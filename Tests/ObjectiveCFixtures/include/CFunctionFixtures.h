#import <Foundation/Foundation.h>
#import <CoreGraphics/CGGeometry.h>
#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT int32_t ABICAnswer(void);
FOUNDATION_EXPORT int8_t ABICNegative(void);
FOUNDATION_EXPORT bool ABICNegate(bool value);
FOUNDATION_EXPORT double ABICMixed(int8_t a, uint16_t b, int32_t c, uint64_t d,
    float e, double f, bool g, const void * _Nullable h, int64_t i, double j, uintptr_t k, int32_t l);
FOUNDATION_EXPORT CGRect ABICRect(CGRect value);
FOUNDATION_EXPORT CGPoint ABICPoint(CGPoint value);
FOUNDATION_EXPORT CGSize ABICSize(CGSize value);
FOUNDATION_EXPORT NSRange ABICRange(NSRange value);
FOUNDATION_EXPORT void * _Nullable ABICPointer(void * _Nullable value);
FOUNDATION_EXPORT void ABICStore(int32_t *value);
FOUNDATION_EXPORT int32_t ABICIncrement(int32_t value);
NS_ASSUME_NONNULL_END
