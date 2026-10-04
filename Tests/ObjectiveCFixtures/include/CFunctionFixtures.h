#import <Foundation/Foundation.h>
#import <CoreGraphics/CGGeometry.h>
#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT int32_t ABICAnswer(void);
FOUNDATION_EXPORT int8_t ABICNegative(void);
FOUNDATION_EXPORT bool ABICNegate(bool value);
FOUNDATION_EXPORT double ABICVariadicMix(float prefix, int32_t count, ...);
FOUNDATION_EXPORT double ABICVariadicMixOracle(float prefix, int32_t count, int8_t signedValue,
    uint16_t unsignedValue, bool boolean, float real, const void * _Nullable pointer, CGPoint point);
FOUNDATION_EXPORT double ABICVariadicSum(int32_t count, ...);
FOUNDATION_EXPORT double ABICVariadicStackOracle(void);
FOUNDATION_EXPORT double ABICMixed(int8_t a, uint16_t b, int32_t c, uint64_t d,
    float e, double f, bool g, const void * _Nullable h, int64_t i, double j, uintptr_t k, int32_t l);
FOUNDATION_EXPORT CGRect ABICRect(CGRect value);
FOUNDATION_EXPORT CGPoint ABICPoint(CGPoint value);
FOUNDATION_EXPORT CGSize ABICSize(CGSize value);
FOUNDATION_EXPORT NSRange ABICRange(NSRange value);
FOUNDATION_EXPORT void * _Nullable ABICPointer(void * _Nullable value);
FOUNDATION_EXPORT void ABICStore(int32_t *value);
FOUNDATION_EXPORT int32_t ABICIncrement(int32_t value);
typedef struct ABIAdapterPair { double left; double right; } ABIAdapterPair;
FOUNDATION_EXPORT ABIAdapterPair ABICTransformPair(ABIAdapterPair value, int32_t *calls);
FOUNDATION_EXPORT void * _Nullable ABICCreateResource(int32_t *live);
FOUNDATION_EXPORT int32_t ABICReadResource(const void *resource);
FOUNDATION_EXPORT void ABICDestroyResource(void *resource);
FOUNDATION_EXPORT CFTypeRef _Nullable ABICEchoCFValue(CFTypeRef _Nullable value) CF_RETURNS_NOT_RETAINED;
FOUNDATION_EXPORT CFTypeRef ABICRetainCFValue(CFTypeRef value) CF_RETURNS_RETAINED;
FOUNDATION_EXPORT void ABICConsumeCFValue(CFTypeRef CF_CONSUMED value);
NS_ASSUME_NONNULL_END
