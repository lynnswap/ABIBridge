#pragma once

#include <ABIBridge/Inspection.h>
#include <ABIBridge/Memory.hpp>
#include <array>
#include <cstdint>
#include <cstddef>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>

namespace abi_bridge {

/// Declaration language used for symbol inspection.
enum class language : std::uint8_t {
    swift = ABILanguageSwift,
    /// Reserved; symbol resolution reports unsupported declaration for this language.
    objective_c = ABILanguageObjectiveC,
    c = ABILanguageC, cxx = ABILanguageCXX
};
/// Required storage kind; does not establish an invocation signature.
enum class symbol_kind : std::uint8_t {
    function = ABISymbolFunction, data = ABISymbolData, vtable = ABISymbolVTable
};
/// Process-local load identity. Addresses alone do not distinguish reloads.
struct image_identity final {
    std::uint64_t header_address = 0;
    std::int64_t slide = 0;
    std::uint64_t load_generation = 0;
    friend constexpr bool operator==(const image_identity&, const image_identity&) = default;
};
/// A source-level name and expected symbol storage.
struct declaration final {
    std::string name;
    language source_language = language::cxx;
    symbol_kind kind = symbol_kind::function;

    declaration() = default;
    declaration(std::string name, language source_language = language::cxx,
                symbol_kind kind = symbol_kind::function)
        : name(std::move(name)), source_language(source_language), kind(kind) {}
};

/// A loaded-image constraint. Selecting an image does not load it.
class image_selector final {
public:
    image_selector() = default;
    static image_selector automatic() { return {}; }
    static image_selector framework(std::string name) {
        return {ABIImageFramework, std::move(name)};
    }
    static image_selector path(std::string executable_path) {
        return {ABIImagePath, std::move(executable_path)};
    }

private:
    friend class Runtime;
    image_selector(std::int32_t kind, std::string value)
        : kind_(kind), value_(std::move(value)) {}
    std::int32_t kind_ = ABIImageAutomatic;
    std::string value_;
};

/// A resolution failure with a stable category and human-readable detail.
class resolution_error final : public std::runtime_error {
public:
    resolution_error(std::int32_t code, const std::string& message)
        : std::runtime_error(message), code_(code) {}
    /// One of the ABIFailure constants declared in Inspection.h.
    std::int32_t code() const noexcept { return code_; }

private:
    std::int32_t code_;
};

/// A symbol retaining its image. Copies share ownership of the same result.
class resolved_symbol final {
public:
    /// False after a move. Other operations require a live handle.
    explicit operator bool() const noexcept { return bool(handle_); }

    /// Borrowed address; keep this handle alive while using it. This establishes
    /// neither a native signature nor the ownership/layout of a data value.
    const void* unsafe_address() const noexcept {
        return ABIResolvedSymbolAddress(handle_.get());
    }
    image_identity image() const noexcept {
        ABIImageInfo info{};
        ABIResolvedSymbolImage(handle_.get(), &info);
        return {info.header, info.slide, info.generation};
    }
    std::string image_path() const {
        ABIImageInfo info{};
        ABIResolvedSymbolImage(handle_.get(), &info);
        return info.path;
    }

private:
    friend class Runtime;
    explicit resolved_symbol(ABIResolvedSymbol* handle)
        : handle_(handle, ABIReleaseResolvedSymbol) {}
    std::shared_ptr<ABIResolvedSymbol> handle_;
};


/// A copied image description. The path and UUID are owned values; this
/// description does not retain the image or make its addresses safe to read.
struct image_description final {
    image_identity identity;
    std::array<std::uint8_t, 16> uuid;
    std::string path;
};

/// An immutable image-catalog snapshot. Copies share the snapshot's storage.
/// Moving leaves an empty handle, which may be tested, reassigned, or destroyed.
class image_snapshot final {
public:
    /// Captures loaded-image descriptions without retaining those images.
    /// Throws resolution_error if the catalog cannot be initialized/retained.
    static image_snapshot capture() {
        auto* list = ABICopyLoadedImages();
        if (!list) {
            throw resolution_error(ABIFailureImageUnavailable, "The loaded-image catalog is unavailable.");
        }
        return image_snapshot(list);
    }

    explicit operator bool() const noexcept { return bool(handle_); }
    /// Requires a live snapshot.
    std::size_t size() const noexcept { return ABIImageListCount(handle_.get()); }
    /// Copies an entry, including its path. The returned description may
    /// outlive the snapshot. Throws out_of_range for an invalid index.
    image_description at(std::size_t index) const {
        if (index >= size()) throw std::out_of_range("Image snapshot index is out of range.");
        const auto info = ABIImageListGet(handle_.get(), index);
        return {{info.header, info.slide, info.generation}, std::to_array(info.uuid), info.path};
    }

private:
    explicit image_snapshot(ABIImageList* list) : handle_(list, ABIFreeImageList) {}
    std::shared_ptr<ABIImageList> handle_;
};

/// A loader lease. Copies share one acquired lease; its last owner releases it.
/// This does not own path strings copied or borrowed from another handle.
class image_lease final {
public:
    /// Returns no value if the generation disappeared or cannot be retained.
    /// The loader may independently keep an image loaded after lease release.
    static std::optional<image_lease> acquire(std::uint64_t generation) {
        if (auto* lease = ABIRetainLoadedImage(generation)) return image_lease(lease);
        return std::nullopt;
    }
    /// False after moving the contained lease; a moved-from optional can still
    /// be engaged, as with other optional values.
    explicit operator bool() const noexcept { return bool(handle_); }

private:
    explicit image_lease(ABIImageLease* lease) : handle_(lease, ABIReleaseImage) {}
    std::shared_ptr<ABIImageLease> handle_;
};

/// Synchronous access to the same backend as Swift's ABIRuntime.
/// Copies share a cache; default construction creates an independent cache.
/// Calls and cache clearing are thread-safe while handles stay alive. Moving
/// leaves an empty handle; do not resolve or clear through that moved-from value.
class Runtime final {
public:
    Runtime() : handle_(ABICreateSymbolRuntime(), ABIReleaseSymbolRuntime) {}
    /// Shares the process-wide resolver cache with Swift's ABIRuntime.shared.
    static Runtime current() { return Runtime(ABICopySharedSymbolRuntime()); }
    explicit operator bool() const noexcept { return bool(handle_); }

    /// Resolves a declaration or throws an owned resolution_error. The returned
    /// symbol is independent of this runtime and keeps its image loaded.
    /// Names/selectors use UTF-8 without embedded NULs. Embedded NULs report
    /// ABIFailureInvalidRequest instead of resolving a truncated C string.
    resolved_symbol resolve(const declaration& query, const image_selector& scope = {}) const {
        if (query.name.find('\0') != std::string::npos || scope.value_.find('\0') != std::string::npos) {
            throw resolution_error(ABIFailureInvalidRequest, "Names and image selectors must not contain embedded NULs.");
        }
        ABIResolutionFailure* failure = nullptr;
        auto* symbol = ABIResolveSymbol(
            handle_.get(), query.name.c_str(),
            static_cast<std::int32_t>(query.source_language),
            static_cast<std::int32_t>(query.kind),
            scope.kind_, scope.value_.c_str(), &failure);
        if (!symbol) {
            std::unique_ptr<ABIResolutionFailure, decltype(&ABIReleaseResolutionFailure)>
                owned_failure(failure, ABIReleaseResolutionFailure);
            throw resolution_error(ABIResolutionFailureCode(failure),
                                   ABIResolutionFailureMessage(failure));
        }
        return resolved_symbol(symbol);
    }

    /// Clears indexes without invalidating previously returned symbol handles.
    void remove_cached_results() const { ABIRuntimeRemoveCachedResults(handle_.get()); }

private:
    explicit Runtime(ABISymbolRuntime* handle) : handle_(handle, ABIReleaseSymbolRuntime) {}
    std::shared_ptr<ABISymbolRuntime> handle_;
};

} // namespace abi_bridge
