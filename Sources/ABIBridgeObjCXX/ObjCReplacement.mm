#import <ABIBridgeObjCXX/Replacement.h>
#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

namespace {
void fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:ABIObjCInvocationErrorDomain
        code:ABIFailureInvalidRequest userInfo:@{NSLocalizedDescriptionKey: message}];
}

struct Callback {
    ABIObjCReplacementHandler handler;
    void *context;
    ABIObjCReplacementDestroy destroy;
    ~Callback() { destroy(context); }
};
}

struct ABIObjCReplacement {
    ABIObjCInvocation *binding;
    ABICallInterface *interface;
    ABICallClosure *closure = nullptr;
    CFTypeRef fallbackOwner;
    std::mutex mutex;
    std::shared_ptr<Callback> callback;
    bool published = false;
    bool retainable;
    bool retained;
    bool consumed;
    size_t resultSize;

    ABIObjCReplacement(ABIObjCInvocation *binding, ABICallInterface *interface, id owner)
        : binding(binding), interface(interface), fallbackOwner(CFBridgingRetain(owner)),
          retained(ABIObjCInvocationReturnsRetained(binding)),
          consumed(ABIObjCInvocationConsumesReceiver(binding)),
          resultSize(ABIObjCInvocationResultSize(binding)) {
        ABIRetainObjCInvocation(binding);
        ABIRetainCallInterface(interface);
        const char *type = ABIObjCInvocationResultType(binding);
        while (*type && std::strchr("rnNoORV", *type)) ++type;
        retainable = *type == '@' || *type == '#';
    }
    ~ABIObjCReplacement() {
        ABIReleaseCallClosure(closure);
        ABIReleaseCallInterface(interface);
        if (fallbackOwner) CFRelease(fallbackOwner);
        ABIReleaseObjCInvocation(binding);
    }
};

struct ABIObjCReplacementCall {
    ABIObjCReplacement& entry;
    void *const *arguments;
    std::vector<std::max_align_t> result;
    bool completed = false;

    ABIObjCReplacementCall(ABIObjCReplacement& entry, void *const *arguments)
        : entry(entry), arguments(arguments),
          result((std::max(entry.resultSize, sizeof(void *)) + sizeof(std::max_align_t) - 1) / sizeof(std::max_align_t)) {}
    CFTypeRef object() const {
        CFTypeRef value = nullptr;
        std::memcpy(&value, result.data(), sizeof(value));
        return value;
    }
    void clear() {
        if (completed && entry.retainable && object()) CFRelease(object());
        completed = false;
    }
    ~ABIObjCReplacementCall() { clear(); }
};

ABIObjCReplacement *ABICreateObjCReplacement(ABIObjCInvocation *binding,
    ABICallInterface *interface, ABIObjCReplacementHandler handler, void *context,
    ABIObjCReplacementDestroy destroy, id fallbackOwner, NSError **error) {
    if (error) *error = nil;
    if (!binding || !interface || !handler || !destroy || !ABIObjCInvocationImplementation(binding)) {
        fail(error, @"A captured implementation, prepared interface, and callback owner are required.");
        return nullptr;
    }
    auto entry = std::make_unique<ABIObjCReplacement>(binding, interface, fallbackOwner);
    ABIResolutionFailure *failure = nullptr;
    entry->closure = ABICreateCallClosure(interface,
        [](void *context, void *output, void *const *arguments) {
            auto& entry = *static_cast<ABIObjCReplacement *>(context);
            std::shared_ptr<Callback> callback;
            { std::lock_guard lock(entry.mutex); callback = entry.callback; }
            ABIObjCReplacementCall call(entry, arguments);
            if (callback) callback->handler(callback->context, &call);
            // A callback failure before proceed bypasses it with native storage.
            // A failure after proceed preserves that result and never replays it.
            if (!call.completed) ABIObjCReplacementProceed(&call, nullptr, nullptr);
            if (entry.retainable) {
                CFTypeRef value = call.object();
                call.completed = false; // Transfer the frame's +1 exactly once.
                if (entry.retained) {
                    std::memcpy(output, &value, sizeof(value));
                } else {
                    id __autoreleasing autoreleased = CFBridgingRelease(value);
                    void *borrowed = (__bridge void *)autoreleased;
                    std::memcpy(output, &borrowed, sizeof(borrowed));
                }
            } else if (entry.resultSize) {
                std::memcpy(output, call.result.data(), entry.resultSize);
            }
        }, entry.get(), &failure);
    if (!entry->closure) {
        if (error) *error = [NSError errorWithDomain:ABIObjCInvocationErrorDomain
            code:failure ? ABIResolutionFailureCode(failure) : ABIFailureUnsupportedDeclaration
            userInfo:@{NSLocalizedDescriptionKey: failure ? @(ABIResolutionFailureMessage(failure)) : @"Callback preparation failed."}];
        if (failure) ABIReleaseResolutionFailure(failure);
        return nullptr;
    }
    entry->callback = std::make_shared<Callback>(handler, context, destroy);
    return entry.release();
}

IMP ABIPublishObjCReplacement(ABIObjCReplacement *replacement) {
    { std::lock_guard lock(replacement->mutex); replacement->published = true; }
    return reinterpret_cast<IMP>(ABICallClosureFunction(replacement->closure));
}

void ABIInvalidateObjCReplacement(ABIObjCReplacement *replacement) {
    std::shared_ptr<Callback> previous;
    { std::lock_guard lock(replacement->mutex); previous.swap(replacement->callback); }
    // Releasing Swift captures can reenter this API; do it outside the lock.
}

void ABIReleaseObjCReplacement(ABIObjCReplacement *replacement) {
    if (!replacement) return;
    ABIInvalidateObjCReplacement(replacement);
    if (!replacement->published) delete replacement;
}

void *ABIObjCReplacementReceiver(const ABIObjCReplacementCall *call) {
    if (call->entry.consumed) return nullptr;
    void *receiver = nullptr;
    std::memcpy(&receiver, call->arguments[0], sizeof(receiver));
    return receiver;
}
const void *ABIObjCReplacementArgument(const ABIObjCReplacementCall *call, size_t index) {
    return call->arguments[index + 2];
}

BOOL ABIObjCReplacementProceed(ABIObjCReplacementCall *call, const void *const *arguments, NSError **error) {
    if (error) *error = nil;
    if (call->entry.consumed && call->completed) {
        fail(error, @"A consumed initializer receiver cannot be initialized twice.");
        return NO;
    }
    const size_t count = ABIObjCInvocationParameterCount(call->entry.binding);
    std::vector<void *> values{call->arguments[0], call->arguments[1]};
    for (size_t index = 0; index < count; ++index)
        values.push_back(const_cast<void *>(arguments ? arguments[index] : call->arguments[index + 2]));
    std::vector<std::max_align_t> result(call->result.size());
    ABIResolutionFailure *failure = nullptr;
    const bool success = ABIUnsafeInvokeCCallInterface(call->entry.interface,
        reinterpret_cast<ABIUnmanagedFunction>(ABIObjCInvocationImplementation(call->entry.binding)),
        result.data(), values.data(), &failure);
    if (!success) {
        if (error) *error = [NSError errorWithDomain:ABIObjCInvocationErrorDomain
            code:failure ? ABIResolutionFailureCode(failure) : ABIFailureInvalidRequest
            userInfo:@{NSLocalizedDescriptionKey: failure ? @(ABIResolutionFailureMessage(failure)) : @"Invalid continuation storage."}];
        if (failure) ABIReleaseResolutionFailure(failure);
        return NO;
    }
    if (call->entry.retainable && !call->entry.retained) {
        CFTypeRef value = nullptr;
        std::memcpy(&value, result.data(), sizeof(value));
        if (value) CFRetain(value);
    }
    call->clear();
    call->result.swap(result);
    call->completed = true;
    return YES;
}

BOOL ABICopyObjCReplacementResult(ABIObjCReplacementCall *call, void *result, NSError **error) {
    if (error) *error = nil;
    if (!call->completed) { fail(error, @"No native result is available."); return NO; }
    if (call->entry.retainable && call->object()) CFRetain(call->object());
    std::memcpy(result, call->result.data(), call->entry.resultSize);
    return YES;
}
BOOL ABISetObjCReplacementResult(ABIObjCReplacementCall *call, const void *result, NSError **error) {
    if (error) *error = nil;
    if (call->entry.consumed) { fail(error, @"Initializer results are supplied by native initialization."); return NO; }
    CFTypeRef value = nullptr;
    if (call->entry.retainable) {
        std::memcpy(&value, result, sizeof(value));
        if (value) CFRetain(value);
    }
    call->clear();
    std::memcpy(call->result.data(), result, call->entry.resultSize);
    call->completed = true;
    return YES;
}
