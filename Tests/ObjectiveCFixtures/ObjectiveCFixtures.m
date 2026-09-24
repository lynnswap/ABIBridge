#import "ObjectiveCFixtures.h"
#import <objc/runtime.h>

@implementation ABIBlockFixture
- (int32_t)apply:(int32_t)value using:(ABIIntegerBlock)block { return block ? block(value) : -1; }
- (ABIObjectBlock)blockHolding:(id)object { return [^{ return object; } copy]; }
- (ABIObjectBlock)copyBlockHolding:(id)object { return [^{ return object; } copy]; }
- (ABIIntegerBlock)nilBlock { return nil; }
- (ABIArrayProvider)provider {
    return ^(ABIArrayCompletion completion) { completion(@[@"first", @"second"]); };
}
- (id)plainObject { return [NSObject new]; }
- (id)eraseBlock:(id)block { return block; }
@end


@interface ABIOwnershipFixture ()
@property(nonatomic) NSInteger liveResults;
@property(nonatomic) NSInteger classCalls;
@end

@interface ABICountedResult : NSObject
@property(nonatomic, strong) ABIOwnershipFixture *fixture;
- (instancetype)initWithFixture:(ABIOwnershipFixture *)fixture;
@end
@implementation ABICountedResult
- (instancetype)initWithFixture:(ABIOwnershipFixture *)fixture {
    if ((self = [super init])) {
        _fixture = fixture;
        fixture.liveResults += 1;
    }
    return self;
}
- (void)dealloc { _fixture.liveResults -= 1; }
@end

@implementation ABIOwnershipFixture
- (NSObject *)object { return [[ABICountedResult alloc] initWithFixture:self]; }
- (NSObject *)copyObject { return [[ABICountedResult alloc] initWithFixture:self]; }
- (NSObject *)retainedObject { return [[ABICountedResult alloc] initWithFixture:self]; }
- (NSObject *)newBorrowedObject { return [[ABICountedResult alloc] initWithFixture:self]; }
- (signed char)negateCharacterBoolean:(signed char)value { return value ? 0 : -1; }
- (Class)echoClass:(Class)value { self.classCalls += 1; return value; }
- (SEL)echoSelector:(SEL)value { return value; }
- (ABIUnionFixture)unionValue { return (ABIUnionFixture){.integer = 42}; }
- (ABIUnionFixture *)unionPointer:(ABIUnionFixture *)value { return value; }
@end

@implementation ABIInitializerFixture
- (instancetype)initWithReplacement { return [[ABIInitializerFixture alloc] init]; }
- (instancetype)initReturningNil { return nil; }
@end

@implementation ABIForwardingFixture
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (sel_isEqual(selector, NSSelectorFromString(@"answer"))) {
        return [NSMethodSignature signatureWithObjCTypes:"q@:"];
    }
    return [super methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    if (sel_isEqual(invocation.selector, NSSelectorFromString(@"answer"))) {
        NSInteger result = 61;
        [invocation setReturnValue:&result];
    } else {
        [super forwardInvocation:invocation];
    }
}
@end
