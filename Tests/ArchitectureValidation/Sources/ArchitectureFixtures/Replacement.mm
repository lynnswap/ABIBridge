#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <ABIBridgeObjCXX/Replacement.h>
#include "ArchitectureFixtures.h"
#include <memory>

@interface ABIReplacementArchitectureReceiver : NSObject
@property(nonatomic) int32_t calls;
- (int32_t)add:(int32_t)a to:(int32_t)b;
- (nullable instancetype)initWithSeed:(int32_t)seed;
@end
@implementation ABIReplacementArchitectureReceiver
- (int32_t)add:(int32_t)a to:(int32_t)b { self.calls++; return a + b; }
- (instancetype)initWithSeed:(int32_t)seed {
    if (seed < 0) return nil;
    if ((self = [super init])) _calls = seed;
    return self;
}
@end

namespace {
struct State { int callbacks = 0; int destroyed = 0; bool valid = true; bool initializer = false; };
using Entry = std::unique_ptr<ABIObjCReplacement, decltype(&ABIReleaseObjCReplacement)>;

Entry prepare(SEL selector, State& state) {
    NSError *error = nil;
    auto *binding = ABICopyObjCImplementation(ABIReplacementArchitectureReceiver.class, selector, NO, -1, -1, &error);
    if (!binding) return {nullptr, ABIReleaseObjCReplacement};
    auto *pointer = ABICreateScalarType(ABIValuePointer, nullptr);
    auto *integer = ABICreateScalarType(ABIValueInt32, nullptr);
    const ABIValueType *parameters[] = {pointer, pointer, integer, integer};
    auto *interface = ABICreateCCallInterface(state.initializer ? pointer : integer,
        parameters, state.initializer ? 3 : 4, nullptr);
    auto *entry = ABICreateObjCReplacement(binding, interface,
        [](void *context, ABIObjCReplacementCall *call) {
            auto& state = *static_cast<State *>(context);
            ++state.callbacks;
            if (state.initializer) {
                state.valid &= ABIObjCReplacementReceiver(call) == nullptr;
                state.valid &= ABIObjCReplacementProceed(call, nullptr, nullptr);
                void *result = nullptr;
                state.valid &= ABICopyObjCReplacementResult(call, &result, nullptr);
                id value = CFBridgingRelease(result);
                state.valid &= !value || [value isKindOfClass:ABIReplacementArchitectureReceiver.class];
                // A second proceed must be rejected before touching consumed self.
                NSError *error = nil;
                state.valid &= !ABIObjCReplacementProceed(call, nullptr, &error) && error != nil;
            } else {
                state.valid &= ABIObjCReplacementProceed(call, nullptr, nullptr);
                int32_t result = 0;
                state.valid &= ABICopyObjCReplacementResult(call, &result, nullptr);
                result += 1;
                state.valid &= ABISetObjCReplacementResult(call, &result, nullptr);
            }
        }, &state, [](void *context) { ++static_cast<State *>(context)->destroyed; }, nil, &error);
    ABIReleaseCallInterface(interface);
    ABIReleaseValueType(pointer);
    ABIReleaseValueType(integer);
    ABIReleaseObjCInvocation(binding);
    return {entry, ABIReleaseObjCReplacement};
}
struct MethodRestore {
    Method method;
    IMP previous;
    ~MethodRestore() { method_setImplementation(method, previous); }
};
}

const char *ABIValidateObjCReplacement(void) {
    @autoreleasepool {
        State state;
        auto entry = prepare(@selector(add:to:), state);
        if (!entry) return "Replacement preparation failed";
        IMP cached = ABIPublishObjCReplacement(entry.get());
        Method method = class_getInstanceMethod(ABIReplacementArchitectureReceiver.class, @selector(add:to:));
        MethodRestore restore{method, method_setImplementation(method, cached)};
        ABIReplacementArchitectureReceiver *receiver = [ABIReplacementArchitectureReceiver new];
        if ([receiver add:20 to:21] != 42 || receiver.calls != 1) return "Replacement method call failed";
        entry.reset();
        if (!state.valid || state.callbacks != 1 || state.destroyed != 1) return "Callback ownership failed";
        if (((int32_t (*)(id, SEL, int32_t, int32_t))cached)(receiver, @selector(add:to:), 20, 22) != 42)
            return "Cached IMP failed after callback owner release";
        if (state.callbacks != 1 || receiver.calls != 2) return "Inactive callback was invoked";

        State initializerState;
        initializerState.initializer = true;
        auto initializer = prepare(@selector(initWithSeed:), initializerState);
        if (!initializer) return "Initializer replacement preparation failed";
        Method initMethod = class_getInstanceMethod(ABIReplacementArchitectureReceiver.class, @selector(initWithSeed:));
        MethodRestore initRestore{initMethod, method_setImplementation(initMethod, ABIPublishObjCReplacement(initializer.get()))};
        ABIReplacementArchitectureReceiver *value = [[ABIReplacementArchitectureReceiver alloc] initWithSeed:7];
        if (value.calls != 7) return "Initializer result failed";
        if ([[ABIReplacementArchitectureReceiver alloc] initWithSeed:-1] != nil) return "Nil initializer failed";
        initializer.reset();
        if (!initializerState.valid || initializerState.callbacks != 2 || initializerState.destroyed != 1)
            return "Initializer callback ownership failed";
    }
    return nullptr;
}

Class ABIValidationInitializerClass(void) { return ABIReplacementArchitectureReceiver.class; }
NSObject *ABIValidationCreateInitialized(int32_t seed) {
    return [[ABIReplacementArchitectureReceiver alloc] initWithSeed:seed];
}

#include <ABIBridge/ObjectiveCHooks.hpp>
const char *ABIValidateNativeObjCHooks(void) {
    @autoreleasepool {
        int failures = 0;
        auto failed = [&](const abi_bridge::resolution_error&) noexcept { ++failures; };
        auto first = abi_bridge::objc_method_hook<int32_t(int32_t, int32_t)>(ABIReplacementArchitectureReceiver.class, "add:to:",
            [](auto& call, int32_t a, int32_t b) { return call.proceed(a,b) + 1; }, failed);
        auto second = abi_bridge::objc_method_hook<int32_t(int32_t, int32_t)>(ABIReplacementArchitectureReceiver.class, "add:to:",
            [](auto& call, int32_t a, int32_t b) { return call.proceed(a,b) * 2; }, failed);
        ABIReplacementArchitectureReceiver *receiver = [ABIReplacementArchitectureReceiver new];
        if ([receiver add:20 to:21] != 84) return "Native typed hook ordering failed";
        IMP saved = class_getMethodImplementation(ABIReplacementArchitectureReceiver.class, @selector(add:to:));
        first.invalidate(); second.invalidate();
        if (((int32_t (*)(id, SEL, int32_t, int32_t))saved)(receiver, @selector(add:to:), 20, 22) != 42)
            return "Saved native hook entry failed after invalidation";
        auto initializer = abi_bridge::objc_initializer_hook<ABIReplacementArchitectureReceiver *(int32_t)>(
            ABIReplacementArchitectureReceiver.class, "initWithSeed:", [](int32_t seed) { return seed < 0 ? seed : seed + 1; },
            [](ABIReplacementArchitectureReceiver *result) { if (result) result.calls += 40; }, failed);
        if ([[ABIReplacementArchitectureReceiver alloc] initWithSeed:1].calls != 42)
            return "Native typed initializer transformation failed";
        if ([[ABIReplacementArchitectureReceiver alloc] initWithSeed:-1] != nil)
            return "Native typed initializer nil result failed";
        if (failures) return "Native hook callback reported a failure";
    }
    return nullptr;
}
