#import <Foundation/Foundation.h>
#import "CFunctionFixtures.h"
#import "CXXObjectFixtures.h"

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
typedef int32_t (^ABIIntegerBlock)(int32_t);
typedef id _Nonnull (^ABIObjectBlock)(void);
typedef void (^ABIArrayCompletion)(NSArray<NSString *> *);
typedef void (^ABIArrayProvider)(ABIArrayCompletion);
@interface ABIBlockFixture : NSObject
@property(nonatomic, copy, nullable) ABIIntegerBlock handler;
- (int32_t)apply:(int32_t)value using:(nullable ABIIntegerBlock)block;
- (ABIObjectBlock)blockHolding:(id)object;
- (ABIObjectBlock)copyBlockHolding:(id)object;
- (nullable ABIIntegerBlock)nilBlock;
- (ABIArrayProvider)provider;
- (id)plainObject;
- (nullable id)eraseBlock:(nullable id)block;
@end
NS_ASSUME_NONNULL_END
