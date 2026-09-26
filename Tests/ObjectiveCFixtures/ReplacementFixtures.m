#import "ReplacementFixtures.h"
#include <stdatomic.h>

@interface ABIReplacementFixture ()
@property(nonatomic) NSInteger calls;
@property(nonatomic) NSInteger liveResults;
@end

int32_t ABIReplacementCallAdd(IMP implementation, ABIReplacementFixture *receiver, int32_t a, int32_t b) {
    return ((int32_t (*)(id, SEL, int32_t, int32_t))implementation)(receiver, @selector(add:to:), a, b);
}
@interface ABIReplacementResult : NSObject
@property(nonatomic, strong) ABIReplacementFixture *owner;
- (instancetype)initWithOwner:(ABIReplacementFixture *)owner;
@end
@implementation ABIReplacementResult
- (instancetype)initWithOwner:(ABIReplacementFixture *)owner {
    if ((self = [super init])) { _owner = owner; owner.liveResults++; }
    return self;
}
- (void)dealloc { _owner.liveResults--; }
@end

@implementation ABIReplacementFixture
- (int32_t)add:(int32_t)a to:(int32_t)b { self.calls++; return a + b; }
- (int8_t)negate:(int8_t)value { return -value; }
- (CGSize)resize:(CGSize)value { return CGSizeMake(value.width + 1, value.height + 2); }
- (CGRect)translate:(CGRect)value { return CGRectOffset(value, 3, 5); }
- (double)mixed:(int8_t)a b:(uint16_t)b c:(float)c d:(double)d e:(NSInteger)e
              f:(void *)f g:(CGSize)g h:(CGRect)h i:(BOOL)i j:(int64_t)j k:(float)k l:(double)l {
    return a + b*2 + c*3 + d*4 + e*5 + (uintptr_t)f*6 + g.width*7 + g.height*8
        + h.origin.x*9 + h.origin.y*10 + h.size.width*11 + h.size.height*12
        + i*13 + j*14 + k*15 + l*16;
}
- (id)echo:(id)value { self.calls++; return value; }
- (Class)echoClass:(Class)value { return value; }
- (void)accept:(id)value { self.calls++; }
- (NSObject *)object { return [[ABIReplacementResult alloc] initWithOwner:self]; }
- (NSObject *)copyObject { return [[ABIReplacementResult alloc] initWithOwner:self]; }
- (NSObject *)retainedObject { return [[ABIReplacementResult alloc] initWithOwner:self]; }
- (NSObject *)newBorrowedObject { return [[ABIReplacementResult alloc] initWithOwner:self]; }
- (ABIReplacementBlock)block { return ^(int32_t value) { return value + 10; }; }
- (ABIReplacementBlock)retainedBlock { return [^(int32_t value) { return value + 20; } copy]; }
- (int32_t)apply:(int32_t)value block:(ABIReplacementBlock)block { self.storedBlock = block; return block ? block(value) : -1; }
+ (int32_t)answer { return 42; }
@end

static atomic_long liveObjects;
static atomic_long initializations;
@interface ABIReplacementInitializerOther : ABIReplacementInitializer @end
@implementation ABIReplacementInitializerOther @end
@implementation ABIReplacementInitializer
+ (id)allocWithZone:(struct _NSZone *)zone { atomic_fetch_add(&liveObjects, 1); return [super allocWithZone:zone]; }
+ (NSInteger)liveObjects { return atomic_load(&liveObjects); }
+ (NSInteger)initializations { return atomic_load(&initializations); }
- (instancetype)initWithMode:(NSInteger)mode {
    atomic_fetch_add(&initializations, 1);
    if (mode == 1) return nil;
    if (mode == 2) return [[ABIReplacementInitializerOther alloc] initWithMode:0];
    return [super init];
}
- (void)dealloc { atomic_fetch_sub(&liveObjects, 1); }
@end
@implementation ABIReplacementInitializerChild
- (instancetype)initWithMode:(NSInteger)mode { return [super initWithMode:mode]; }
@end
