#import "CFunctionFixtures.h"
#include <stdlib.h>
#include <stdarg.h>
#include "CXXObjectFixtures.h"

int32_t ABICNextRecordMode(int32_t value) { return value == 7 ? 42 : 7; }

ABICXXRecord ABICTransformRecord(ABICXXRecord value) {
    value.value += 1.5; value.tag += 2;
    return value;
}
ABICXXNestedRecord ABICTransformNestedRecord(ABICXXNestedRecord value) {
    value.first = ABICTransformRecord(value.first);
    value.second += 3;
    return value;
}

ABICWideResult ABICMakeWideResult(uint64_t seed) {
    ABICWideResult result = {0};
    for (uint64_t index = 0; index < 12; ++index) result.values[index] = seed + index * index;
    return result;
}

int32_t ABICAnswer(void) { return 42; }
int8_t ABICNegative(void) { return -42; }
bool ABICNegate(bool value) { return !value; }
double ABICVariadicMix(float prefix, int32_t count, ...) {
    va_list arguments;
    va_start(arguments, count);
    int signedValue = va_arg(arguments, int);
    int unsignedValue = va_arg(arguments, int);
    int boolean = va_arg(arguments, int);
    double real = va_arg(arguments, double);
    const void *pointer = va_arg(arguments, const void *);
    CGPoint point = va_arg(arguments, CGPoint);
    va_end(arguments);
    return prefix + count + signedValue + unsignedValue + boolean + real + (pointer != NULL) + point.x + point.y;
}
double ABICVariadicMixOracle(float prefix, int32_t count, int8_t signedValue,
    uint16_t unsignedValue, bool boolean, float real, const void *pointer, CGPoint point) {
    return ABICVariadicMix(prefix, count, signedValue, unsignedValue, boolean, real, pointer, point);
}
double ABICVariadicSum(int32_t count, ...) {
    va_list arguments;
    va_start(arguments, count);
    double result = 0;
    for (int32_t index = 0; index < count; ++index) result += va_arg(arguments, double);
    va_end(arguments);
    return result;
}
double ABICVariadicStackOracle(void) {
    return ABICVariadicSum(12, 1.0f, 2.0, 3.0f, 4.0, 5.0f, 6.0, 7.0f, 8.0, 9.0, 10.0, 11.0f, 12.0);
}
double ABICMixed(int8_t a, uint16_t b, int32_t c, uint64_t d,
    float e, double f, bool g, const void *h, int64_t i, double j, uintptr_t k, int32_t l) {
    return a + b + c + d + e + f + g + (h != NULL) + i + j + k + l;
}
CGRect ABICRect(CGRect value) { value.size.width += 1; return value; }
CGPoint ABICPoint(CGPoint value) { value.x += 1; return value; }
CGSize ABICSize(CGSize value) { value.height += 1; return value; }
NSRange ABICRange(NSRange value) { value.length += 1; return value; }
void *ABICPointer(void *value) { return value; }
void ABICStore(int32_t *value) { *value = 42; }
int32_t ABICIncrement(int32_t value) { return value + 1; }

ABIAdapterPair ABICTransformPair(ABIAdapterPair value, int32_t *calls) {
    *calls += 1;
    return (ABIAdapterPair){value.left + 1, value.right + 2};
}
typedef struct ABIAdapterResource { int32_t *live; int32_t value; } ABIAdapterResource;
void *ABICCreateResource(int32_t *live) {
    ABIAdapterResource *resource = malloc(sizeof(*resource));
    if (!resource) return NULL;
    resource->live = live;
    resource->value = 73;
    *live += 1;
    return resource;
}
int32_t ABICReadResource(const void *resource) { return ((const ABIAdapterResource *)resource)->value; }
void ABICDestroyResource(void *resource) {
    ABIAdapterResource *value = resource;
    *value->live -= 1;
    free(value);
}

CFTypeRef ABICEchoCFValue(CFTypeRef value) { return value; }
CFTypeRef ABICRetainCFValue(CFTypeRef value) { return CFRetain(value); }
void ABICConsumeCFValue(CFTypeRef value) { CFRelease(value); }
