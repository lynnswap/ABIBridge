#pragma once

#include <ABIBridge/Inspection.h>
#include <ABIBridge/Memory.hpp>
#include <ABIBridge/PointerSearch.hpp>
#include <array>
#include <cstdint>
#include <cstddef>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <variant>
#include <vector>
#include <algorithm>

namespace abi_bridge {

/// Declaration language used for symbol inspection.
enum class language : std::uint8_t {
    swift = ABILanguageSwift,
    /// Source declarations are unsupported; exact symbol spellings are accepted.
    objective_c = ABILanguageObjectiveC,
    c = ABILanguageC, cxx = ABILanguageCXX
};
/// Required storage kind; does not establish an invocation signature.
enum class symbol_kind : std::uint8_t {
    function = ABISymbolFunction, data = ABISymbolData, vtable = ABISymbolVTable
};
/// Name representation independent of declaration language.
enum class name_form : std::uint8_t {
    source = ABINameSource, linker = ABINameLinker, mach_o = ABINameMachO
};
/// Process-local load identity. Addresses alone do not distinguish reloads.
struct image_identity final {
    std::uint64_t header_address = 0;
    std::int64_t slide = 0;
    std::uint64_t load_generation = 0;
    friend constexpr bool operator==(const image_identity&, const image_identity&) = default;
};
/// A source-level or exact name and expected symbol storage.
struct declaration final {
    std::string name;
    language source_language = language::cxx;
    symbol_kind kind = symbol_kind::function;
    name_form form = name_form::source;

    declaration() = default;
    declaration(std::string name, language source_language = language::cxx,
                symbol_kind kind = symbol_kind::function, name_form form = name_form::source)
        : name(std::move(name)), source_language(source_language), kind(kind), form(form) {}

    /// Exact linker spelling; adds one Mach-O underscore without guessing prefixes.
    static declaration linker_name(std::string name, language source_language,
                                   symbol_kind kind = symbol_kind::function) {
        return {std::move(name), source_language, kind, name_form::linker};
    }
    /// Literal Mach-O symbol spelling, with no prefix conversion or normalization.
    static declaration mach_o_name(std::string name, language source_language,
                                   symbol_kind kind = symbol_kind::function) {
        return {std::move(name), source_language, kind, name_form::mach_o};
    }

    /// Requests a C++ vtable by qualified type name. Resolves its symbol base,
    /// without inferring an address point, object layout, or authentication.
    static declaration vtable_for(std::string type_name) {
        return {"vtable for " + type_name, language::cxx, symbol_kind::vtable};
    }
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

/// One declaration with aliases, lazy fallbacks, and ordered loaded-image scopes.
/// Empty scopes match no images. Found aliases must agree on address and load.
/// Each candidate searches all scopes before the next candidate is attempted.
struct symbol_request final {
    declaration primary;
    std::vector<declaration> alternatives;
    std::vector<image_selector> image_scopes = {image_selector::automatic()};
    std::vector<declaration> fallbacks;
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
    /// Takes ownership of one acquired, non-null C symbol reference. The caller
    /// must not release that reference after this call, including if allocation
    /// throws. Copies of the wrapper share its ownership.
    static resolved_symbol adopt(ABIResolvedSymbol* owned) {
        return resolved_symbol(owned);
    }
    /// Acquires independent ownership from a borrowed, live, non-null C symbol.
    /// Keep the borrowed reference alive throughout this call.
    static resolved_symbol retain(ABIResolvedSymbol* borrowed) {
        return adopt(ABIRetainResolvedSymbol(borrowed));
    }
    /// Borrows the C handle. Keep this wrapper or another owning copy alive
    /// during use; call ABIRetainResolvedSymbol to acquire independent ownership.
    ABIResolvedSymbol* native_handle() const noexcept { return handle_.get(); }

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


/// An independently owned per-request symbol or lookup failure.
using resolution_result = std::variant<resolved_symbol, resolution_error>;

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

/// An image lifetime lease. Copies share one acquired lease; its last owner releases it.
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

/// Copied import names. Neither spelling establishes a callable signature.
struct lazy_symbol_description final {
    std::optional<std::string> name;
    std::optional<std::string> raw_name;
};

/// Copied lazy-load metadata. Empty optionals mean unavailable information.
struct lazy_library_description final {
    std::uint64_t command_offset;
    std::optional<std::string> path;
    std::optional<bool> is_optional;
    std::optional<bool> symbols_prebound;
    /// Always empty for file inspection; live reads do not synchronize with dyld.
    std::optional<bool> is_initialized;
    /// An engaged empty vector means a readable zero-symbol list.
    std::optional<std::vector<lazy_symbol_description>> symbols;
};

/// Immutable diagnostics that may outlive the source image or file.
/// Copies share ownership; descriptions returned by at() own their strings.
class lazy_library_snapshot final {
public:
    /// Retains the generation during reading, then releases that temporary lease.
    /// No dependency is loaded and no mutable binding chain is traversed.
    static lazy_library_snapshot capture(std::uint64_t generation) {
        ABIResolutionFailure* failure = nullptr;
        auto* list = ABICopyLazyLibrariesForImage(generation, &failure);
        return checked(list, failure);
    }
    /// Reads a thin Mach-O file. Disk data cannot establish live initialization.
    static lazy_library_snapshot read_file(const std::string& path) {
        if (path.find('\0') != std::string::npos) {
            throw resolution_error(ABIFailureInvalidRequest, "File paths must not contain embedded NULs.");
        }
        ABIResolutionFailure* failure = nullptr;
        auto* list = ABICopyLazyLibrariesInFile(path.c_str(), &failure);
        return checked(list, failure);
    }
    explicit operator bool() const noexcept { return bool(handle_); }
    /// Requires a live snapshot; moving leaves an empty handle.
    std::size_t size() const noexcept { return ABILazyLibraryListCount(handle_.get()); }
    lazy_library_description at(std::size_t index) const {
        if (index >= size()) throw std::out_of_range("Lazy-library index is out of range.");
        const auto info = ABILazyLibraryListGet(handle_.get(), index);
        lazy_library_description result{info.commandOffset, string(info.path), boolean(info.isOptional),
            boolean(info.areSymbolsPrebound), boolean(info.isInitialized), std::nullopt};
        if (info.symbolsAvailable == ABIDiagnosticTrue) {
            result.symbols.emplace();
            result.symbols->reserve(info.symbolCount);
            for (std::size_t i = 0; i < info.symbolCount; ++i) {
                const auto symbol = ABILazyLibraryListSymbol(handle_.get(), index, i);
                result.symbols->push_back({string(symbol.name), string(symbol.rawName)});
            }
        }
        return result;
    }

private:
    explicit lazy_library_snapshot(ABILazyLibraryList* list) : handle_(list, ABIFreeLazyLibraryList) {}
    static lazy_library_snapshot checked(ABILazyLibraryList* list, ABIResolutionFailure* failure) {
        std::unique_ptr<ABIResolutionFailure, decltype(&ABIReleaseResolutionFailure)>
            owned_failure(failure, ABIReleaseResolutionFailure);
        if (!list) throw resolution_error(ABIResolutionFailureCode(failure), ABIResolutionFailureMessage(failure));
        return lazy_library_snapshot(list);
    }
    static std::optional<std::string> string(const char* value) {
        return value ? std::optional<std::string>(value) : std::nullopt;
    }
    static std::optional<bool> boolean(std::int32_t value) {
        if (value == ABIDiagnosticTrue) return true;
        if (value == ABIDiagnosticFalse) return false;
        return std::nullopt;
    }
    std::shared_ptr<ABILazyLibraryList> handle_;
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
        auto* symbol = ABIResolveSymbolWithNameForm(
            handle_.get(), query.name.c_str(), static_cast<std::int32_t>(query.form),
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

    /// Resolves aliases and lazy name/scope fallbacks, or throws resolution_error.
    resolved_symbol resolve(const symbol_request& query) const {
        auto results = resolve(std::vector<symbol_request>{query});
        if (auto* symbol = std::get_if<resolved_symbol>(&results.front())) return std::move(*symbol);
        throw std::get<resolution_error>(results.front());
    }

    /// Resolves every request, preserving order and partial success. Scope
    /// results are reused within this batch, not an atomic loader snapshot.
    /// Allocation failures still throw; resolution failures remain per request.
    std::vector<resolution_result> resolve(const std::vector<symbol_request>& queries) const {
        const auto declaration_value = [](const declaration& d) {
            return ABIDeclaration{d.name.c_str(), static_cast<std::int32_t>(d.source_language),
                                  static_cast<std::int32_t>(d.kind), static_cast<std::int32_t>(d.form)};
        };
        const auto has_nul = [](const std::string& s) { return s.find('\0') != std::string::npos; };
        std::vector<std::vector<ABIDeclaration>> aliases(queries.size());
        std::vector<std::vector<ABIDeclaration>> fallbacks(queries.size());
        std::vector<std::vector<ABIImageSelector>> scopes(queries.size());
        std::vector<ABISymbolRequest> native_queries;
        std::vector<std::size_t> indices;
        std::vector<std::optional<resolution_result>> outcomes(queries.size());
        for (std::size_t i = 0; i < queries.size(); ++i) {
            const auto& query = queries[i];
            if (has_nul(query.primary.name) ||
                std::any_of(query.alternatives.begin(), query.alternatives.end(),
                            [&](const auto& d) { return has_nul(d.name); }) ||
                std::any_of(query.fallbacks.begin(), query.fallbacks.end(),
                            [&](const auto& d) { return has_nul(d.name); }) ||
                std::any_of(query.image_scopes.begin(), query.image_scopes.end(),
                            [&](const auto& s) { return has_nul(s.value_); })) {
                outcomes[i].emplace(resolution_error(
                    ABIFailureInvalidRequest, "Names and image selectors must not contain embedded NULs."));
                continue;
            }
            for (const auto& d : query.alternatives) aliases[i].push_back(declaration_value(d));
            for (const auto& d : query.fallbacks) fallbacks[i].push_back(declaration_value(d));
            for (const auto& s : query.image_scopes) scopes[i].push_back({s.kind_, s.value_.c_str()});
            native_queries.push_back({declaration_value(query.primary),
                                      aliases[i].data(), aliases[i].size(),
                                      scopes[i].data(), scopes[i].size(),
                                      fallbacks[i].data(), fallbacks[i].size()});
            indices.push_back(i);
        }
        std::vector<ABISymbolResult> native_results(native_queries.size());
        struct result_cleanup {
            std::vector<ABISymbolResult>& results;
            ~result_cleanup() {
                for (auto& result : results) {
                    if (result.symbol) ABIReleaseResolvedSymbol(result.symbol);
                    if (result.failure) ABIReleaseResolutionFailure(result.failure);
                }
            }
        } cleanup{native_results};
        ABIResolveSymbols(handle_.get(), native_queries.data(), native_queries.size(), native_results.data());
        for (std::size_t i = 0; i < native_results.size(); ++i) {
            auto& result = native_results[i];
            if (result.symbol) {
                outcomes[indices[i]].emplace(resolved_symbol::adopt(std::exchange(result.symbol, nullptr)));
            } else {
                outcomes[indices[i]].emplace(resolution_error(
                    ABIResolutionFailureCode(result.failure), ABIResolutionFailureMessage(result.failure)));
            }
        }
        std::vector<resolution_result> results;
        results.reserve(outcomes.size());
        for (auto& outcome : outcomes) results.push_back(std::move(*outcome));
        return results;
    }

    /// Clears indexes without invalidating previously returned symbol handles.
    void remove_cached_results() const { ABIRuntimeRemoveCachedResults(handle_.get()); }

private:
    explicit Runtime(ABISymbolRuntime* handle) : handle_(handle, ABIReleaseSymbolRuntime) {}
    std::shared_ptr<ABISymbolRuntime> handle_;
};

} // namespace abi_bridge
