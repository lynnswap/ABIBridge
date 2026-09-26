#import <ABIBridgeObjCXX/Replacement.h>
#include <ABIBridge/ObjectiveCHooks.h>
#include <algorithm>
#include <cstring>
#include <cstddef>
#include <memory>
#include <map>
#include <optional>
#include <pthread.h>
#include <string>
#include <vector>

namespace {
using Failure = std::unique_ptr<ABIResolutionFailure, decltype(&ABIReleaseResolutionFailure)>;
using Type = std::unique_ptr<ABIValueType, decltype(&ABIReleaseValueType)>;
using Binding = std::unique_ptr<ABIObjCInvocation, decltype(&ABIReleaseObjCInvocation)>;
using Interface = std::unique_ptr<ABICallInterface, decltype(&ABIReleaseCallInterface)>;
bool fail(ABIResolutionFailure **error, int32_t code, const char *message) {
    if (error) *error = ABICreateResolutionFailure(code, message);
    return false;
}
bool fail(ABIResolutionFailure **error, NSError *value) {
    int32_t code = value ? static_cast<int32_t>(value.code) : ABIFailureOther;
    if ([value.domain isEqualToString:ABIObjCMethodHookErrorDomain]) {
        code = value.code == 1 ? ABIFailureHookDisplaced
            : value.code == 2 ? ABIFailureUnsupportedDeclaration : ABIFailureSignatureMismatch;
    }
    return fail(error, code, value.localizedDescription.UTF8String ?: "Objective-C hook operation failed.");
}
const char *unqualified(const char *type) {
    while (*type && std::strchr("rnNoORV", *type)) ++type;
    return type;
}
bool compatible(const char *expected, const char *actual) {
    expected = unqualified(expected); actual = unqualified(actual);
    if (std::strcmp(expected, actual) == 0) return true;
    if (*expected == '@' && *actual == '@') return (expected[1] == '?') == (actual[1] == '?');
    if (*expected == 'B' && *actual == 'c') return true;
    if ((*expected == '^' || *expected == '*') && (*actual == '^' || *actual == '*')) return true;
    // Platform integer typedefs may use different spellings for the same width.
    return (std::strchr("csilq", *expected) && std::strchr("csilq", *actual))
        || (std::strchr("CSILQ", *expected) && std::strchr("CSILQ", *actual));
}
struct ValueInfo {
    size_t size;
    bool boolean;
    bool object;
    bool block;
    bool classObject;
};
std::optional<ValueInfo> prepareType(const ABIObjCHookValueType& requested, const char *actual,
    Type& type, ABIResolutionFailure **error) {
    if (!requested.encoding || !*requested.encoding || !requested.alignment) {
        fail(error, ABIFailureInvalidRequest, "A type encoding and storage alignment are required."); return {};
    }
    Type expected(ABICopyObjCHookValueType(requested.encoding, error), ABIReleaseValueType);
    if (!expected) return {};
    if (requested.size != ABIValueTypeSize(expected.get()) || requested.alignment != ABIValueTypeAlignment(expected.get())) {
        fail(error, ABIFailureSignatureMismatch, "The requested encoding and storage layout disagree."); return {};
    }
    if (!compatible(requested.encoding, actual)) {
        fail(error, ABIFailureSignatureMismatch, "The requested Objective-C encoding does not match the method."); return {};
    }
    type.reset(ABICopyObjCHookValueType(actual, error));
    if (!type) return {};
    if (requested.size != ABIValueTypeSize(type.get()) || requested.alignment != ABIValueTypeAlignment(type.get())) {
        fail(error, ABIFailureSignatureMismatch, "The declared storage layout does not match the method ABI."); return {};
    }
    actual = unqualified(actual);
    return ValueInfo{requested.size, *unqualified(requested.encoding) == 'B',
        *actual == '@' || *actual == '#', *actual == '@' && actual[1] == '?', *actual == '#'};
}
struct OwnedValue {
    std::vector<std::max_align_t> data;
    CFTypeRef object = nullptr;
    explicit OwnedValue(size_t size) : data((std::max(size, sizeof(void *)) + sizeof(std::max_align_t) - 1) / sizeof(std::max_align_t)) {}
    ~OwnedValue() { if (object) CFRelease(object); }
    OwnedValue(const OwnedValue&) = delete;
    OwnedValue& operator=(const OwnedValue&) = delete;
};
std::unique_ptr<OwnedValue> copyValue(const ValueInfo& info, const void *bytes, size_t size, ABIResolutionFailure **error) {
    if (size != info.size || (size && !bytes)) {
        fail(error, ABIFailureInvalidRequest, "Value storage must match the declared size."); return nullptr;
    }
    auto result = std::make_unique<OwnedValue>(size);
    if (size) std::memcpy(result->data.data(), bytes, size);
    if (info.object) {
        void *object = nullptr;
        std::memcpy(&object, bytes, sizeof(object));
        if (object) {
            if (info.classObject && !object_isClass((__bridge id)object)) {
                fail(error, ABIFailureSignatureMismatch, "A Class value requires a runtime class object."); return nullptr;
            }
            result->object = info.block ? ABICopyObjCBlock(object) : CFRetain(object);
            if (!result->object) {
                fail(error, ABIFailureSignatureMismatch, "A block value requires a live Objective-C block."); return nullptr;
            }
            std::memcpy(result->data.data(), &result->object, sizeof(object));
        }
    } else if (info.boolean) {
        const uint8_t normalized = *static_cast<const uint8_t *>(bytes) != 0;
        std::memcpy(result->data.data(), &normalized, sizeof(normalized));
    }
    return result;
}
struct State {
    void *context;
    ABIObjCHookContextRelease release;
    ABIObjCHookFailureHandler failure;
    ABIObjCHookCallback method = nullptr;
    ABIObjCInitializerBefore before = nullptr;
    ABIObjCInitializerAfter after = nullptr;
    bool initializer;
    bool mainThread;
    bool retained = false;
    bool consumed = false;
    ValueInfo result{};
    std::vector<ValueInfo> parameters;
    State(void *context, ABIObjCHookContextRelease release, ABIObjCHookFailureHandler failure,
          bool initializer, bool mainThread)
        : context(context), release(release), failure(failure), initializer(initializer), mainThread(mainThread) {}
    ~State() { release(context); }
    void report(ABIResolutionFailure *owned) {
        Failure error(owned ?: ABICreateResolutionFailure(ABIFailureOther, "The native hook callback failed."), ABIReleaseResolutionFailure);
        failure(context, error.get());
    }
};
struct Scope {
    State& state;
    ABIObjCReplacementCall *call;
    pthread_t thread = pthread_self();
    std::vector<CFTypeRef> objects;
    Scope(State& state, ABIObjCReplacementCall *call) : state(state), call(call) {}
    ~Scope() { for (auto value : objects) CFRelease(value); }
};
bool check(Scope *scope, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!scope) return fail(error, ABIFailureInvalidRequest, "A live callback context is required.");
    if (!pthread_equal(scope->thread, pthread_self()))
        return fail(error, ABIFailureWrongThread, "Use the context on its callback's original thread.");
    return true;
}
bool readArgument(Scope *scope, size_t index, void *value, size_t size, ABIResolutionFailure **error) {
    if (!check(scope, error)) return false;
    if (index >= scope->state.parameters.size() || !value || size != scope->state.parameters[index].size)
        return fail(error, ABIFailureInvalidRequest, "Argument index and storage size must match the signature.");
    const auto& info = scope->state.parameters[index];
    const void *source = ABIObjCReplacementArgument(scope->call, index);
    std::memcpy(value, source, size);
    if (info.boolean) *static_cast<uint8_t *>(value) = *static_cast<const uint8_t *>(source) != 0;
    return true;
}
bool belongsTo(id object, Class type) {
    for (Class current = object_getClass(object); current; current = class_getSuperclass(current))
        if (current == type) return true;
    return false;
}
}

struct ABIObjCHookInvocation : Scope {
    std::unique_ptr<OwnedValue> pending;
    using Scope::Scope;
};
struct ABIObjCInitializerArguments : Scope {
    std::vector<std::unique_ptr<OwnedValue>> replacements;
    ABIObjCInitializerArguments(State& state, ABIObjCReplacementCall *call)
        : Scope(state, call), replacements(state.parameters.size()) {}
};

void *ABIObjCHookReceiver(ABIObjCHookInvocation *invocation, ABIResolutionFailure **error) {
    if (!check(invocation, error)) return nullptr;
    return ABIObjCReplacementReceiver(invocation->call);
}
bool ABIObjCHookReadArgument(ABIObjCHookInvocation *invocation, size_t index,
    void *value, size_t size, ABIResolutionFailure **error) {
    return readArgument(invocation, index, value, size, error);
}
bool ABIObjCHookProceed(ABIObjCHookInvocation *invocation, const void *const *arguments,
    size_t count, ABIResolutionFailure **error) {
    if (!check(invocation, error)) return false;
    if ((!arguments && count) || (arguments && count != invocation->state.parameters.size()))
        return fail(error, ABIFailureInvalidRequest, "Supply all explicit arguments, or null/zero to reuse the incoming arguments.");
    for (size_t index = 0; index < count; ++index)
        if (!arguments[index]) return fail(error, ABIFailureInvalidRequest, "Each argument needs value storage.");
    NSError *failure = nil;
    return ABIObjCReplacementProceed(invocation->call, arguments, &failure) || fail(error, failure);
}
bool ABIObjCHookReadResult(ABIObjCHookInvocation *invocation, void *value, size_t size, ABIResolutionFailure **error) {
    if (!check(invocation, error)) return false;
    const auto& info = invocation->state.result;
    if (size != info.size || (size && !value)) return fail(error, ABIFailureInvalidRequest, "Result storage must match the declared size.");
    OwnedValue temporary(size);
    NSError *failure = nil;
    if (!ABICopyObjCReplacementResult(invocation->call, temporary.data.data(), &failure)) return fail(error, failure);
    if (info.object) {
        CFTypeRef object = nullptr;
        std::memcpy(&object, temporary.data.data(), sizeof(object));
        if (object) invocation->objects.push_back(object);
    }
    if (size) std::memcpy(value, temporary.data.data(), size);
    if (info.boolean) *static_cast<uint8_t *>(value) = *static_cast<uint8_t *>(value) != 0;
    return true;
}
bool ABIObjCHookSetResult(ABIObjCHookInvocation *invocation, const void *value, size_t size, ABIResolutionFailure **error) {
    if (!check(invocation, error)) return false;
    auto pending = copyValue(invocation->state.result, value, size, error);
    if (!pending) return false;
    invocation->pending = std::move(pending);
    return true;
}
bool ABIObjCInitializerReadArgument(ABIObjCInitializerArguments *arguments, size_t index,
    void *value, size_t size, ABIResolutionFailure **error) {
    if (!check(arguments, error)) return false;
    if (index >= arguments->state.parameters.size() || !value || size != arguments->state.parameters[index].size)
        return fail(error, ABIFailureInvalidRequest, "Argument index and storage size must match the signature.");
    if (arguments->replacements[index]) {
        std::memcpy(value, arguments->replacements[index]->data.data(), size);
        return true;
    }
    return readArgument(arguments, index, value, size, error);
}
bool ABIObjCInitializerSetArgument(ABIObjCInitializerArguments *arguments, size_t index,
    const void *value, size_t size, ABIResolutionFailure **error) {
    if (!check(arguments, error)) return false;
    if (index >= arguments->state.parameters.size()) return fail(error, ABIFailureInvalidRequest, "Argument index exceeds the signature.");
    auto replacement = copyValue(arguments->state.parameters[index], value, size, error);
    if (!replacement) return false;
    arguments->replacements[index] = std::move(replacement);
    return true;
}

namespace {
void invoke(State& state, ABIObjCReplacementCall *call) {
    if (state.mainThread && !NSThread.isMainThread) {
        state.report(ABICreateResolutionFailure(ABIFailureWrongThread, "The hook requires the main thread.")); return;
    }
    ABIResolutionFailure *error = nullptr;
    if (!state.initializer) {
        ABIObjCHookInvocation invocation(state, call);
        const bool succeeded = state.method(state.context, &invocation, &error);
        Failure reported(error, ABIReleaseResolutionFailure);
        if (!succeeded) { state.report(reported.release()); return; }
        if (invocation.pending) {
            NSError *failure = nil;
            if (!ABISetObjCReplacementResult(call, invocation.pending->data.data(), &failure)) {
                ABIResolutionFailure *error = nullptr; fail(&error, failure); state.report(error);
            }
        }
        return;
    }
    ABIObjCInitializerArguments arguments(state, call);
    if (state.before) {
        const bool succeeded = state.before(state.context, &arguments, &error);
        Failure reported(error, ABIReleaseResolutionFailure);
        if (!succeeded) { state.report(reported.release()); return; }
    }
    std::vector<const void *> values;
    for (size_t index = 0; index < state.parameters.size(); ++index) {
        values.push_back(arguments.replacements[index] ? arguments.replacements[index]->data.data()
            : ABIObjCReplacementArgument(call, index));
    }
    NSError *failure = nil;
    if (!ABIObjCReplacementProceed(call, values.data(), &failure)) {
        fail(&error, failure); state.report(error); return;
    }
    if (state.after) {
        void *initialized = nullptr;
        if (!ABICopyObjCReplacementResult(call, &initialized, &failure)) {
            fail(&error, failure); state.report(error); return;
        }
        // Only the actual initialized object is bridged/owned by postprocessing.
        __attribute__((objc_precise_lifetime)) id result = CFBridgingRelease(initialized);
        error = nullptr;
        const bool succeeded = state.after(state.context, (__bridge void *)result, &error);
        Failure reported(error, ABIReleaseResolutionFailure);
        if (!succeeded) state.report(reported.release());
    }
}
bool prepare(Class type, const char *name, const ABIObjCHookSignature *signature,
    ABIObjCHookOptions options, State& state, Binding& binding, Interface& interface, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!type || !object_isClass((id)type) || !name || !*name || !signature || !state.failure ||
        (signature->parameterCount && !signature->parameters) ||
        options.resultOwnership < 0 || options.resultOwnership > 2 ||
        options.receiverOwnership < 0 || options.receiverOwnership > 2) {
        fail(error, ABIFailureInvalidRequest, "A class, selector, signature, failure handler, and valid ownership options are required."); return false;
    }
    if ((state.initializer && options.classMethod) || (options.object && (state.initializer || options.classMethod))) {
        fail(error, ABIFailureUnsupportedDeclaration, "Object filters require ordinary instance methods; initializer hooks require instance initialization."); return false;
    }
    if (options.object && !belongsTo((__bridge id)options.object, type)) {
        fail(error, ABIFailureSignatureMismatch, "The object filter does not belong to the target class."); return false;
    }
    SEL selector = sel_registerName(name);
    NSError *failure = nil;
    binding.reset(ABICopyObjCImplementation(type, selector, options.classMethod,
        options.resultOwnership - 1, options.receiverOwnership - 1, &failure));
    if (!binding) {
        if (ABIObjCMethodHookIsDisplaced(type, selector, options.classMethod))
            fail(error, ABIFailureHookDisplaced, "Another writer displaced the managed entry.");
        else fail(error, failure);
        return false;
    }
    if (signature->parameterCount != ABIObjCInvocationParameterCount(binding.get())) {
        fail(error, ABIFailureSignatureMismatch, "The parameter count does not match the method."); return false;
    }
    Type result(nullptr, ABIReleaseValueType);
    const auto resultInfo = prepareType(signature->result, ABIObjCInvocationResultType(binding.get()), result, error);
    if (!resultInfo) return false;
    state.result = *resultInfo;
    state.parameters.clear();
    std::vector<Type> types;
    Type pointer(ABICreateScalarType(ABIValuePointer, error), ABIReleaseValueType);
    if (!pointer) return false;
    std::vector<const ABIValueType *> parameters{pointer.get(), pointer.get()};
    for (size_t index = 0; index < signature->parameterCount; ++index) {
        Type type(nullptr, ABIReleaseValueType);
        auto info = prepareType(signature->parameters[index], ABIObjCInvocationParameterType(binding.get(), index), type, error);
        if (!info) return false;
        state.parameters.push_back(*info);
        parameters.push_back(type.get()); types.push_back(std::move(type));
    }
    interface.reset(ABICreateCCallInterface(result.get(), parameters.data(), parameters.size(), error));
    if (!interface) return false;
    if (!ABIValidateObjCMethodHook(type, selector, options.classMethod, state.initializer,
        binding.get(), (__bridge id)options.object, &failure)) return fail(error, failure);
    state.retained = ABIObjCInvocationReturnsRetained(binding.get());
    state.consumed = ABIObjCInvocationConsumesReceiver(binding.get());
    return true;
}

ABIObjCMethodHook *install(Class type, const char *name, const ABIObjCHookSignature *signature,
    ABIObjCHookOptions options, std::unique_ptr<State> state, ABIResolutionFailure **error) {
    Binding binding(nullptr, ABIReleaseObjCInvocation);
    Interface interface(nullptr, ABIReleaseCallInterface);
    if (!prepare(type, name, signature, options, *state, binding, interface, error)) return nullptr;
    const bool initializer = state->initializer;
    SEL selector = sel_registerName(name);
    NSError *failure = nil;
    // The managed boundary takes ownership on success and failure.
    auto *context = state.release();
    auto *hook = ABICreateObjCMethodHook(type, selector, options.classMethod, initializer, binding.get(), interface.get(),
        [](void *context, ABIObjCReplacementCall *call) { invoke(*static_cast<State *>(context), call); }, context,
        [](void *context) { delete static_cast<State *>(context); },
        (__bridge id)options.object, (__bridge id)options.fallbackOwner, &failure);
    if (!hook) fail(error, failure);
    return hook;
}
}

ABIObjCMethodHook *ABIInstallObjCMethodHook(Class type, const char *selector, const ABIObjCHookSignature *signature,
    ABIObjCHookOptions options, void *context, ABIObjCHookCallback callback,
    ABIObjCHookFailureHandler onFailure, ABIObjCHookContextRelease releaseContext, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!releaseContext) { fail(error, ABIFailureInvalidRequest, "A context release callback is required."); return nullptr; }
    auto state = std::make_unique<State>(context, releaseContext, onFailure, false, options.requiresMainThread);
    if (!callback) { fail(error, ABIFailureInvalidRequest, "An ordinary method callback is required."); return nullptr; }
    state->method = callback;
    return install(type, selector, signature, options, std::move(state), error);
}
ABIObjCMethodHook *ABIInstallObjCInitializerHook(Class type, const char *selector, const ABIObjCHookSignature *signature,
    ABIObjCHookOptions options, void *context, ABIObjCInitializerBefore before,
    ABIObjCInitializerAfter after, ABIObjCHookFailureHandler onFailure,
    ABIObjCHookContextRelease releaseContext, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!releaseContext) { fail(error, ABIFailureInvalidRequest, "A context release callback is required."); return nullptr; }
    auto state = std::make_unique<State>(context, releaseContext, onFailure, true, options.requiresMainThread);
    state->before = before; state->after = after;
    return install(type, selector, signature, options, std::move(state), error);
}

struct ABIObjCHookInstallation {
    std::vector<ABIObjCMethodHook *> hooks;
    Failure failure{nullptr, ABIReleaseResolutionFailure};
    size_t failedIndex = SIZE_MAX;
    int32_t phase = 0;
    ~ABIObjCHookInstallation() { for (auto *hook : hooks) ABIReleaseObjCMethodHook(hook); }
};

ABIObjCHookInstallation *ABIInstallObjCHooks(const ABIObjCHookRequest *requests, size_t count) {
    auto result = std::make_unique<ABIObjCHookInstallation>();
    auto failed = [&](size_t index, int32_t phase, ABIResolutionFailure *failure) {
        result->failedIndex = index; result->phase = phase; result->failure.reset(failure);
    };
    if (!requests && count) {
        failed(0, ABIObjCHookPreparation, ABICreateResolutionFailure(ABIFailureInvalidRequest, "A request table is required."));
        return result.release();
    }
    for (size_t index = 0; index < count; ++index) {
        if (!requests[index].releaseContext) {
            failed(index, ABIObjCHookPreparation, ABICreateResolutionFailure(ABIFailureInvalidRequest, "Every request needs a context release callback; no contexts were taken."));
            return result.release();
        }
    }
    struct Prepared {
        Binding binding{nullptr, ABIReleaseObjCInvocation};
        Interface interface{nullptr, ABIReleaseCallInterface};
        // Callback destruction may execute image code; destroy it before leases.
        std::unique_ptr<State> state;
        explicit Prepared(std::unique_ptr<State> state) : state(std::move(state)) {}
    };
    std::vector<Prepared> prepared;
    prepared.reserve(count);
    // Acquire every context before validating declarations, so cleanup includes
    // requests after the first failure as well as already-prepared requests.
    for (size_t index = 0; index < count; ++index) {
        const auto& request = requests[index];
        auto state = std::make_unique<State>(request.context, request.releaseContext, request.onFailure,
            request.initializer, request.options.requiresMainThread);
        state->method = request.callback; state->before = request.before; state->after = request.after;
        prepared.push_back(Prepared{std::move(state)});
    }
    std::map<std::pair<uintptr_t, std::string>, std::pair<bool, bool>> contracts;
    for (size_t index = 0; index < count; ++index) {
        const auto& request = requests[index];
        auto& value = prepared[index];
        ABIResolutionFailure *error = nullptr;
        if ((!request.initializer && !request.callback)
            || !prepare(request.type, request.selector, request.signature, request.options,
                *value.state, value.binding, value.interface, &error)) {
            failed(index, ABIObjCHookPreparation, error ?: ABICreateResolutionFailure(ABIFailureInvalidRequest, "An ordinary callback is required."));
            return result.release();
        }
        Class type = request.options.classMethod ? object_getClass(request.type) : request.type;
        auto key = std::make_pair(reinterpret_cast<uintptr_t>((__bridge void *)type), std::string(request.selector));
        const auto ownership = std::make_pair(value.state->retained, value.state->consumed);
        auto previous = contracts.find(key);
        if (previous != contracts.end() && previous->second != ownership) {
            failed(index, ABIObjCHookPreparation, ABICreateResolutionFailure(ABIFailureSignatureMismatch, "Requests for one method disagree on ownership."));
            return result.release();
        }
        contracts[key] = ownership;
    }
    for (size_t index = 0; index < count; ++index) {
        const auto& request = requests[index];
        ABIResolutionFailure *error = nullptr;
        // Reacquire the current predecessor: an earlier request may have
        // installed a superclass dispatcher since this request was validated.
        auto *hook = install(request.type, request.selector, request.signature, request.options,
            std::move(prepared[index].state), &error);
        if (!hook) {
            for (auto it = result->hooks.rbegin(); it != result->hooks.rend(); ++it) ABIInvalidateObjCMethodHook(*it);
            failed(index, ABIObjCHookActivation, error);
            return result.release();
        }
        result->hooks.push_back(hook);
    }
    return result.release();
}
void ABIInvalidateObjCHookInstallation(ABIObjCHookInstallation *installation) {
    if (installation) for (auto *hook : installation->hooks) ABIInvalidateObjCMethodHook(hook);
}
void ABIReleaseObjCHookInstallation(ABIObjCHookInstallation *installation) { delete installation; }
size_t ABIObjCHookInstallationCount(const ABIObjCHookInstallation *installation) { return installation->hooks.size(); }
ABIObjCMethodHook *ABIObjCHookInstallationGet(const ABIObjCHookInstallation *installation, size_t index) { return installation->hooks[index]; }
const ABIResolutionFailure *ABIObjCHookInstallationFailure(const ABIObjCHookInstallation *installation) { return installation->failure.get(); }
size_t ABIObjCHookInstallationFailedIndex(const ABIObjCHookInstallation *installation) { return installation->failedIndex; }
int32_t ABIObjCHookInstallationPhase(const ABIObjCHookInstallation *installation) { return installation->phase; }
