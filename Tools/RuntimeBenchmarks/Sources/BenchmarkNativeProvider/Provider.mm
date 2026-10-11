#import "BenchmarkNativeProvider.h"
@implementation ABIPerfReceiver
- (int64_t)add:(int64_t)left right:(int64_t)right {
  return left + right;
}
- (CGSize)shiftSize:(CGSize)value {
  return CGSizeMake(value.width + 7, value.height);
}
- (id)echoObject:(id)value { return value; }
@end
extern "C" __attribute__((noinline)) int32_t ABIPerfCAdd(int32_t a, int32_t b) {
  return a + b;
}
extern "C" __attribute__((noinline)) int64_t ABIPerfRead(const int64_t *value) {
  return *value + 7;
}
namespace ABIPerf {
__attribute__((noinline)) int add(int a, int b) { return a + b; }
} // namespace ABIPerf
