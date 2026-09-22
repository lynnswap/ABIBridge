#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface ABIOwnershipFixture : NSObject
@property(nonatomic, readonly) NSInteger liveResults;
- (NSObject *)object;
- (NSObject *)copyObject;
- (NSObject *)retainedObject __attribute__((ns_returns_retained));
- (NSObject *)newBorrowedObject __attribute__((objc_method_family(none)));
- (signed char)negateCharacterBoolean:(signed char)value;
- (Class)echoClass:(Class)value;
- (SEL)echoSelector:(SEL)value;
@end

@interface ABIInitializerFixture : NSObject
- (instancetype)initWithReplacement;
- (nullable instancetype)initReturningNil;
@end

/// A forwarding-only receiver with no concrete implementation of answer.
@interface ABIForwardingFixture : NSObject
@end
NS_ASSUME_NONNULL_END
