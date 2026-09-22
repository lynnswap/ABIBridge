#import <Foundation/Foundation.h>
#include <Block.h>
#include <ABIBridge/ABIBridgeObjCXX.hpp>
#include <cassert>
#include <iostream>

typedef NSInteger (^Transform)(NSInteger);
static int liveReceivers = 0;
static int liveResults = 0;

@interface ResultObject : NSObject
@end
@implementation ResultObject
- (instancetype)init { if ((self = [super init])) ++liveResults; return self; }
- (void)dealloc { --liveResults; [super dealloc]; }
@end

@interface FixtureObject : NSObject {
    BOOL initialized;
}
- (NSObject*)copyObject;
- (Transform)ownedTransform __attribute__((ns_returns_retained));
@end
@implementation FixtureObject
- (instancetype)init {
    if ((self = [super init])) { initialized = YES; ++liveReceivers; }
    return self;
}
- (NSObject*)copyObject { return [[ResultObject alloc] init]; }
- (Transform)ownedTransform {
    ResultObject* token = [[ResultObject alloc] init];
    Transform block = Block_copy(^NSInteger(NSInteger value) { return value + (token ? 1 : 0); });
    [token release];
    return block;
}
- (void)dealloc { if (initialized) --liveReceivers; [super dealloc]; }
@end

int main() {
    @autoreleasepool {
        {
            FixtureObject* object = [[FixtureObject alloc] init];
            auto getter = abi_bridge::objc_method<NSObject*()>(object, @selector(copyObject));
            auto transform = abi_bridge::objc_method<Transform()>(
                object, @selector(ownedTransform), {.returns_retained = true});
            [object release];
            assert(liveReceivers == 1);
            NSObject* kept = nil;
            @autoreleasepool {
                NSObject* result = getter.unsafe_invoke();
                assert(liveResults == 1);
                kept = [result retain];
            }
            assert(liveResults == 1);
            [kept release];
            assert(liveResults == 0);
            @autoreleasepool {
                Transform block = transform.unsafe_invoke();
                assert(block(41) == 42 && liveResults == 1);
            }
            assert(liveResults == 0);
        }
        assert(liveReceivers == 0);
        {
            FixtureObject* allocated = [FixtureObject alloc];
            auto initialize = abi_bridge::objc_method<FixtureObject*()>(allocated, @selector(init));
            [allocated release];
            @autoreleasepool {
                FixtureObject* result = initialize.unsafe_invoke();
                assert(result && liveReceivers == 1);
            }
            assert(liveReceivers == 1);
        }
        assert(liveReceivers == 0);
    }
    std::cout << "Manual-reference-counted Objective-C++ consumer passed.\n";
}
