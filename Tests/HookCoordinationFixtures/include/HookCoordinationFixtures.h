#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// A deterministic external writer triggered by fallback-owner retention during
/// activation. Validation only inspects the target and never retains this owner.
@interface ABICoordinationOwner : NSObject
@property(nonatomic, copy, nullable) void (^onRetain)(void);
@end
@interface ABIDestructorHookResult : NSObject
@property(nonatomic, readonly) NSInteger identifier;
@end
@interface ABIDestructorHookFixture : NSObject
@property(nonatomic, readonly) NSInteger created;
@property(nonatomic, readonly) NSInteger destroyed;
@property(nonatomic, readonly) NSInteger releasesDuringDestruction;
@property(nonatomic, copy, nullable) void (^onFirstDestruction)(void);
- (ABIDestructorHookResult *)newResult;
- (ABIDestructorHookResult *)newUnhookedResult;
@end
NS_ASSUME_NONNULL_END
