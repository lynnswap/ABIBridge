#pragma once

#include <ABIBridge/ABIBridge.hpp>
#include <ABIBridge/Runtime.h>
#include <memory>
#include <ptrauth.h>
#include <stdexcept>
#include <string>
#include <utility>

namespace abi_bridge {

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
    /// One of the ABIFailure constants declared in Runtime.h.
    std::int32_t code() const noexcept { return code_; }

private:
    std::int32_t code_;
};

/// A symbol retaining its image. Copies share ownership of the same result.
class resolved_symbol final {
public:
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

template <typename Signature> class function;

/// A concrete C/C++ function signature, lowered by the consumer's compiler.
/// Variadic signatures are not supported. A handle may be copied and outlive
/// its runtime; target thread-safety and argument lifetimes remain caller-owned.
template <typename Result, typename... Arguments>
class function<Result(Arguments...)> final {
public:
    /// Calls using the supplied signature. The caller must ensure that argument
    /// and result types, calling convention, and ownership match the definition.
    /// Name resolution alone cannot validate this ABI contract.
    Result unsafe_invoke(Arguments... arguments) const {
        using signature = Result(Arguments...);
        using pointer = signature*;
        void* address = const_cast<void*>(symbol_.unsafe_address());
#if __has_feature(ptrauth_calls)
        address = ptrauth_sign_unauthenticated(
            address, ptrauth_key_function_pointer,
            ptrauth_function_pointer_type_discriminator(signature));
#endif
        return reinterpret_cast<pointer>(address)(std::forward<Arguments>(arguments)...);
    }

    const resolved_symbol& symbol() const noexcept { return symbol_; }

private:
    friend class Runtime;
    explicit function(resolved_symbol symbol) : symbol_(std::move(symbol)) {}
    resolved_symbol symbol_;
};

/// Synchronous access to the shared native symbol resolver.
///
/// Link the ABIBridgeCore Swift package product; it includes the MachOKit-backed
/// implementation. Resolution and cache clearing are thread-safe. Copies share
/// their runtime; separately constructed instances own independent caches.
class Runtime final {
public:
    Runtime() : handle_(ABICreateSymbolRuntime(), ABIReleaseSymbolRuntime) {}
    /// Uses the same cache as Swift's ABIRuntime.shared.
    static Runtime current() { return Runtime(ABICopySharedSymbolRuntime()); }

    /// Resolves a source-level declaration; throws resolution_error on failure.
    resolved_symbol resolve(const declaration& query, const image_selector& scope = {}) const {
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

    /// Resolves a C function by its unmangled name and retains its image.
    template <typename Signature>
    function<Signature> c_function(std::string name, const image_selector& scope = {}) const {
        return function<Signature>(resolve(declaration(std::move(name), language::c), scope));
    }

    /// Resolves a complete demangled C++ declaration. Signature must describe
    /// the actual C++ types, including reference categories and return type.
    template <typename Signature>
    function<Signature> cxx_function(const declaration& query, const image_selector& scope = {}) const {
        if (query.source_language != language::cxx || query.kind != symbol_kind::function) {
            throw resolution_error(ABIFailureInvalidRequest, "Expected a C++ function declaration.");
        }
        return function<Signature>(resolve(query, scope));
    }

    /// Drops indexes without invalidating existing function or symbol handles.
    void remove_cached_results() const { ABIRuntimeRemoveCachedResults(handle_.get()); }

private:
    explicit Runtime(ABISymbolRuntime* handle) : handle_(handle, ABIReleaseSymbolRuntime) {}
    std::shared_ptr<ABISymbolRuntime> handle_;
};

} // namespace abi_bridge
