#import "CFunctionFixtures.h"

int32_t ABICAnswer(void) { return 42; }
int8_t ABICNegative(void) { return -42; }
bool ABICNegate(bool value) { return !value; }
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
