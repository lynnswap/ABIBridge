#ifndef ABI_LAZY_LIBRARY_FIXTURE_H
#define ABI_LAZY_LIBRARY_FIXTURE_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

enum { ABITestLazySize = 8192, ABITestLazyPayload = 4096, ABITestLazyFlag = 512 };

static inline void ABITestLazyPut(unsigned char *p, uint64_t value, unsigned count, int swapped) {
    for (unsigned i = 0; i < count; ++i) p[swapped ? count - i - 1 : i] = (unsigned char)(value >> (i * 8));
}

static inline unsigned char *ABITestLazyCreate(int wide, int swapped) {
    unsigned char *p = (unsigned char *)calloc(1, ABITestLazySize);
    if (!p) return NULL;
    const unsigned header = wide ? 32 : 28, segmentSize = wide ? 72 : 56;
    const uint64_t base = wide ? UINT64_C(0x100000000) : UINT64_C(0x10000000);
    ABITestLazyPut(p, wide ? 0xfeedfacf : 0xfeedface, 4, swapped);
    ABITestLazyPut(p + 4, wide ? 0x100000c : 12, 4, swapped);
    ABITestLazyPut(p + 8, 2, 4, swapped);
    ABITestLazyPut(p + 12, 6, 4, swapped);
    ABITestLazyPut(p + 16, 5, 4, swapped);
    ABITestLazyPut(p + 20, 2 * segmentSize + 3 * 16, 4, swapped);
    for (unsigned i = 0; i < 2; ++i) {
        unsigned char *segment = p + header + i * segmentSize;
        ABITestLazyPut(segment, wide ? 0x19 : 1, 4, swapped);
        ABITestLazyPut(segment + 4, segmentSize, 4, swapped);
        strcpy((char *)segment + 8, i ? "__LINKEDIT" : "__TEXT");
        const unsigned fieldSize = wide ? 8 : 4;
        ABITestLazyPut(segment + 24, base + i * 4096, fieldSize, swapped);
        ABITestLazyPut(segment + 24 + fieldSize, 4096, fieldSize, swapped);
        ABITestLazyPut(segment + 24 + 2 * fieldSize, i * 4096, fieldSize, swapped);
        ABITestLazyPut(segment + 24 + 3 * fieldSize, 4096, fieldSize, swapped);
    }
    for (unsigned i = 0; i < 3; ++i) {
        unsigned char *command = p + header + 2 * segmentSize + i * 16;
        ABITestLazyPut(command, 0x3a, 4, swapped); // LC_LAZY_LOAD_DYLIB_INFO
        ABITestLazyPut(command + 4, 16, 4, swapped);
        ABITestLazyPut(command + 8, 4096 + i * 512, 4, swapped);
        ABITestLazyPut(command + 12, i == 2 ? 8 : 256, 4, swapped);
        if (i == 2) continue; // Intentionally truncated payload, retained in diagnostics.
        unsigned char *payload = p + 4096 + i * 512;
        ABITestLazyPut(payload, 24, 4, swapped);
        ABITestLazyPut(payload + 4, ABITestLazyFlag + i * 4, 4, swapped);
        ABITestLazyPut(payload + 8, i ? 2 : 1, 2, swapped);
        ABITestLazyPut(payload + 10, 1, 2, swapped);
        ABITestLazyPut(payload + 12, 0xfffffff0, 4, swapped); // No chain may be walked.
        ABITestLazyPut(payload + 16, i ? 0 : 3, 4, swapped);
        ABITestLazyPut(payload + 20, 64, 4, swapped);
        strcpy((char *)payload + 24, i ? "@rpath/Prebound.dylib" : "@rpath/Example.dylib");
        if (!i) {
            unsigned offset = 80;
            const char *names[] = {"__ZN7Example8Renderer7refreshEv", "_$s9LazyTests4echoyyF", "_plainSymbol"};
            for (unsigned s = 0; s < 3; ++s) {
                ABITestLazyPut(payload + 64 + s * 4, offset, 4, swapped);
                strcpy((char *)payload + offset, names[s]);
                offset += (unsigned)strlen(names[s]) + 1;
            }
        }
    }
    ABITestLazyPut(p + ABITestLazyFlag + 4, 1, 4, swapped);
    return p;
}

static inline int ABITestLazyWrite(const char *path, const unsigned char *bytes) {
    FILE *file = fopen(path, "wb");
    if (!file) return 0;
    const int wrote = fwrite(bytes, 1, ABITestLazySize, file) == ABITestLazySize;
    const int closed = fclose(file) == 0;
    return wrote && closed;
}
#endif
