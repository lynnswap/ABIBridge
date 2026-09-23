#pragma once

#include <ABIBridge/ABIBridge.hpp>
#include <ABIBridge/Runtime.h>
#include <memory>
#include <ptrauth.h>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>

namespace abi_bridge {

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
    friend class InvocationRuntime;
    explicit function(resolved_symbol symbol) : symbol_(std::move(symbol)) {}
    resolved_symbol symbol_;
};


namespace detail {
template <typename Signature> struct method_signature;
template <typename Result, typename... Arguments>
struct method_signature<Result(Arguments...)> {
    using receiver = void;
    using function_type = Result(void*, Arguments...);
};
template <typename Result, typename... Arguments>
struct method_signature<Result(Arguments...) const> {
    using receiver = const void;
    using function_type = Result(const void*, Arguments...);
};
}

template <typename Signature> class bound_method;

/// A direct member entry point with an explicitly supplied receiver.
/// Use a const-qualified signature for const methods. The receiver must point
/// to the target class subobject; this handle does not perform virtual dispatch.
template <typename Signature>
class method final {
    using traits = detail::method_signature<Signature>;
    using receiver = typename traits::receiver;
    using native_function = function<typename traits::function_type>;
public:
    /// Borrows a valid receiver for one call. The signature, receiver subobject,
    /// argument lifetimes, and target thread requirements are caller contracts.
    template <typename... Arguments>
    decltype(auto) unsafe_invoke(receiver* object, Arguments&&... arguments) const {
        return function_.unsafe_invoke(object, std::forward<Arguments>(arguments)...);
    }

    /// Binds an existing object, retaining its shared owner. An aliasing
    /// shared_ptr can keep an enclosing allocation alive while pointing at the
    /// exact subobject expected by this member entry point.
    template <typename Object>
        requires std::is_convertible_v<Object*, receiver*>
    bound_method<Signature> bind(std::shared_ptr<Object> object) const {
        if (!object) {
            throw resolution_error(ABIFailureInvalidRequest, "Cannot bind a null C++ receiver.");
        }
        return bound_method<Signature>(*this, std::move(object));
    }

    const resolved_symbol& symbol() const noexcept { return function_.symbol(); }

private:
    friend class InvocationRuntime;
    explicit method(native_function function) : function_(std::move(function)) {}
    native_function function_;
};

/// A method together with a shared owner that keeps its receiver alive.
template <typename Signature>
class bound_method final {
    using receiver = typename detail::method_signature<Signature>::receiver;
public:
    bound_method(const bound_method&) = default;
    bound_method(bound_method&&) noexcept = default;
    bound_method& operator=(bound_method other) noexcept {
        using std::swap;
        swap(method_, other.method_);
        swap(receiver_, other.receiver_);
        return *this;
    }

    /// Calls on the retained receiver. Retention does not make the target's
    /// mutable state thread-safe or retain other pointer/reference arguments.
    template <typename... Arguments>
    decltype(auto) unsafe_invoke(Arguments&&... arguments) const {
        return method_.unsafe_invoke(receiver_.get(), std::forward<Arguments>(arguments)...);
    }

    const resolved_symbol& symbol() const noexcept { return method_.symbol(); }

private:
    friend class method<Signature>;
    bound_method(method<Signature> method, std::shared_ptr<receiver> receiver)
        : method_(std::move(method)), receiver_(std::move(receiver)) {}
    // Release the receiver before its code image, including during assignment.
    method<Signature> method_;
    std::shared_ptr<receiver> receiver_;
};

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
        using native_signature = typename detail::method_signature<Signature>::function_type;
        return method<Signature>(function<native_signature>(resolve(query, scope)));
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
