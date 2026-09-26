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
