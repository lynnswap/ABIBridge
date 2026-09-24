#pragma once

#include <ABIBridge/NativeInvocation.hpp>
#include <ABIBridge/Runtime.h>
#include <memory>
#include <ptrauth.h>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>

namespace abi_bridge {

/// Internal compiler-lowered invocation support for native backend fixtures.
/// Public inspection and its ownership model live in Inspection.hpp.
class InvocationRuntime final {
public:
    InvocationRuntime() = default;
    static InvocationRuntime current() { return InvocationRuntime(Runtime::current()); }
    resolved_symbol resolve(const declaration& query, const image_selector& scope = {}) const {
        return runtime_.resolve(query, scope);
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
        require_cxx_function(query);
        return function<Signature>(resolve(query, scope));
    }

    /// Resolves a direct member entry point. Use Result(Arguments...) const for
    /// a const method. The caller supplies the exact receiver subobject;
    /// virtual dispatch and implicit base adjustments are not performed.
    template <typename Signature>
    method<Signature> cxx_method(const declaration& query, const image_selector& scope = {}) const {
        require_cxx_function(query);
        return method<Signature>(resolve(query, scope));
    }

    /// Drops indexes without invalidating existing function or symbol handles.
    void remove_cached_results() const { runtime_.remove_cached_results(); }

private:
    static void require_cxx_function(const declaration& query) {
        if (query.source_language != language::cxx || query.kind != symbol_kind::function) {
            throw resolution_error(ABIFailureInvalidRequest, "Expected a C++ function declaration.");
        }
    }

    explicit InvocationRuntime(Runtime runtime) : runtime_(std::move(runtime)) {}
    Runtime runtime_;
};

} // namespace abi_bridge
