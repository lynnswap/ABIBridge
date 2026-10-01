#pragma once
#include <ABIBridge/ObjectiveCInvocation.hpp>
#include <cassert>
#include <cstdlib>
#include <objc/message.h>
#include <functional>
#include <utility>

static int liveProxyReceivers = 0;
static int liveProxyResults = 0;
static int nativeStorage = 42;
static std::function<void()> assignmentReentry;

@interface AssignmentFirst : NSObject
- (NSInteger)value;
@end
@implementation AssignmentFirst
- (NSInteger)value { return 11; }
- (void)dealloc {
    if (assignmentReentry) assignmentReentry();
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}
@end
@interface AssignmentSecond : NSObject
- (NSInteger)value;
@end
@implementation AssignmentSecond
- (NSInteger)value { return 22; }
@end

inline void checkAssignmentReentry(bool moving) {
    using Handle = abi_bridge::bound_objc_implementation<NSInteger()>;
    std::optional<Handle> current;
    AssignmentFirst *first = [[AssignmentFirst alloc] init];
    AssignmentSecond *second = [[AssignmentSecond alloc] init];
    current.emplace(first, @selector(value));
    Handle next(second, @selector(value));
#if __has_feature(objc_arc)
    first = nil; second = nil;
#else
    [first release]; [second release];
#endif
    NSInteger during = 0;
    assignmentReentry = [&] { during = current->unsafe_invoke(); };
    if (moving) *current = std::move(next);
    else *current = next;
    assignmentReentry = nullptr;
    assert(during == 22 && current->unsafe_invoke() == 22);
}

#if !__has_feature(objc_arc)
static std::function<void()> receiverRetainReentry;
@interface RetainReentrantReceiver : NSObject
- (NSInteger)value;
@end
@implementation RetainReentrantReceiver
- (NSInteger)value { return 42; }
- (id)retain {
    auto callback = std::exchange(receiverRetainReentry, {});
    if (callback) callback();
    return [super retain];
}
@end

inline void checkReceiverRetainReentry() {
    using namespace abi_bridge;
    RetainReentrantReceiver *prototype = [[RetainReentrantReceiver alloc] init];
    RetainReentrantReceiver *receiver = [[RetainReentrantReceiver alloc] init];
    {
        std::optional<objc_implementation<NSInteger()>> source;
        source.emplace(prototype, "value");
        receiverRetainReentry = [&] { source.reset(); };
        auto rebound = source->bind(receiver);
        assert(!source && rebound.unsafe_invoke() == 42);
    }
    {
        NSError *error = nil;
        auto *binding = ABICopyObjCMethod(prototype, @selector(value), @encode(NSInteger), nullptr, 0, -1, -1, &error);
        assert(binding && !error);
        auto *source = ABICopyObjCMethodImplementation(binding);
        ABIReleaseObjCMethod(binding);
        receiverRetainReentry = [&] { ABIReleaseObjCImplementation(source); source = nullptr; };
        auto *rebound = ABICopyBoundObjCMethod(source, receiver, &error);
        assert(!source && rebound && !error);
        using Getter = NSInteger (*)(id, SEL);
        assert(reinterpret_cast<Getter>(ABIObjCMethodImplementation(rebound))(
            (__bridge id)ABIObjCMethodReceiverAddress(rebound), ABIObjCMethodSelector(rebound)) == 42);
        ABIReleaseObjCMethod(rebound);
    }
    [prototype release];
    [receiver release];
}
#endif

@interface ProxyResult : NSObject
@end
@implementation ProxyResult
- (instancetype)init { if ((self = [super init])) ++liveProxyResults; return self; }
- (void)dealloc {
    --liveProxyResults;
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}
@end

@interface ConcreteProxy : NSProxy {
    NSInteger _value;
}
- (instancetype)init;
- (void *)nativeAddress;
- (void)setValue:(NSInteger)value;
- (NSInteger)value;
- (id)copyToken;
+ (NSInteger)classValue;
@end
@implementation ConcreteProxy
- (instancetype)init { ++liveProxyReceivers; return self; }
- (void *)nativeAddress { return &nativeStorage; }
- (void)setValue:(NSInteger)value { _value = value; }
- (NSInteger)value { return _value; }
- (id)copyToken { return [[ProxyResult alloc] init]; }
+ (NSInteger)classValue { return 17; }
- (BOOL)respondsToSelector:(SEL)selector { std::abort(); }
- (void)dealloc {
    --liveProxyReceivers;
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}
@end

@interface ForwardedReceiver : NSObject
@end
@implementation ForwardedReceiver
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (sel_isEqual(selector, sel_registerName("forwardedValue")))
        return [NSMethodSignature signatureWithObjCTypes:"q@:"];
    return [super methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    long long value = 99;
    [invocation setReturnValue:&value];
}
@end

struct ForwardedAggregate { long long fields[4]; };

inline void checkForwardingImplementation(id receiver, IMP implementation, SEL selector, const char *encoding) {
    assert(class_addMethod(object_getClass(receiver), selector, implementation, encoding));
    assert(class_getInstanceMethod(object_getClass(receiver), selector));
    try {
        abi_bridge::bound_objc_implementation<ForwardedAggregate()>(receiver, selector);
        assert(false && "Forwarding trampolines must not become captured calls");
    } catch (const abi_bridge::resolution_error& error) {
        assert(error.code() == ABIFailureUnsupportedDeclaration);
    }
}

inline void checkReusableCapturedImplementation() {
    using namespace abi_bridge;
    std::optional<objc_implementation<NSInteger()>> captured;
    std::unique_ptr<ABIObjCImplementation, decltype(&ABIReleaseObjCImplementation)> native(nullptr, ABIReleaseObjCImplementation);
    {
        ConcreteProxy *prototype = [[ConcreteProxy alloc] init];
        [prototype setValue:1];
        auto bound = bound_objc_implementation<NSInteger()>(prototype, "value");
        captured = bound.implementation();
        NSError *error = nil;
        auto *binding = ABICopyObjCMethod(prototype, @selector(value), @encode(NSInteger), nullptr, 0, -1, -1, &error);
        assert(binding && !error);
        native.reset(ABICopyObjCMethodImplementation(binding));
        ABIRetainObjCImplementation(native.get());
        ABIReleaseObjCImplementation(native.get());
        ABIReleaseObjCMethod(binding);
#if __has_feature(objc_arc)
        prototype = nil;
#else
        [prototype release];
#endif
        assert(liveProxyReceivers == 1);
    }
    assert(liveProxyReceivers == 0);
    @autoreleasepool {
        ConcreteProxy *second = [[ConcreteProxy alloc] init];
        [second setValue:42];
        assert(captured->unsafe_invoke(second) == 42);
        NSError *error = nil;
        assert(ABIValidateObjCImplementationReceiver(native.get(), second, &error));
        auto *nativeBound = ABICopyBoundObjCMethod(native.get(), second, &error);
        assert(nativeBound && !error);
        native.reset();
        using Getter = NSInteger (*)(id, SEL);
        assert(reinterpret_cast<Getter>(ABIObjCMethodImplementation(nativeBound))(
            (__bridge id)ABIObjCMethodReceiverAddress(nativeBound), ABIObjCMethodSelector(nativeBound)) == 42);
        ABIReleaseObjCMethod(nativeBound);
        auto rebound = captured->bind(second);
        Method method = class_getInstanceMethod([ConcreteProxy class], @selector(value));
        IMP replacement = imp_implementationWithBlock(^NSInteger(id) { return 99; });
        IMP previous = method_setImplementation(method, replacement);
        assert([second value] == 99);
        assert(captured->unsafe_invoke(second) == 42 && rebound.unsafe_invoke() == 42);
        method_setImplementation(method, previous);
        imp_removeBlock(replacement);
        objc_implementation<NSInteger()> classValue([ConcreteProxy class], "classValue");
        assert(classValue.unsafe_invoke([ConcreteProxy class]) == 17);
        try { classValue.unsafe_invoke(second); assert(false); }
        catch (const resolution_error& error) { assert(error.code() == ABIFailureSignatureMismatch); }
        NSObject *incompatible = [[NSObject alloc] init];
        try { captured->unsafe_invoke(incompatible); assert(false); }
        catch (const resolution_error& error) { assert(error.code() == ABIFailureSignatureMismatch); }
        try { captured->bind(incompatible); assert(false); }
        catch (const resolution_error& error) { assert(error.code() == ABIFailureSignatureMismatch); }
#if !__has_feature(objc_arc)
        [incompatible release];
#endif
#if __has_feature(objc_arc)
        second = nil;
#else
        [second release];
#endif
        assert(liveProxyReceivers == 1 && rebound.unsafe_invoke() == 42);
    }
    assert(liveProxyReceivers == 0);
}

inline void checkPublicObjCInvocation() {
    checkAssignmentReentry(false);
    checkAssignmentReentry(true);
#if !__has_feature(objc_arc)
    checkReceiverRetainReentry();
#endif
    checkReusableCapturedImplementation();
    using namespace abi_bridge;
    @autoreleasepool {
        ConcreteProxy *proxy = [[ConcreteProxy alloc] init];
        {
            auto pointer = abi_bridge::bound_objc_implementation<void *()>(proxy, "nativeAddress");
            auto setter = abi_bridge::bound_objc_implementation<void(NSInteger)>(proxy, @selector(setValue:));
            auto getter = abi_bridge::bound_objc_implementation<NSInteger()>(proxy, "value");
            auto result = abi_bridge::bound_objc_implementation<id()>(proxy, "copyToken");
            assert(abi_bridge::bound_objc_implementation<NSInteger()>([ConcreteProxy class], "classValue").unsafe_invoke() == 17);
            try {
                abi_bridge::bound_objc_implementation<void()>(proxy, "missing");
                assert(false);
            } catch (const resolution_error& error) { assert(error.code() == ABIFailureDeclarationNotFound); }
            try {
                abi_bridge::bound_objc_implementation<void()>(proxy, std::string_view("value\0ignored", 13));
                assert(false);
            } catch (const resolution_error& error) { assert(error.code() == ABIFailureInvalidRequest); }
            try {
                abi_bridge::bound_objc_implementation<double()>(proxy, "value");
                assert(false);
            } catch (const resolution_error& error) { assert(error.code() == ABIFailureSignatureMismatch); }
#if __has_feature(objc_arc)
            proxy = nil;
#else
            [proxy release];
#endif
            assert(liveProxyReceivers == 1);
            auto copy = getter;
            @autoreleasepool {
                setter.unsafe_invoke(42);
                assert(copy.unsafe_invoke() == 42);
                assert(pointer.unsafe_invoke() == &nativeStorage);
                id token = result.unsafe_invoke();
                assert(token && liveProxyResults == 1);
            }
            assert(liveProxyResults == 0);
        }
        assert(liveProxyReceivers == 0);
        ForwardedReceiver *forwarded = [[ForwardedReceiver alloc] init];
        try {
            abi_bridge::bound_objc_implementation<long long()>(forwarded, "forwardedValue");
            assert(false);
        } catch (const resolution_error& error) { assert(error.code() == ABIFailureUnsupportedDeclaration); }
        const std::string aggregateEncoding = std::string(@encode(ForwardedAggregate)) + "@:";
        checkForwardingImplementation(forwarded, reinterpret_cast<IMP>(_objc_msgForward),
                                      sel_registerName("ordinaryForwardingIMP"), aggregateEncoding.c_str());
#if defined(__x86_64__)
        checkForwardingImplementation(forwarded, reinterpret_cast<IMP>(_objc_msgForward_stret),
                                      sel_registerName("aggregateForwardingIMP"), aggregateEncoding.c_str());
#endif
#if !__has_feature(objc_arc)
        [forwarded release];
#endif
    }
}
