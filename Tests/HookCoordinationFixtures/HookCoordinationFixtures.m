#import "include/HookCoordinationFixtures.h"
@implementation ABICoordinationOwner
- (id)retain {
    id result = [super retain];
    void (^action)(void) = [_onRetain copy];
    self.onRetain = nil;
    if (action) action();
    [action release];
    return result;
}
- (void)dealloc { [_onRetain release]; [super dealloc]; }
@end

@interface ABIDestructorHookFixture ()
@property(nonatomic) NSInteger created;
@property(nonatomic) NSInteger destroyed;
@property(nonatomic) NSInteger releasesDuringDestruction;
@end
@interface ABIDestructorHookResult ()
- (instancetype)initWithFixture:(ABIDestructorHookFixture *)fixture identifier:(NSInteger)identifier;
@end
@implementation ABIDestructorHookResult {
    ABIDestructorHookFixture *_fixture;
    BOOL _destroying;
}
- (instancetype)initWithFixture:(ABIDestructorHookFixture *)fixture identifier:(NSInteger)identifier {
    if ((self = [super init])) { _fixture = [fixture retain]; _identifier = identifier; }
    return self;
}
- (oneway void)release {
    if (_destroying) ++_fixture.releasesDuringDestruction;
    [super release];
}
- (void)dealloc {
    _destroying = YES;
    ++_fixture.destroyed;
    if (_identifier == 1) {
        void (^action)(void) = [_fixture.onFirstDestruction copy];
        _fixture.onFirstDestruction = nil;
        if (action) action();
        [action release];
    }
    [_fixture release];
    [super dealloc];
}
@end
@implementation ABIDestructorHookFixture
- (ABIDestructorHookResult *)newResult { return [self newUnhookedResult]; }
- (ABIDestructorHookResult *)newUnhookedResult {
    return [[ABIDestructorHookResult alloc] initWithFixture:self identifier:++_created];
}
- (void)dealloc { [_onFirstDestruction release]; [super dealloc]; }
@end
