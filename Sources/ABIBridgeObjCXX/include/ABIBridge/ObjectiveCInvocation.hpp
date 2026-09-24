#pragma once

#import <ABIBridge/ObjectiveCInvocation.h>
#include <ABIBridge/Inspection.hpp>
#include <array>
#include <optional>
#include <type_traits>

namespace abi_bridge {

/// Ownership overrides for annotations not represented in runtime encodings.
/// Omitted values use selector-family conventions. Explicit consumed arguments
/// other than self require a target-specific adapter.
struct objc_method_options {
    std::optional<bool> returns_retained;
    std::optional<bool> consumes_receiver;
};

namespace detail {
template <typename T>
struct is_objc_result : std::bool_constant<std::is_pointer_v<T> && std::is_convertible_v<T, id>> {};
template <typename Result, typename... Arguments>
struct is_objc_result<Result (^)(Arguments...)> : std::true_type {};
}

template <typename Signature> class objc_method_handle;

/// A typed IMP and retained receiver. Copies share the binding. Binding checks
/// encodings and ownership options, but cannot infer every native ABI contract.
/// The caller owns argument lifetimes and target thread requirements.
template <typename Result, typename... Arguments>
class objc_method_handle<Result(Arguments...)> final {
public:
    objc_method_handle(id receiver, SEL selector, objc_method_options options = {}) {
        const std::array<const char*, sizeof...(Arguments)> parameters{@encode(Arguments)...};
        NSError* error = nil;
        auto* method = ABICopyObjCMethod(receiver, selector, @encode(Result),
            parameters.data(), parameters.size(),
            options.returns_retained ? (*options.returns_retained ? 1 : 0) : -1,
            options.consumes_receiver ? (*options.consumes_receiver ? 1 : 0) : -1, &error);
        if (!method) {
            throw resolution_error(static_cast<std::int32_t>(error.code),
                                   error.localizedDescription.UTF8String);
        }
        method_ = std::shared_ptr<ABIObjCMethod>(method, ABIReleaseObjCMethod);
    }

    /// Invokes the IMP chosen at binding time. Rebind to observe replacement.
    /// Object results follow ordinary +0 return semantics; ARC callers receive
    /// managed values. With manual reference counting, retain results to keep
    /// them beyond the current autorelease pool.
    Result unsafe_invoke(Arguments... arguments) const {
        const bool consumed = ABIObjCMethodConsumesReceiver(method_.get());
        if constexpr (detail::is_objc_result<Result>::value) {
            if (ABIObjCMethodReturnsRetained(method_.get())) {
                return consumed ? invoke<true, true>(std::forward<Arguments>(arguments)...)
                                : invoke<false, true>(std::forward<Arguments>(arguments)...);
            }
        }
        return consumed ? invoke<true, false>(std::forward<Arguments>(arguments)...)
                        : invoke<false, false>(std::forward<Arguments>(arguments)...);
    }

private:
    template <bool Consumed, bool Retained>
    Result invoke(Arguments... arguments) const {
        id receiver = ABIObjCMethodReceiver(method_.get());
        const auto selector = ABIObjCMethodSelector(method_.get());
        const auto implementation = ABIObjCMethodImplementation(method_.get());
#if !__has_feature(objc_arc)
        if constexpr (Consumed) [receiver retain];
#endif
        if constexpr (Retained) {
            Result result;
            if constexpr (Consumed) {
                typedef Result (*Function)(id __attribute__((ns_consumed)), SEL, Arguments...)
                    __attribute__((ns_returns_retained));
                result = reinterpret_cast<Function>(implementation)(
                    receiver, selector, std::forward<Arguments>(arguments)...);
            } else {
                typedef Result (*Function)(id, SEL, Arguments...) __attribute__((ns_returns_retained));
                result = reinterpret_cast<Function>(implementation)(
                    receiver, selector, std::forward<Arguments>(arguments)...);
            }
#if !__has_feature(objc_arc)
            return [result autorelease];
#else
            return result;
#endif
        } else if constexpr (Consumed) {
            typedef Result (*Function)(id __attribute__((ns_consumed)), SEL, Arguments...);
            return reinterpret_cast<Function>(implementation)(
                receiver, selector, std::forward<Arguments>(arguments)...);
        } else {
            using Function = Result (*)(id, SEL, Arguments...);
            return reinterpret_cast<Function>(implementation)(
                receiver, selector, std::forward<Arguments>(arguments)...);
        }
    }

    std::shared_ptr<ABIObjCMethod> method_;
};

/// Resolves a selector on an existing receiver and binds its typed IMP.
template <typename Signature>
objc_method_handle<Signature> objc_method(
    id receiver, SEL selector, objc_method_options options = {})
{
    return objc_method_handle<Signature>(receiver, selector, options);
}

/// Creates the selector from a source-level name without requiring a header
/// declaration for the target method.
template <typename Signature>
objc_method_handle<Signature> objc_method(
    id receiver, std::string_view name, objc_method_options options = {})
{
    if (name.find('\0') != std::string_view::npos)
        throw resolution_error(ABIFailureInvalidRequest, "Selector names must not contain embedded NULs.");
    const std::string selector(name);
    return objc_method<Signature>(receiver, sel_registerName(selector.c_str()), options);
}

} // namespace abi_bridge
