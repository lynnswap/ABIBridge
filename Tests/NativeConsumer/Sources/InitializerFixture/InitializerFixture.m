#import "InitializerFixture.h"
#include <stdatomic.h>

static atomic_long prematureRetains;
static atomic_long liveObjects;
@implementation ABISwiftInitializerFixture {
    BOOL _initialized;
}
+ (id)allocWithZone:(struct _NSZone *)zone {
    atomic_fetch_add(&liveObjects, 1);
    return [super allocWithZone:zone];
}
+ (NSInteger)prematureRetains { return atomic_load(&prematureRetains); }
+ (NSInteger)liveObjects { return atomic_load(&liveObjects); }
- (instancetype)initWithLeft:(NSInteger)left right:(NSInteger)right fail:(BOOL)fail {
    if (fail) { [self release]; return nil; }
    if ((self = [super init])) { _initialized = YES; _total = left + right; }
    return self;
}
// MRC makes unexpected retaining of uninitialized self observable without
// adding a Swift reference or using private runtime reference-count inspection.
- (id)retain {
    if (!_initialized) atomic_fetch_add(&prematureRetains, 1);
    return [super retain];
}
- (void)dealloc { atomic_fetch_sub(&liveObjects, 1); [super dealloc]; }
@end
