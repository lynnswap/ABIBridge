#pragma once
#include <ABIBridge/ObjectiveCInvocation.hpp>
#include <cassert>
#include <cstdlib>
#include <objc/message.h>

static int liveProxyReceivers = 0;
static int liveProxyResults = 0;
static int nativeStorage = 42;

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
        abi_bridge::objc_method<ForwardedAggregate()>(receiver, selector);
        assert(false && "Forwarding trampolines must not become captured calls");
    } catch (const abi_bridge::resolution_error& error) {
        assert(error.code() == ABIFailureUnsupportedDeclaration);
    }
}

inline void checkPublicObjCInvocation() {
    using namespace abi_bridge;
    @autoreleasepool {
        ConcreteProxy *proxy = [[ConcreteProxy alloc] init];
        {
            auto pointer = abi_bridge::objc_method<void *()>(proxy, "nativeAddress");
            auto setter = abi_bridge::objc_method<void(NSInteger)>(proxy, @selector(setValue:));
            auto getter = abi_bridge::objc_method<NSInteger()>(proxy, "value");
            auto result = abi_bridge::objc_method<id()>(proxy, "copyToken");
            assert(abi_bridge::objc_method<NSInteger()>([ConcreteProxy class], "classValue").unsafe_invoke() == 17);
            try {
                abi_bridge::objc_method<void()>(proxy, "missing");
                assert(false);
            } catch (const resolution_error& error) { assert(error.code() == ABIFailureDeclarationNotFound); }
            try {
                abi_bridge::objc_method<void()>(proxy, std::string_view("value\0ignored", 13));
                assert(false);
            } catch (const resolution_error& error) { assert(error.code() == ABIFailureInvalidRequest); }
            try {
                abi_bridge::objc_method<double()>(proxy, "value");
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
            abi_bridge::objc_method<long long()>(forwarded, "forwardedValue");
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
