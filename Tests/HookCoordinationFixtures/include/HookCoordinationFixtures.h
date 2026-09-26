#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// A deterministic external writer triggered by fallback-owner retention during
/// activation. Validation only inspects the target and never retains this owner.
@interface ABICoordinationOwner : NSObject
@property(nonatomic, copy, nullable) void (^onRetain)(void);
@end
NS_ASSUME_NONNULL_END
