#import <Foundation/Foundation.h>
#include <stdint.h>
NS_ASSUME_NONNULL_BEGIN
@interface ABIPerfReceiver : NSObject
- (int64_t)add:(int64_t)left right:(int64_t)right;
@end
#ifdef __cplusplus
extern "C" {
#endif
int32_t ABIPerfCAdd(int32_t left, int32_t right);
#ifdef __cplusplus
}
namespace ABIPerf {
int add(int left, int right);
}
#endif
NS_ASSUME_NONNULL_END
