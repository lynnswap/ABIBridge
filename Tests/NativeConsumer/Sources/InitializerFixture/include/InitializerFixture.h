#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface ABISwiftInitializerFixture : NSObject
@property(class, nonatomic, readonly) NSInteger prematureRetains;
@property(class, nonatomic, readonly) NSInteger liveObjects;
@property(nonatomic) NSInteger total;
- (nullable instancetype)initWithLeft:(NSInteger)left right:(NSInteger)right fail:(BOOL)fail;
@end
NS_ASSUME_NONNULL_END
