#pragma once

#include <ABIBridge/Inspection.hpp>
#include <memory>
#include <ptrauth.h>
#include <type_traits>
#include <utility>

namespace abi_bridge {

/// A concrete C/C++ function signature, lowered by the consumer's compiler.
/// Fixed and variadic signatures use ordinary function types. A handle may outlive
/// its runtime; target thread-safety and argument lifetimes remain caller-owned.
template <typename Signature> class function;

namespace detail {
template <typename Signature>
class function_target {
public:
    explicit function_target(resolved_symbol symbol) : symbol_(std::move(symbol)) {
        if (!symbol_ || ABIResolvedSymbolKind(symbol_.native_handle()) != ABISymbolFunction ||
            (ABIResolvedSymbolLanguage(symbol_.native_handle()) != ABILanguageC &&
             ABIResolvedSymbolLanguage(symbol_.native_handle()) != ABILanguageCXX)) {
            throw resolution_error(ABIFailureInvalidRequest, "Expected a retained C/C++ function symbol.");
        }
    }
    Signature* pointer() const {
        void* address = const_cast<void*>(symbol_.unsafe_address());
#if __has_feature(ptrauth_calls)
        address = ptrauth_sign_unauthenticated(address, ptrauth_key_function_pointer,
            ptrauth_function_pointer_type_discriminator(Signature));
#endif
        return reinterpret_cast<Signature*>(address);
    }
    const resolved_symbol& symbol() const noexcept { return symbol_; }
private:
    resolved_symbol symbol_;
};
}

template <typename Result, typename... Arguments>
class function<Result(Arguments...)> final {
    detail::function_target<Result(Arguments...)> target_;
public:
    /// Takes a retained C/C++ function symbol. The supplied signature is the
    /// caller's ABI and ownership contract, not information proven by lookup.
    explicit function(resolved_symbol symbol) : target_(std::move(symbol)) {}
    /// Calls with the declared fixed parameter types and native ownership.
    Result unsafe_invoke(Arguments... arguments) const {
        return target_.pointer()(std::forward<Arguments>(arguments)...);
    }
    const resolved_symbol& symbol() const noexcept { return target_.symbol(); }
};

template <typename Result, typename... Arguments>
class function<Result(Arguments..., ...)> final {
    detail::function_target<Result(Arguments..., ...)> target_;
public:
    explicit function(resolved_symbol symbol) : target_(std::move(symbol)) {}
    /// The compiler promotes anonymous arguments. Their types must match the
    /// implementation's va_arg operations; pointer/resource lifetimes are borrowed.
    template <typename... VariadicArguments>
    Result unsafe_invoke(Arguments... arguments, VariadicArguments&&... tail) const {
        return target_.pointer()(std::forward<Arguments>(arguments)...,
            std::forward<VariadicArguments>(tail)...);
    }
    const resolved_symbol& symbol() const noexcept { return target_.symbol(); }
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
template <typename Result, typename... Arguments>
struct method_signature<Result(Arguments..., ...)> {
    using receiver = void;
    using function_type = Result(void*, Arguments..., ...);
};
template <typename Result, typename... Arguments>
struct method_signature<Result(Arguments..., ...) const> {
    using receiver = const void;
    using function_type = Result(const void*, Arguments..., ...);
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
    /// Uses a retained C++ member-entry symbol without repeating lookup.
    explicit method(resolved_symbol symbol) : function_(std::move(symbol)) {
        if (ABIResolvedSymbolLanguage(function_.symbol().native_handle()) != ABILanguageCXX)
            throw resolution_error(ABIFailureInvalidRequest, "Expected a C++ member-entry symbol.");
    }

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

    /// Copies the prepared entry point without retaining this receiver binding.
    auto method() const noexcept -> abi_bridge::method<Signature> { return method_; }

private:
    friend class abi_bridge::method<Signature>;
    bound_method(abi_bridge::method<Signature> method, std::shared_ptr<receiver> receiver)
        : method_(std::move(method)), receiver_(std::move(receiver)) {}
    // Release the receiver before its code image, including during assignment.
    abi_bridge::method<Signature> method_;
    std::shared_ptr<receiver> receiver_;
};

} // namespace abi_bridge
