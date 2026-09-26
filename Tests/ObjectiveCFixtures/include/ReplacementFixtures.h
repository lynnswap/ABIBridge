#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
typedef int32_t (^ABIReplacementBlock)(int32_t);

@interface ABIReplacementFixture : NSObject
@property(nonatomic, readonly) NSInteger calls;
@property(nonatomic, readonly) NSInteger liveResults;
@property(nonatomic, copy, nullable) ABIReplacementBlock storedBlock;
- (int32_t)add:(int32_t)a to:(int32_t)b;
- (int8_t)negate:(int8_t)value;
- (CGSize)resize:(CGSize)value;
- (CGRect)translate:(CGRect)value;
- (double)mixed:(int8_t)a b:(uint16_t)b c:(float)c d:(double)d e:(NSInteger)e
              f:(nullable void *)f g:(CGSize)g h:(CGRect)h i:(BOOL)i j:(int64_t)j k:(float)k l:(double)l;
- (nullable id)echo:(nullable id)value;
- (Class)echoClass:(Class)value;
- (void)accept:(nullable id)value;
- (NSObject *)object;
- (NSObject *)copyObject;
- (NSObject *)retainedObject __attribute__((ns_returns_retained));
- (NSObject *)newBorrowedObject __attribute__((objc_method_family(none)));
- (ABIReplacementBlock)block;
- (ABIReplacementBlock)retainedBlock __attribute__((ns_returns_retained));
- (int32_t)apply:(int32_t)value block:(nullable ABIReplacementBlock)block;
+ (int32_t)answer;
@end

int32_t ABIReplacementCallAdd(IMP implementation, ABIReplacementFixture *receiver, int32_t a, int32_t b);

@interface ABIReplacementInitializer : NSObject
@property(class, nonatomic, readonly) NSInteger liveObjects;
@property(class, nonatomic, readonly) NSInteger initializations;
- (nullable instancetype)initWithMode:(NSInteger)mode;
@end
@interface ABIReplacementInitializerChild : ABIReplacementInitializer
- (nullable instancetype)initWithMode:(NSInteger)mode;
@end

NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface ABIManagedHookFixture : ABIReplacementFixture
@property(nonatomic) NSInteger number;
- (NSInteger)sumThrough:(NSInteger)value;
- (int32_t)add:(int32_t)a to:(int32_t)b;
- (CGSize)resize:(CGSize)value;
@end
@interface ABIHookParent : NSObject
- (NSInteger)value;
+ (NSInteger)value;
@end
@interface ABIHookChild : ABIHookParent @end
@interface ABIHookSibling : ABIHookParent @end
IMP ABIHookForwardingImplementation(void);
@interface ABIHookExternalFixture : ABIManagedHookFixture @end
@interface ABIHookBenchmarkControl : ABIReplacementFixture @end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface ABIManagedInitializerFixture : NSObject
@property(class, nonatomic, readonly) NSInteger liveObjects;
@property(class, nonatomic, readonly) NSInteger initializations;
@property(nonatomic) NSInteger value;
@property(nonatomic, strong, nullable) id object;
- (nullable instancetype)initWithMode:(NSInteger)mode value:(NSInteger)value object:(nullable id)object;
- (instancetype)initWithValue:(NSInteger)value;
- (BOOL)containsIdenticalObject:(id)object;
- (instancetype)constructValue:(NSInteger)value __attribute__((objc_method_family(init)));
@end
@interface ABIManagedInitializerChild : ABIManagedInitializerFixture
- (nullable instancetype)initWithMode:(NSInteger)mode value:(NSInteger)value object:(nullable id)object;
@end
@interface ABIManagedInitializerInherited : ABIManagedInitializerFixture @end
ABIManagedInitializerFixture *ABIManagedConstruct(NSInteger value);
NS_ASSUME_NONNULL_END
