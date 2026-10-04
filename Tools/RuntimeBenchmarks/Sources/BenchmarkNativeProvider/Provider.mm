#import "BenchmarkNativeProvider.h"
@implementation ABIPerfReceiver
- (int64_t)add:(int64_t)left right:(int64_t)right {
  return left + right;
}
@end
extern "C" __attribute__((noinline)) int32_t ABIPerfCAdd(int32_t a, int32_t b) {
  return a + b;
}
namespace ABIPerf {
__attribute__((noinline)) int add(int a, int b) { return a + b; }
} // namespace ABIPerf
