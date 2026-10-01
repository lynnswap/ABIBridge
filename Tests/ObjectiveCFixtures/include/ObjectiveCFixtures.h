#import <Foundation/Foundation.h>
#include "LazyLibraryFixtures.h"
#import "CFunctionFixtures.h"
#import "CXXObjectFixtures.h"
#import "ReplacementFixtures.h"
#include "PointerSlotFixtures.h"

#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct ABIInsetsFixture { double top, left, bottom, right; } ABIInsetsFixture;
typedef struct ABINestedAggregate {
    ABIInsetsFixture insets;
    double values[3];
    int32_t tag;
} ABINestedAggregate;
typedef struct ABIPaddedAggregate { double value; int8_t tag; } ABIPaddedAggregate;
typedef struct ABILongDoubleAggregate { long double value; int8_t tag; } ABILongDoubleAggregate;
@interface ABIAggregateFixture : NSObject
- (ABILongDoubleAggregate)transformLongDouble:(ABILongDoubleAggregate)value;
- (ABIPaddedAggregate)transformPadded:(ABIPaddedAggregate)value;
- (ABIInsetsFixture)transformInsets:(ABIInsetsFixture)value;
- (ABINestedAggregate)transformNested:(ABINestedAggregate)value;
- (CGAffineTransform)transformAffine:(CGAffineTransform)value;
@end

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
@property(nonatomic, copy, nullable) NSString *answerEncoding;
@property(nonatomic, readonly) NSInteger forwardedCalls;
@end
/// Keeps forwarded invocations to inspect their arguments after later calls.
@interface ABIEscapingForwardingFixture : NSObject
@property(nonatomic, readonly) NSArray<NSNumber *> *savedArguments;
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
- (ABIObjectBlock)retainedBlockHolding:(id)object __attribute__((ns_returns_retained));
- (nullable ABIIntegerBlock)nilBlock;
- (ABIArrayProvider)provider;
- (id)plainObject;
- (nullable id)eraseBlock:(nullable id)block;
@end
@interface ABIIvarFixture : NSObject
@property(nonatomic, strong, nullable) id inheritedObject;
@property(nonatomic, weak, nullable) id weakObject;
@property(nonatomic, unsafe_unretained, nullable) id unretainedObject;
@property(nonatomic, assign, nullable) Class classObject;
@property(nonatomic) NSInteger scalar;
@property(nonatomic) void *pointer;
@property(nonatomic) NSRange range;
@property(nonatomic, copy, nullable) ABIIntegerBlock block;
@end
@interface ABIIvarChild : ABIIvarFixture
@property(nonatomic, strong, nullable) id childObject;
@end
NS_ASSUME_NONNULL_END
