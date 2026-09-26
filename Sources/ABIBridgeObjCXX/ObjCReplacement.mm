#import <ABIBridgeObjCXX/Replacement.h>
#include <algorithm>
#include <atomic>
#include <map>
#include <string>
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
    Class inheritedFrom = Nil;
    SEL selector = nullptr;
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
    void (*next)(void *, ABIObjCReplacementCall *) = nullptr;
    void *nextContext = nullptr;

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
    if (call->next) {
        ABIObjCReplacementCall child(call->entry, values.data());
        call->next(call->nextContext, &child);
        call->clear();
        call->result.swap(child.result);
        call->completed = child.completed;
        child.completed = false;
        return YES;
    }
    std::vector<std::max_align_t> result(call->result.size());
    ABIResolutionFailure *failure = nullptr;
    // A subclass-local inherited entry follows later superclass replacements.
    const IMP implementation = call->entry.inheritedFrom
        ? class_getMethodImplementation(call->entry.inheritedFrom, call->entry.selector)
        : ABIObjCInvocationImplementation(call->entry.binding);
    const bool success = ABIUnsafeInvokeCCallInterface(call->entry.interface,
        reinterpret_cast<ABIUnmanagedFunction>(implementation),
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

NSString * const ABIObjCMethodHookErrorDomain = @"ABIBridge.ObjCMethodHook";

namespace {
struct HookCallback {
    ABIObjCReplacementHandler handler;
    void *context;
    ABIObjCReplacementDestroy destroy;
    __weak id object;
    bool filtered;

    HookCallback(ABIObjCReplacementHandler handler, void *context,
                 ABIObjCReplacementDestroy destroy, id object)
        : handler(handler), context(context), destroy(destroy), object(object), filtered(object != nil) {}
    ~HookCallback() { destroy(context); }
};
using HookChain = std::vector<std::shared_ptr<HookCallback>>;
struct HookEntry {
    Class target;
    SEL selector;
    std::vector<std::string> contract;
    ABIObjCReplacement *replacement = nullptr;
    IMP implementation = nullptr;
    std::mutex mutex;
    std::shared_ptr<const HookChain> chain = std::make_shared<HookChain>();

    HookEntry(Class target, SEL selector, std::vector<std::string> contract)
        : target(target), selector(selector), contract(std::move(contract)) {}
    ~HookEntry() { ABIReleaseObjCReplacement(replacement); }
};
using HookKey = std::pair<uintptr_t, uintptr_t>;
struct HookRegistry {
    std::mutex mutex;
    std::map<HookKey, std::unique_ptr<HookEntry>> entries;
};
HookRegistry& hookRegistry() {
    // Saved IMPs can still be called during static destruction.
    static auto *registry = new HookRegistry;
    return *registry;
}
Method ownMethod(Class type, SEL selector) {
    unsigned count = 0;
    Method *methods = class_copyMethodList(type, &count);
    Method result = nullptr;
    for (unsigned index = 0; index < count; ++index) {
        if (method_getName(methods[index]) == selector) { result = methods[index]; break; }
    }
    free(methods);
    return result;
}
bool ownsMethod(const HookEntry& entry) {
    Method method = ownMethod(entry.target, entry.selector);
    return method && method_getImplementation(method) == entry.implementation;
}
void hookFail(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:ABIObjCMethodHookErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}
bool methodFamily(const char *name, const char *family) {
    while (*name == '_') ++name;
    const size_t size = std::strlen(family);
    return std::strncmp(name, family, size) == 0 && !(name[size] >= 'a' && name[size] <= 'z');
}
bool ordinaryMethod(SEL selector, bool classMethod) {
    const char *name = sel_getName(selector);
    if (methodFamily(name, "init") || methodFamily(name, "alloc")) return false;
    for (const char *lifetime : {"dealloc", "retain", "release", "autorelease", "retainCount", "_tryRetain", "_isDeallocating"})
        if (std::strcmp(name, lifetime) == 0) return false;
    return !classMethod || (std::strcmp(name, "load") != 0 && std::strcmp(name, "initialize") != 0);
}
std::vector<std::string> hookContract(const ABIObjCInvocation *binding) {
    std::vector<std::string> contract{ABIObjCInvocationReturnsRetained(binding) ? "retained" : "borrowed",
        ABIObjCInvocationResultType(binding)};
    for (size_t index = 0; index < ABIObjCInvocationParameterCount(binding); ++index)
        contract.emplace_back(ABIObjCInvocationParameterType(binding, index));
    return contract;
}
Method concreteMethod(Class type, SEL selector) {
    for (Class current = type; current; current = class_getSuperclass(current))
        if (Method method = ownMethod(current, selector)) return method;
    return nullptr;
}

struct HookCursor {
    const HookChain& chain;
    size_t count;
};
void dispatchHook(void *context, ABIObjCReplacementCall *call) {
    auto cursor = *static_cast<HookCursor *>(context);
    while (cursor.count) {
        const auto& callback = cursor.chain[--cursor.count];
        // Weak loading and callback execution can run Objective-C code. Neither
        // happens under registry/entry locks. Keep a matching receiver alive for
        // this callback only; a registration never owns its object filter.
        __attribute__((objc_precise_lifetime)) id object = callback->object;
        if (callback->filtered && (!object || (__bridge void *)object != ABIObjCReplacementReceiver(call))) continue;
        call->next = dispatchHook;
        call->nextContext = &cursor;
        callback->handler(callback->context, call);
        if (!call->completed) ABIObjCReplacementProceed(call, nullptr, nullptr);
        call->next = nullptr;
        call->nextContext = nullptr;
        return;
    }
    ABIObjCReplacementProceed(call, nullptr, nullptr);
}
void dispatchEntry(void *context, ABIObjCReplacementCall *call) {
    auto& entry = *static_cast<HookEntry *>(context);
    std::shared_ptr<const HookChain> chain;
    { std::lock_guard lock(entry.mutex); chain = entry.chain; }
    HookCursor cursor{*chain, chain->size()};
    dispatchHook(&cursor, call);
}
}

struct ABIObjCMethodHook {
    HookEntry *entry = nullptr;
    // Only identity is retained here. Removing a registration drops its
    // captures even while the invalidated token remains alive.
    HookCallback *identity;
    std::atomic<bool> active{true};
    explicit ABIObjCMethodHook(HookCallback *identity) : identity(identity) {}
};

ABIObjCMethodHook *ABICreateObjCMethodHook(Class type, SEL selector, BOOL classMethod,
    ABIObjCInvocation *binding, ABICallInterface *interface,
    ABIObjCReplacementHandler handler, void *context, ABIObjCReplacementDestroy destroy,
    id object, id fallbackOwner, NSError **error) {
    if (error) *error = nil;
    auto callback = std::make_shared<HookCallback>(handler, context, destroy, object);
    if (!ordinaryMethod(selector, classMethod) || ABIObjCInvocationConsumesReceiver(binding)) {
        hookFail(error, 2, @"Initializers, consuming receivers, allocation, and lifecycle methods require dedicated hook contracts.");
        return nullptr;
    }
    const auto contract = hookContract(binding);
    Class target = classMethod ? object_getClass(type) : type;
    HookKey key{reinterpret_cast<uintptr_t>((__bridge void *)target), reinterpret_cast<uintptr_t>(selector)};
    auto& registry = hookRegistry();
    HookEntry *existing = nullptr;
    { std::lock_guard lock(registry.mutex);
      auto found = registry.entries.find(key);
      if (found != registry.entries.end()) existing = found->second.get(); }

    // Preparation may retain user objects and images. Do it outside writer
    // locks; if another managed writer wins, discard the unpublished candidate.
    std::unique_ptr<HookEntry> candidate;
    std::string encoding;
    if (!existing) {
        Method method = class_getInstanceMethod(target, selector);
        if (!method || method_getImplementation(method) != ABIObjCInvocationImplementation(binding)) {
            hookFail(error, 1, @"The method changed during hook preparation.");
            return nullptr;
        }
        encoding = method_getTypeEncoding(method);
        candidate = std::make_unique<HookEntry>(target, selector, contract);
        candidate->replacement = ABICreateObjCReplacement(binding, interface, dispatchEntry, candidate.get(),
            [](void *) {}, fallbackOwner, error);
        if (!candidate->replacement) return nullptr;
        candidate->replacement->selector = selector;
        candidate->implementation = reinterpret_cast<IMP>(ABICallClosureFunction(candidate->replacement->closure));
    }
    auto token = std::make_unique<ABIObjCMethodHook>(callback.get());
    std::shared_ptr<const HookChain> previous;
    NSInteger failureCode = 0;
    NSString *failureMessage = nil;
    const bool installed = [&] {
        std::lock_guard writer(registry.mutex);
        auto found = registry.entries.find(key);
        HookEntry *entry = found == registry.entries.end() ? candidate.get() : found->second.get();
        if (found != registry.entries.end()) {
            if (!ownsMethod(*entry)) {
                failureCode = 1; failureMessage = @"Another writer displaced the managed method implementation.";
                return false;
            }
            if (entry->contract != contract) {
                failureCode = 3; failureMessage = @"The hook's ownership or native signature differs from the installed entry.";
                return false;
            }
        } else {
            Method method = concreteMethod(target, selector);
            if (!method || method_getImplementation(method) != ABIObjCInvocationImplementation(binding)) {
                failureCode = 1; failureMessage = @"The method changed during hook preparation.";
                return false;
            }
            Method own = ownMethod(target, selector);
            if (!own) candidate->replacement->inheritedFrom = class_getSuperclass(target);
            // Publish a complete initial chain before exposing the entry to
            // callers. External method-table writers must coordinate with this
            // operation: Objective-C has no compare-and-set IMP primitive.
            entry->chain = std::make_shared<HookChain>(HookChain{callback});
            if (own) method_setImplementation(own, entry->implementation);
            else if (!class_addMethod(target, selector, entry->implementation, encoding.c_str())) {
                failureCode = 1; failureMessage = @"Another writer added the method during hook installation.";
                return false;
            }
            ABIPublishObjCReplacement(entry->replacement);
            registry.entries.emplace(key, std::move(candidate));
            token->entry = entry;
            return true;
        }
        {
            std::lock_guard lock(entry->mutex);
            auto chain = std::make_shared<HookChain>(*entry->chain);
            chain->push_back(callback);
            previous = std::move(entry->chain);
            entry->chain = std::move(chain);
        }
        token->entry = entry;
        return true;
    }();
    if (!installed) {
        hookFail(error, failureCode, failureMessage);
        return nullptr;
    }
    return token.release();
}

void ABIInvalidateObjCMethodHook(ABIObjCMethodHook *hook) {
    if (!hook->active.exchange(false)) return;
    std::shared_ptr<const HookChain> previous;
    {
        auto& entry = *hook->entry;
        std::lock_guard lock(entry.mutex);
        auto chain = std::make_shared<HookChain>();
        for (const auto& callback : *entry.chain)
            if (callback.get() != hook->identity) chain->push_back(callback);
        previous = std::move(entry.chain);
        entry.chain = std::move(chain);
    }
    // Release captures outside locks; a destructor may register/invalidate hooks.
}
void ABIReleaseObjCMethodHook(ABIObjCMethodHook *hook) {
    if (!hook) return;
    ABIInvalidateObjCMethodHook(hook);
    delete hook;
}
int32_t ABIObjCMethodHookStatus(const ABIObjCMethodHook *hook) {
    if (!hook->active.load()) return 0;
    return ownsMethod(*hook->entry) ? 1 : 2;
}
