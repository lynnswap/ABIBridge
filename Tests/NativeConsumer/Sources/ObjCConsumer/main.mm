#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <ABIBridge/ObjectiveCInvocation.hpp>
#include <cassert>
#include <iostream>
#include "../../ObjCInvocationFixture.hpp"

typedef NSInteger (^Transform)(NSInteger);
struct Pair { double x, y; };
struct Large { double values[6]; };
static int liveResults = 0;
static BOOL classInitialized = NO;

@interface ResultObject : NSObject
@end
@implementation ResultObject
- (instancetype)init { if ((self = [super init])) ++liveResults; return self; }
- (void)dealloc { --liveResults; }
@end

@interface FixtureObject : NSObject
@property(nonatomic) NSInteger value;
- (BOOL)refreshAnimated:(BOOL)animated;
- (NSInteger)add:(NSInteger)a scale:(double)scale label:(NSString*)label flag:(BOOL)flag
           value:(NSInteger)b extra:(NSInteger)c pair:(Pair)pair token:(NSObject*)token
           index:(NSInteger)d other:(NSInteger)e;
- (Pair)scaledPair:(Pair)pair;
- (Large)largeValue;
- (NSObject*)object;
- (NSObject*)copyObject;
- (NSObject*)retainedObject __attribute__((ns_returns_retained));
- (NSObject*)newBorrowedObject __attribute__((objc_method_family(none)));
- (NSObject*)newspaper;
- (BOOL)acceptsObject:(NSObject*)object;
- (void)applyBlock:(void (^)(NSInteger))block;
- (Transform)copyTransform;
- (Transform)retainedTransform __attribute__((ns_returns_retained));
+ (BOOL)initialized;
@end
@implementation FixtureObject
+ (void)initialize { if (self == [FixtureObject class]) classInitialized = YES; }
+ (BOOL)initialized { return classInitialized; }
- (BOOL)refreshAnimated:(BOOL)animated { self.value = animated ? 42 : 0; return animated; }
- (NSInteger)add:(NSInteger)a scale:(double)scale label:(NSString*)label flag:(BOOL)flag
           value:(NSInteger)b extra:(NSInteger)c pair:(Pair)pair token:(NSObject*)token
           index:(NSInteger)d other:(NSInteger)e {
    assert([label isEqualToString:@"native"] && token);
    return (a + b + c + d + e + pair.x + pair.y + flag) * scale;
}
- (Pair)scaledPair:(Pair)pair { return {pair.x * 2, pair.y * 2}; }
- (Large)largeValue { return {{1, 2, 3, 4, 5, 42}}; }
- (NSObject*)object { return [ResultObject new]; }
- (NSObject*)copyObject { return [ResultObject new]; }
- (NSObject*)retainedObject { return [ResultObject new]; }
- (NSObject*)newBorrowedObject { return [ResultObject new]; }
- (NSObject*)newspaper { return [ResultObject new]; }
- (BOOL)acceptsObject:(NSObject*)object { return object != nil; }
- (void)applyBlock:(void (^)(NSInteger))block { block(42); }
- (Transform)copyTransform {
    ResultObject* token = [ResultObject new];
    return ^NSInteger(NSInteger value) { return value + (token ? 1 : 0); };
}
- (Transform)retainedTransform {
    ResultObject* token = [ResultObject new];
    return ^NSInteger(NSInteger value) { return value + (token ? 1 : 0); };
}
@end

@interface Initializable : NSObject
- (instancetype)initWithReplacement;
- (instancetype)initReturningNil;
@end
@implementation Initializable
- (instancetype)initWithReplacement { return [[Initializable alloc] init]; }
- (instancetype)initReturningNil { return nil; }
@end

@interface DynamicObject : NSObject
@end
static NSInteger dynamicValue(id, SEL) { return 42; }
@implementation DynamicObject
+ (BOOL)resolveInstanceMethod:(SEL)selector {
    if (sel_isEqual(selector, sel_registerName("dynamicValue"))) {
        std::string types = std::string(@encode(NSInteger)) + "@:";
        return class_addMethod(self, selector, reinterpret_cast<IMP>(dynamicValue), types.c_str());
    }
    return [super resolveInstanceMethod:selector];
}
@end

int main() {
    checkPublicObjCInvocation();
    @autoreleasepool {
        Class cls = objc_getClass("FixtureObject");
        auto initialized = abi_bridge::objc_method<BOOL()>(cls, @selector(initialized));
        assert(initialized.unsafe_invoke());
        __weak FixtureObject* weakReceiver;
        {
            FixtureObject* object = [FixtureObject new];
            weakReceiver = object;
            auto refresh = abi_bridge::objc_method<BOOL(BOOL)>(object, "refreshAnimated:");
            object = nil;
            assert(weakReceiver);
            assert(refresh.unsafe_invoke(YES));
            assert(weakReceiver.value == 42);
            auto copy = refresh;
            assert(!copy.unsafe_invoke(NO));
        }
        assert(!weakReceiver);

        FixtureObject* object = [FixtureObject new];
        auto mixed = abi_bridge::objc_method<NSInteger(NSInteger, double, NSString*, BOOL, NSInteger, NSInteger, Pair, NSObject*, NSInteger, NSInteger)>(
            object, @selector(add:scale:label:flag:value:extra:pair:token:index:other:));
        assert(mixed.unsafe_invoke(1, 2.0, @"native", YES, 2, 3, Pair{4, 5}, object, 6, 7) == 58);
        auto pair = abi_bridge::objc_method<Pair(Pair)>(object, @selector(scaledPair:));
        assert(pair.unsafe_invoke(Pair{2, 3}).y == 6);
        auto large = abi_bridge::objc_method<Large()>(object, @selector(largeValue));
        assert(large.unsafe_invoke().values[5] == 42);

        for (SEL selector : {@selector(object), @selector(copyObject), @selector(newspaper)}) {
            @autoreleasepool {
                auto getter = abi_bridge::objc_method<NSObject*()>(object, selector);
                NSObject* value = getter.unsafe_invoke();
                assert(value && liveResults == 1);
            }
            assert(liveResults == 0);
        }
        @autoreleasepool {
            auto getter = abi_bridge::objc_method<NSObject*()>(
                object, @selector(retainedObject), {.returns_retained = true});
            NSObject* value = getter.unsafe_invoke();
            assert(value && liveResults == 1);
        }
        assert(liveResults == 0);
        @autoreleasepool {
            auto getter = abi_bridge::objc_method<NSObject*()>(
                object, @selector(newBorrowedObject), {.returns_retained = false});
            NSObject* value = getter.unsafe_invoke();
            assert(value && liveResults == 1);
        }
        assert(liveResults == 0);

        auto accepts = abi_bridge::objc_method<BOOL(NSObject*)>(object, @selector(acceptsObject:));
        assert(accepts.unsafe_invoke(object) && !accepts.unsafe_invoke(nil));
        __block NSInteger blockResult = 0;
        auto apply = abi_bridge::objc_method<void(void (^)(NSInteger))>(object, @selector(applyBlock:));
        apply.unsafe_invoke(^(NSInteger value) { blockResult = value; });
        assert(blockResult == 42);
        @autoreleasepool {
            auto factory = abi_bridge::objc_method<Transform()>(object, @selector(copyTransform));
            Transform transform = factory.unsafe_invoke();
            assert(transform(41) == 42 && liveResults == 1);
        }
        assert(liveResults == 0);

        @autoreleasepool {
            auto factory = abi_bridge::objc_method<Transform()>(
                object, @selector(retainedTransform), {.returns_retained = true});
            Transform transform = factory.unsafe_invoke();
            assert(transform(41) == 42 && liveResults == 1);
        }
        assert(liveResults == 0);

        __weak Initializable* original;
        __weak Initializable* replacement;
        @autoreleasepool {
            Initializable* allocated = [Initializable alloc];
            original = allocated;
            auto initialize = abi_bridge::objc_method<Initializable*()>(allocated, @selector(initWithReplacement));
            allocated = nil;
            Initializable* result = initialize.unsafe_invoke();
            replacement = result;
            assert(result && result != original);
        }
        assert(!original && !replacement);
        @autoreleasepool {
            Initializable* allocated = [Initializable alloc];
            original = allocated;
            auto initialize = abi_bridge::objc_method<Initializable*()>(allocated, @selector(initReturningNil));
            allocated = nil;
            assert(initialize.unsafe_invoke() == nil);
        }
        assert(!original);

        auto dynamic = abi_bridge::objc_method<NSInteger()>([DynamicObject new], sel_registerName("dynamicValue"));
        assert(dynamic.unsafe_invoke() == 42);
        try {
            abi_bridge::objc_method<void(double)>(object, @selector(refreshAnimated:));
            assert(false && "Mismatched encodings must be rejected");
        } catch (const abi_bridge::resolution_error& error) {
            assert(error.code() == ABIFailureSignatureMismatch);
        }
        try {
            abi_bridge::objc_method<BOOL()>(object, @selector(refreshAnimated:));
            assert(false && "Mismatched parameter counts must be rejected");
        } catch (const abi_bridge::resolution_error& error) {
            assert(error.code() == ABIFailureSignatureMismatch);
        }
        try {
            abi_bridge::objc_method<BOOL(double)>(object, @selector(refreshAnimated:));
            assert(false && "Mismatched parameter encodings must be rejected");
        } catch (const abi_bridge::resolution_error& error) {
            assert(error.code() == ABIFailureSignatureMismatch);
        }
        try {
            abi_bridge::objc_method<BOOL(BOOL)>(
                object, @selector(refreshAnimated:), {.returns_retained = true});
            assert(false && "A scalar result cannot transfer object ownership");
        } catch (const abi_bridge::resolution_error& error) {
            assert(error.code() == ABIFailureInvalidRequest);
        }
        try {
            abi_bridge::objc_method<void()>(object, sel_registerName("missingMethod"));
            assert(false && "Missing methods must be rejected");
        } catch (const abi_bridge::resolution_error& error) {
            assert(error.code() == ABIFailureDeclarationNotFound);
        }
        try {
            abi_bridge::objc_method<void()>(nil, @selector(description));
            assert(false && "A bound method requires a receiver");
        } catch (const abi_bridge::resolution_error& error) {
            assert(error.code() == ABIFailureInvalidRequest);
        }

    }
    assert(liveResults == 0);
    std::cout << "Objective-C++ consumer passed: selectors, encodings, receiver and result ownership.\n";
}
