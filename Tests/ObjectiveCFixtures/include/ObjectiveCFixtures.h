#import <Foundation/Foundation.h>
#import "CFunctionFixtures.h"

NS_ASSUME_NONNULL_BEGIN

typedef union ABIUnionFixture { NSInteger integer; double real; } ABIUnionFixture;
@interface ABIOwnershipFixture : NSObject
@property(nonatomic, readonly) NSInteger liveResults;
@property(nonatomic, readonly) NSInteger classCalls;
- (NSObject *)object;
- (NSObject *)copyObject;
- (NSObject *)retainedObject __attribute__((ns_returns_retained));
- (NSObject *)newBorrowedObject __attribute__((objc_method_family(none)));
- (signed char)negateCharacterBoolean:(signed char)value;
- (Class)echoClass:(Class)value;
- (SEL)echoSelector:(SEL)value;
- (ABIUnionFixture)unionValue;
- (ABIUnionFixture *)unionPointer:(ABIUnionFixture *)value;
@end

@interface ABIInitializerFixture : NSObject
- (instancetype)initWithReplacement;
- (nullable instancetype)initReturningNil;
@end

/// A forwarding-only receiver with no concrete implementation of answer.
@interface ABIForwardingFixture : NSObject
@end
NS_ASSUME_NONNULL_END
