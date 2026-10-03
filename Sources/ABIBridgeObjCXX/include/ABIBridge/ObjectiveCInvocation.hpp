#pragma once

#import <ABIBridge/ObjectiveCInvocation.h>
#include <ABIBridge/Inspection.hpp>
#include <algorithm>
#include <array>
#include <Block.h>
#include <optional>
#include <tuple>
#include <type_traits>
#include <vector>

namespace abi_bridge {

/// Ownership overrides for annotations not represented in runtime encodings.
/// Omitted receiver/result values use selector-family conventions.
struct objc_method_options {
    std::optional<bool> returns_retained;
    std::optional<bool> consumes_receiver;
    /// Zero-based explicit ns_consumed parameters.
    std::vector<std::size_t> consumed_parameters;
};

namespace detail {
template <typename T>
struct is_objc_result : std::bool_constant<std::is_pointer_v<T> && std::is_convertible_v<T, id>> {};
template <typename Result, typename... Arguments>
struct is_objc_result<Result (^)(Arguments...)> : std::true_type {};
template <typename T> struct is_objc_block : std::false_type {};
template <typename Result, typename... Arguments>
struct is_objc_block<Result (^)(Arguments...)> : std::true_type {};
}

template <typename Signature> class bound_objc_implementation;
template <typename Signature> class objc_implementation;

/// A captured typed IMP whose receiver is supplied for each call.
/// Copies retain its class and implementation images without retaining a receiver.
/// Calls preserve the original ownership contract and do not redispatch overrides.
template <typename Result, typename... Arguments>
class objc_implementation<Result(Arguments...)> final {
    using signature = Result(Arguments...);
public:
    /// Uses an existing object to discover and validate a concrete implementation.
    objc_implementation(id prototype, SEL selector, objc_method_options options = {}) {
        auto method = std::unique_ptr<ABIObjCMethod, decltype(&ABIReleaseObjCMethod)>(
            copy_method(prototype, selector, options), ABIReleaseObjCMethod);
        implementation_ = std::shared_ptr<ABIObjCImplementation>(
            ABICopyObjCMethodImplementation(method.get()), ABIReleaseObjCImplementation);
    }
    objc_implementation(id prototype, std::string_view name, objc_method_options options = {})
        : objc_implementation(prototype, selector_named(name), options) {}

    /// Calls the captured IMP with a compatible live receiver.
    /// Target isolation, argument lifetimes, and the actual ABI remain caller contracts.
    /// Object and block results follow ordinary +0 return semantics under ARC/MRC.
    Result unsafe_invoke(__unsafe_unretained id receiver, Arguments... arguments) const {
        const auto implementation = implementation_;
        NSError* error = nil;
        if (!ABIValidateObjCImplementationReceiver(implementation.get(), receiver, &error)) {
            throw resolution_error(static_cast<std::int32_t>(error.code), error.localizedDescription.UTF8String);
        }
        std::array<bool, sizeof...(Arguments)> parameters{};
        for (std::size_t index = 0; index < parameters.size(); ++index)
            parameters[index] = ABIObjCImplementationConsumesParameter(implementation.get(), index);
        return invoke_owned(receiver, ABIObjCImplementationSelector(implementation.get()),
            ABIObjCImplementationIMP(implementation.get()),
            ABIObjCImplementationConsumesReceiver(implementation.get()),
            ABIObjCImplementationReturnsRetained(implementation.get()), parameters, std::forward<Arguments>(arguments)...);
    }

    /// Retains another receiver without repeating lookup or changing the IMP.
    bound_objc_implementation<signature> bind(__unsafe_unretained id receiver) const {
        return bound_objc_implementation<signature>(*this, receiver);
    }

private:
    friend class bound_objc_implementation<signature>;
    explicit objc_implementation(ABIObjCImplementation* owned)
        : implementation_(owned, ABIReleaseObjCImplementation) {}

    static ABIObjCMethod* copy_method(id receiver, SEL selector, objc_method_options options) {
        const std::array<const char*, sizeof...(Arguments)> parameters{@encode(Arguments)...};
        NSError* error = nil;
        auto* method = ABICopyObjCMethod(receiver, selector, @encode(Result),
            parameters.data(), parameters.size(),
            options.returns_retained ? (*options.returns_retained ? 1 : 0) : -1,
            options.consumes_receiver ? (*options.consumes_receiver ? 1 : 0) : -1,
            options.consumed_parameters.data(), options.consumed_parameters.size(), &error);
        if (!method) {
            throw resolution_error(static_cast<std::int32_t>(error.code), error.localizedDescription.UTF8String);
        }
        return method;
    }

    static SEL selector_named(std::string_view name) {
        if (name.find('\0') != std::string_view::npos)
            throw resolution_error(ABIFailureInvalidRequest, "Selector names must not contain embedded NULs.");
        const std::string selector(name);
        return sel_registerName(selector.c_str());
    }

    struct owned_arguments {
        std::tuple<Arguments...> values;
        std::array<CFTypeRef, sizeof...(Arguments)> references{};
        bool transferred = false;
        explicit owned_arguments(Arguments... arguments) : values(std::forward<Arguments>(arguments)...) {}
        ~owned_arguments() {
            if (!transferred) for (auto value : references) if (value) CFRelease(value);
        }
        template <std::size_t Index>
        void retain(bool consumed) {
            using Argument = std::tuple_element_t<Index, std::tuple<Arguments...>>;
            if constexpr (detail::is_objc_result<Argument>::value) {
                auto value = std::get<Index>(values);
                if (!consumed || !value) return;
                if constexpr (detail::is_objc_block<Argument>::value)
                    references[Index] = _Block_copy((__bridge const void *)value);
                else references[Index] = CFRetain((__bridge CFTypeRef)value);
                std::get<Index>(values) = (__bridge Argument)references[Index];
            }
        }
        template <std::size_t... Index>
        void prepare(const std::array<bool, sizeof...(Arguments)>& parameters, std::index_sequence<Index...>) {
            (retain<Index>(parameters[Index]), ...);
        }
    };

    static Result invoke_owned(id receiver, SEL selector, IMP implementation, bool consumed, bool retained,
                               const std::array<bool, sizeof...(Arguments)>& parameters, Arguments... arguments) {
        if (std::none_of(parameters.begin(), parameters.end(), [](bool value) { return value; }))
            return invoke_prepared(receiver, selector, implementation, consumed, retained,
                                   std::forward<Arguments>(arguments)...);
        owned_arguments owned(std::forward<Arguments>(arguments)...);
        owned.prepare(parameters, std::index_sequence_for<Arguments...>{});
        owned.transferred = true;
        return std::apply([&](auto... values) {
            return invoke_prepared(receiver, selector, implementation, consumed, retained, values...);
        }, owned.values);
    }

    static Result invoke_prepared(id receiver, SEL selector, IMP implementation, bool consumed, bool retained,
                                 Arguments... arguments) {
        if constexpr (detail::is_objc_result<Result>::value) {
            if (retained) {
                return consumed ? invoke<true, true>(receiver, selector, implementation, std::forward<Arguments>(arguments)...)
                                : invoke<false, true>(receiver, selector, implementation, std::forward<Arguments>(arguments)...);
            }
        }
        return consumed ? invoke<true, false>(receiver, selector, implementation, std::forward<Arguments>(arguments)...)
                        : invoke<false, false>(receiver, selector, implementation, std::forward<Arguments>(arguments)...);
    }

    template <bool Consumed, bool Retained>
    static Result invoke(id receiver, SEL selector, IMP implementation, Arguments... arguments) {
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

    std::shared_ptr<ABIObjCImplementation> implementation_;
};

/// A typed captured IMP bound to a retained receiver.
/// Copies share the binding, and receiver destruction precedes image release.
template <typename Result, typename... Arguments>
class bound_objc_implementation<Result(Arguments...)> final {
    using signature = Result(Arguments...);
    using implementation_type = objc_implementation<signature>;
public:
    bound_objc_implementation(id receiver, SEL selector, objc_method_options options = {})
        : method_(implementation_type::copy_method(receiver, selector, options), ABIReleaseObjCMethod) {}
    bound_objc_implementation(id receiver, std::string_view name, objc_method_options options = {})
        : bound_objc_implementation(receiver, implementation_type::selector_named(name), options) {}

    /// Calls the implementation captured at construction with the retained receiver.
    Result unsafe_invoke(Arguments... arguments) const {
        const auto method = method_;
        __unsafe_unretained id receiver = (__bridge id)ABIObjCMethodReceiverAddress(method.get());
        std::array<bool, sizeof...(Arguments)> parameters{};
        for (std::size_t index = 0; index < parameters.size(); ++index)
            parameters[index] = ABIObjCMethodConsumesParameter(method.get(), index);
        return implementation_type::invoke_owned(receiver,
            ABIObjCMethodSelector(method.get()), ABIObjCMethodImplementation(method.get()),
            ABIObjCMethodConsumesReceiver(method.get()), ABIObjCMethodReturnsRetained(method.get()), parameters,
            std::forward<Arguments>(arguments)...);
    }

    /// Copies the captured implementation without retaining this receiver binding.
    implementation_type implementation() const {
        return implementation_type(ABICopyObjCMethodImplementation(method_.get()));
    }

private:
    friend class objc_implementation<signature>;
    bound_objc_implementation(const implementation_type& implementation, __unsafe_unretained id receiver)
        : method_(copy_binding(implementation, receiver), ABIReleaseObjCMethod) {}
    static ABIObjCMethod* copy_binding(const implementation_type& implementation, __unsafe_unretained id receiver) {
        NSError* error = nil;
        auto* method = ABICopyBoundObjCMethod(implementation.implementation_.get(), receiver, &error);
        if (!method) {
            throw resolution_error(static_cast<std::int32_t>(error.code), error.localizedDescription.UTF8String);
        }
        return method;
    }
    std::shared_ptr<ABIObjCMethod> method_;
};

} // namespace abi_bridge
