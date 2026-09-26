#pragma once
#include <ABIBridge/ObjectiveCHooks.h>
#include <ABIBridge/Inspection.hpp>
#include <array>
#include <cstring>
#include <functional>
#include <tuple>
#include <type_traits>
#include <utility>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

namespace abi_bridge {

/// Specialize encoding() for a naturally laid-out C structure in pure C++.
/// Objective-C++ uses compiler encodings, including typed objects and blocks.
template <typename T> struct objc_hook_type {
    static const char *encoding() {
#ifdef __OBJC__
        return @encode(T);
#else
        using V = std::remove_cv_t<T>;
        if constexpr (std::is_void_v<V>) return "v";
        else if constexpr (std::is_same_v<V, id>) return "@";
        else if constexpr (std::is_same_v<V, Class>) return "#";
        else if constexpr (std::is_same_v<V, SEL>) return ":";
        else if constexpr (std::is_same_v<V, bool>) return "B";
        else if constexpr (std::is_integral_v<V>) {
            if constexpr (sizeof(V) == 1) return std::is_signed_v<V> ? "c" : "C";
            else if constexpr (sizeof(V) == 2) return std::is_signed_v<V> ? "s" : "S";
            else if constexpr (sizeof(V) == 4) return std::is_signed_v<V> ? "i" : "I";
            else return std::is_signed_v<V> ? "q" : "Q";
        } else if constexpr (std::is_same_v<V, float>) return "f";
        else if constexpr (std::is_same_v<V, double>) return "d";
        else if constexpr (std::is_pointer_v<V>) return "^v";
        else static_assert(!sizeof(V), "Provide objc_hook_type<T>::encoding() for this C value type.");
#endif
    }
};

struct objc_hook_options {
    bool class_method = false;
    bool requires_main_thread = false;
    std::optional<bool> returns_retained;
    std::optional<bool> consumes_receiver;
    /// Converted to a weak filter at installation; no isa substitution.
    id object_filter = nullptr;
    /// Used only when first publishing the method's permanent fallback entry.
    id fallback_owner = nullptr;
};
enum class objc_hook_status { invalidated = ABIObjCHookInvalidated, active = ABIObjCHookActive, displaced = ABIObjCHookDisplaced };

/// Copies share one owned C reference. Explicit invalidation affects all copies;
/// destroying the last owner invalidates without waiting for current snapshots.
class objc_hook_handle final {
public:
    objc_hook_handle() = default;
    static objc_hook_handle adopt(ABIObjCMethodHook *owned) { return objc_hook_handle(owned); }
    static objc_hook_handle retain(ABIObjCMethodHook *borrowed) { return adopt(ABIRetainObjCMethodHook(borrowed)); }
    ABIObjCMethodHook *native_handle() const noexcept { return handle_.get(); }
    explicit operator bool() const noexcept { return bool(handle_); }
    objc_hook_status status() const noexcept { return static_cast<objc_hook_status>(ABIObjCMethodHookStatus(handle_.get())); }
    void invalidate() const noexcept { ABIInvalidateObjCMethodHook(handle_.get()); }
private:
    explicit objc_hook_handle(ABIObjCMethodHook *owned) : handle_(owned, ABIReleaseObjCMethodHook) {}
    std::shared_ptr<ABIObjCMethodHook> handle_;
};

namespace detail {
inline void hook_require(bool success, ABIResolutionFailure *owned) {
    std::unique_ptr<ABIResolutionFailure, decltype(&ABIReleaseResolutionFailure)> error(owned, ABIReleaseResolutionFailure);
    if (!success) throw resolution_error(error ? ABIResolutionFailureCode(error.get()) : ABIFailureOther,
        error ? ABIResolutionFailureMessage(error.get()) : "The native hook operation failed.");
}
inline void *hook_object_pointer(
#ifdef __OBJC__
    __unsafe_unretained id object
#else
    id object
#endif
) {
#ifdef __OBJC__
    return (__bridge void *)object;
#else
    return reinterpret_cast<void *>(object);
#endif
}
inline ABIObjCHookOptions hook_options(const objc_hook_options& options) {
    return {options.class_method, options.requires_main_thread,
        options.returns_retained ? (*options.returns_retained ? 2 : 1) : 0,
        options.consumes_receiver ? (*options.consumes_receiver ? 2 : 1) : 0,
        hook_object_pointer(options.object_filter), hook_object_pointer(options.fallback_owner)};
}
#ifdef __OBJC__
template <typename T> struct hook_objc_value : std::bool_constant<std::is_convertible_v<T, id>> {};
template <typename R, typename... A> struct hook_objc_value<R (^)(A...)> : std::true_type {};
#endif
template <typename T> ABIObjCHookValueType hook_type() {
    static_assert(!std::is_reference_v<T>, "Use explicit pointer types for reference ABIs.");
    if constexpr (std::is_void_v<T>) return {"v", 0, 1};
    else {
        #ifdef __OBJC__
        static_assert(std::is_trivially_copyable_v<T> || hook_objc_value<T>::value, "Nontrivial values need an ABI adapter.");
#else
        static_assert(std::is_trivially_copyable_v<T>, "Nontrivial values need an ABI adapter.");
#endif
        return {objc_hook_type<T>::encoding(), sizeof(T), alignof(T)};
    }
}
template <typename T, typename Read> T hook_read(Read&& read) {
#ifdef __OBJC__
    if constexpr (hook_objc_value<T>::value) {
        __unsafe_unretained T value = nullptr;
        read(&value, sizeof(T));
        return value;
    } else
#endif
    {
        T value{};
        read(&value, sizeof(T));
        return value;
    }
}
inline std::string hook_selector(std::string_view value) {
    if (value.find('\0') != std::string_view::npos)
        throw resolution_error(ABIFailureInvalidRequest, "A selector must not contain embedded NULs.");
    return std::string(value);
}
template <typename R, typename... A> struct hook_signature {
    std::array<ABIObjCHookValueType, sizeof...(A)> parameters{hook_type<A>()...};
    ABIObjCHookSignature value{hook_type<R>(), parameters.data(), parameters.size()};
};
// No C++ exception leaves a callback trampoline. Failure notifications themselves
// must be noexcept; their C counterpart has the same non-unwinding contract.
template <typename Body> bool hook_callback(Body&& body, ABIResolutionFailure **error) noexcept {
    try { body(); return true; }
    catch (const resolution_error& failure) { *error = ABICreateResolutionFailure(failure.code(), failure.what()); }
    catch (const std::exception& failure) { *error = ABICreateResolutionFailure(ABIFailureOther, failure.what()); }
    catch (...) { *error = ABICreateResolutionFailure(ABIFailureOther, "A C++ hook callback threw an exception."); }
    return false;
}
template <typename Signature> struct hook_installer;
}

template <typename Signature> class objc_hook_invocation;
/// A noncopyable view valid on the original callback thread. Taking its address
/// does not extend the lifetime; storing an escaped C/C++ reference is invalid.
template <typename R, typename... A> class objc_hook_invocation<R(A...)> final {
public:
    objc_hook_invocation(const objc_hook_invocation&) = delete;
    objc_hook_invocation& operator=(const objc_hook_invocation&) = delete;
    objc_hook_invocation(objc_hook_invocation&&) = delete;
    id receiver() const {
        ABIResolutionFailure *error = nullptr;
        void *value = ABIObjCHookReceiver(call_, &error);
        detail::hook_require(error == nullptr, error);
#ifdef __OBJC__
        return (__bridge id)value;
#else
        return reinterpret_cast<id>(value);
#endif
    }
    /// Calls the next snapshot member with explicit arguments. Object results
    /// remain borrowed for this callback in MRC/pure C++; retain/copy if escaping.
    R proceed(A... arguments) const {
        const std::array<const void *, sizeof...(A)> pointers{std::addressof(arguments)...};
        ABIResolutionFailure *error = nullptr;
        const bool success = ABIObjCHookProceed(call_, pointers.data(), pointers.size(), &error);
        detail::hook_require(success, error);
        if constexpr (!std::is_void_v<R>) {
            return detail::hook_read<R>([&](void *value, size_t size) {
                ABIResolutionFailure *error = nullptr;
                const bool success = ABIObjCHookReadResult(call_, value, size, &error);
                detail::hook_require(success, error);
            });
        }
    }
private:
    friend struct detail::hook_installer<R(A...)>;
    explicit objc_hook_invocation(ABIObjCHookInvocation *call) : call_(call) {}
    ABIObjCHookInvocation *call_;
};

namespace detail {
template <typename R, typename... A> struct hook_installer<R(A...)> {
    template <typename Body, typename OnFailure> struct method_state {
        Body body;
        OnFailure failure;
        static void release(void *context) noexcept { delete static_cast<method_state *>(context); }
        static void failed(void *context, const ABIResolutionFailure *error) noexcept {
            static_cast<method_state *>(context)->failure(resolution_error(ABIResolutionFailureCode(error), ABIResolutionFailureMessage(error)));
        }
        template <size_t... I> R invoke(ABIObjCHookInvocation *raw, std::index_sequence<I...>) {
            objc_hook_invocation<R(A...)> call(raw);
            return std::invoke(body, call, hook_read<A>([&](void *value, size_t size) {
                ABIResolutionFailure *error = nullptr;
                const bool success = ABIObjCHookReadArgument(raw, I, value, size, &error);
                hook_require(success, error);
            })...);
        }
        static bool callback(void *context, ABIObjCHookInvocation *call, ABIResolutionFailure **error) noexcept {
            return hook_callback([&] {
                auto& state = *static_cast<method_state *>(context);
                ABIResolutionFailure *failure = nullptr;
                bool success;
                if constexpr (std::is_void_v<R>) {
                    state.invoke(call, std::index_sequence_for<A...>{});
                    success = ABIObjCHookSetResult(call, nullptr, 0, &failure);
                } else {
                    R result = state.invoke(call, std::index_sequence_for<A...>{});
                    success = ABIObjCHookSetResult(call, &result, sizeof(R), &failure);
                }
                hook_require(success, failure);
            }, error);
        }
    };
    template <typename Body, typename OnFailure>
    static objc_hook_handle method(Class type, std::string_view selector, Body&& body, OnFailure&& failure, objc_hook_options options) {
        static_assert(std::is_nothrow_invocable_v<OnFailure&, const resolution_error&>, "The failure callback must be noexcept.");
        const auto name = hook_selector(selector);
        hook_signature<R, A...> signature;
        using State = method_state<std::decay_t<Body>, std::decay_t<OnFailure>>;
        auto state = std::make_unique<State>(std::forward<Body>(body), std::forward<OnFailure>(failure));
        ABIResolutionFailure *error = nullptr;
        auto *hook = ABIInstallObjCMethodHook(type, name.c_str(), &signature.value, hook_options(options),
            state.release(), State::callback, State::failed, State::release, &error);
        hook_require(hook != nullptr, error);
        return objc_hook_handle::adopt(hook);
    }

    template <typename Before, typename After, typename OnFailure> struct initializer_state {
        Before before;
        After after;
        OnFailure failure;
        static void release(void *context) noexcept { delete static_cast<initializer_state *>(context); }
        static void failed(void *context, const ABIResolutionFailure *error) noexcept {
            static_cast<initializer_state *>(context)->failure(resolution_error(ABIResolutionFailureCode(error), ABIResolutionFailureMessage(error)));
        }
        template <size_t... I> void prepare(ABIObjCInitializerArguments *arguments, std::index_sequence<I...>) {
            if constexpr (!std::is_same_v<Before, std::nullptr_t>) {
                auto values = std::tuple<A...>{hook_read<A>([&](void *value, size_t size) {
                    ABIResolutionFailure *error = nullptr;
                    const bool success = ABIObjCInitializerReadArgument(arguments, I, value, size, &error);
                    hook_require(success, error);
                })...};
                using Output = std::invoke_result_t<Before&, A...>;
                if constexpr (std::is_void_v<Output>) std::apply(before, values);
                else {
                    static_assert(std::is_constructible_v<std::tuple<A...>, Output>,
                        "Return the argument tuple, or a convertible value for one argument.");
                    std::tuple<A...> changed(std::apply(before, values));
                    (set(arguments, I, std::get<I>(changed)), ...);
                }
            }
        }
        template <typename T> static void set(ABIObjCInitializerArguments *arguments, size_t index, const T& value) {
            ABIResolutionFailure *error = nullptr;
            const bool success = ABIObjCInitializerSetArgument(arguments, index, &value, sizeof(T), &error);
            hook_require(success, error);
        }
        static bool preparing(void *context, ABIObjCInitializerArguments *arguments, ABIResolutionFailure **error) noexcept {
            return hook_callback([&] { static_cast<initializer_state *>(context)->prepare(arguments, std::index_sequence_for<A...>{}); }, error);
        }
        static bool initialized(void *context, void *object, ABIResolutionFailure **error) noexcept {
            return hook_callback([&] {
                if constexpr (!std::is_same_v<After, std::nullptr_t>) {
                    R result = hook_read<R>([&](void *value, size_t size) { std::memcpy(value, &object, size); });
                    std::invoke(static_cast<initializer_state *>(context)->after, result);
                }
            }, error);
        }
    };
    template <typename Before, typename After, typename OnFailure>
    static objc_hook_handle initializer(Class type, std::string_view selector, Before&& before, After&& after, OnFailure&& failure, objc_hook_options options) {
        static_assert(std::is_nothrow_invocable_v<OnFailure&, const resolution_error&>, "The failure callback must be noexcept.");
        const auto name = hook_selector(selector);
        hook_signature<R, A...> signature;
        using State = initializer_state<std::decay_t<Before>, std::decay_t<After>, std::decay_t<OnFailure>>;
        auto state = std::make_unique<State>(std::forward<Before>(before), std::forward<After>(after), std::forward<OnFailure>(failure));
        ABIResolutionFailure *error = nullptr;
        auto *hook = ABIInstallObjCInitializerHook(type, name.c_str(), &signature.value, hook_options(options), state.release(),
            State::preparing, State::initialized, State::failed, State::release, &error);
        hook_require(hook != nullptr, error);
        return objc_hook_handle::adopt(hook);
    }
};
}

/// Installs a synchronous ordinary-method callback. The callback receives a
/// scoped invocation followed by its typed explicit arguments. Callback C++
/// exceptions become reported hook failures; foreign native unwinding is unsupported.
template <typename Signature, typename Body, typename OnFailure>
objc_hook_handle objc_method_hook(Class type, std::string_view selector, Body&& body, OnFailure&& failure, objc_hook_options options = {}) {
    return detail::hook_installer<Signature>::method(type, selector, std::forward<Body>(body), std::forward<OnFailure>(failure), options);
}
/// Before may observe (void), return an argument tuple, or return one value for
/// one argument. After receives only the initialized object. nullptr omits a phase.
/// Native initialization is automatic and cannot be repeated or replaced here.
template <typename Signature, typename Before, typename After, typename OnFailure>
objc_hook_handle objc_initializer_hook(Class type, std::string_view selector, Before&& before, After&& after, OnFailure&& failure, objc_hook_options options = {}) {
    return detail::hook_installer<Signature>::initializer(type, selector, std::forward<Before>(before), std::forward<After>(after), std::forward<OnFailure>(failure), options);
}
/// Identity-filtered instance hook; the registration retains only a weak object
/// reference. The caller must keep the receiver alive through installation.
template <typename Signature, typename Body, typename OnFailure>
objc_hook_handle objc_object_hook(id object, std::string_view selector, Body&& body, OnFailure&& failure, objc_hook_options options = {}) {
    options.object_filter = object;
    options.class_method = false;
    return objc_method_hook<Signature>(object_getClass(object), selector, std::forward<Body>(body), std::forward<OnFailure>(failure), options);
}
/// A reusable declaration for coordinated installation. Copies share callback
/// storage; retaining a request retains its captures independently of handles.
class objc_hook_request final {
public:
    template <typename Signature, typename Body, typename OnFailure>
    static objc_hook_request method(Class type, std::string_view selector, Body&& body, OnFailure&& failure, objc_hook_options options = {}) {
        static_assert(std::is_nothrow_invocable_v<OnFailure&, const resolution_error&>, "The failure callback must be noexcept.");
        using State = typename detail::hook_installer<Signature>::template method_state<std::decay_t<Body>, std::decay_t<OnFailure>>;
        return make<Signature>(type, selector, options, false,
            std::make_shared<State>(std::forward<Body>(body), std::forward<OnFailure>(failure)));
    }
    template <typename Signature, typename Before, typename After, typename OnFailure>
    static objc_hook_request initializer(Class type, std::string_view selector, Before&& before, After&& after, OnFailure&& failure, objc_hook_options options = {}) {
        static_assert(std::is_nothrow_invocable_v<OnFailure&, const resolution_error&>, "The failure callback must be noexcept.");
        using State = typename detail::hook_installer<Signature>::template initializer_state<std::decay_t<Before>, std::decay_t<After>, std::decay_t<OnFailure>>;
        return make<Signature>(type, selector, options, true,
            std::make_shared<State>(std::forward<Before>(before), std::forward<After>(after), std::forward<OnFailure>(failure)));
    }
private:
    template <typename Signature> struct signature_storage;
    template <typename R, typename... A> struct signature_storage<R(A...)> : detail::hook_signature<R, A...> {};
    template <typename State> struct shared_context {
        std::shared_ptr<State> state;
        static void release(void *raw) noexcept { delete static_cast<shared_context *>(raw); }
        static void failed(void *raw, const ABIResolutionFailure *error) noexcept { State::failed(static_cast<shared_context *>(raw)->state.get(), error); }
    };
    template <typename Signature, typename State>
    static objc_hook_request make(Class type, std::string_view selector, objc_hook_options options, bool initializer, std::shared_ptr<State> state) {
        auto name = detail::hook_selector(selector);
        auto signature = std::make_shared<signature_storage<Signature>>();
        return objc_hook_request([type, name = std::move(name), options, signature, state, initializer] {
            using Context = shared_context<State>;
            auto context = std::make_unique<Context>(state);
            ABIObjCHookRequest request{};
            request.type = type; request.selector = name.c_str(); request.signature = &signature->value;
            request.options = detail::hook_options(options); request.initializer = initializer;
            request.context = context.get(); request.releaseContext = Context::release; request.onFailure = Context::failed;
            if constexpr (requires { State::callback; }) {
                request.callback = [](void *raw, ABIObjCHookInvocation *call, ABIResolutionFailure **error) noexcept {
                    return State::callback(static_cast<Context *>(raw)->state.get(), call, error);
                };
            } else {
                request.before = [](void *raw, ABIObjCInitializerArguments *arguments, ABIResolutionFailure **error) noexcept {
                    return State::preparing(static_cast<Context *>(raw)->state.get(), arguments, error);
                };
                request.after = [](void *raw, void *object, ABIResolutionFailure **error) noexcept {
                    return State::initialized(static_cast<Context *>(raw)->state.get(), object, error);
                };
            }
            context.release();
            return request;
        });
    }
    friend std::vector<objc_hook_handle> install_objc_hooks(const std::vector<objc_hook_request>&);
    explicit objc_hook_request(std::function<ABIObjCHookRequest()> make) : make_(std::move(make)) {}
    std::function<ABIObjCHookRequest()> make_;
};

/// A coordinated-installation failure retaining the original cause and partial
/// handles, already invalidated. Reading status does not require healthy ownership.
class objc_hook_installation_error final : public std::runtime_error {
public:
    objc_hook_installation_error(size_t index, int32_t phase, resolution_error cause, std::vector<objc_hook_handle> hooks)
        : std::runtime_error(cause.what()), index_(index), phase_(phase), cause_(std::move(cause)), hooks_(std::move(hooks)) {}
    size_t failed_index() const noexcept { return index_; }
    int32_t phase() const noexcept { return phase_; }
    const resolution_error& cause() const noexcept { return cause_; }
    const std::vector<objc_hook_handle>& invalidated_hooks() const noexcept { return hooks_; }
private:
    size_t index_;
    int32_t phase_;
    resolution_error cause_;
    std::vector<objc_hook_handle> hooks_;
};

/// Validates all requests before installation, then returns ordinary handles in
/// order. On failure throws objc_hook_installation_error after logical rollback.
/// Cross-method visibility is not atomic; published pass-through entries remain.
inline std::vector<objc_hook_handle> install_objc_hooks(const std::vector<objc_hook_request>& requests) {
    std::vector<ABIObjCHookRequest> native;
    native.reserve(requests.size());
    try { for (const auto& request : requests) native.push_back(request.make_()); }
    catch (...) { for (const auto& request : native) request.releaseContext(request.context); throw; }
    std::unique_ptr<ABIObjCHookInstallation, decltype(&ABIReleaseObjCHookInstallation)> installation(
        ABIInstallObjCHooks(native.data(), native.size()), ABIReleaseObjCHookInstallation);
    std::vector<objc_hook_handle> handles;
    try {
        for (size_t index = 0; index < ABIObjCHookInstallationCount(installation.get()); ++index)
            handles.push_back(objc_hook_handle::retain(ABIObjCHookInstallationGet(installation.get(), index)));
    } catch (...) { ABIInvalidateObjCHookInstallation(installation.get()); throw; }
    if (const auto *error = ABIObjCHookInstallationFailure(installation.get())) {
        throw objc_hook_installation_error(ABIObjCHookInstallationFailedIndex(installation.get()),
            ABIObjCHookInstallationPhase(installation.get()),
            resolution_error(ABIResolutionFailureCode(error), ABIResolutionFailureMessage(error)), std::move(handles));
    }
    return handles;
}

}
