#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
NS_ASSUME_NONNULL_BEGIN
@interface ABIPerfReceiver : NSObject
- (int64_t)add:(int64_t)left right:(int64_t)right;
- (CGSize)shiftSize:(CGSize)value;
- (id)echoObject:(id)value;
@end
#ifdef __cplusplus
extern "C" {
#endif
int32_t ABIPerfCAdd(int32_t left, int32_t right);
int64_t ABIPerfRead(const int64_t *value);
#ifdef __cplusplus
}
namespace ABIPerf {
int add(int left, int right);
}
#endif
NS_ASSUME_NONNULL_END
