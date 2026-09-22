#ifndef ABIBRIDGE_CORE_H
#define ABIBRIDGE_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABIImageList ABIImageList;
typedef struct ABIImageLease ABIImageLease;

typedef struct {
    uintptr_t header;
    intptr_t slide;
    uint64_t generation;
    uint8_t uuid[16];
    const char *path;
} ABIImageInfo;

/// Returns an immutable snapshot. Path pointers are valid until the list is freed.
ABIImageList *ABICopyLoadedImages(void);
size_t ABIImageListCount(const ABIImageList *list);
ABIImageInfo ABIImageListGet(const ABIImageList *list, size_t index);
void ABIFreeImageList(ABIImageList *list);

/// Acquires a loader reference without loading a missing image. Returns null
/// when the snapshot's generation is no longer loaded or cannot be retained.
ABIImageLease *ABIRetainLoadedImage(uint64_t generation);
void ABIReleaseImage(ABIImageLease *lease);

/// The caller frees a successful demangle result with ABIFreeString.
char *ABICopyDemangledCXXName(const char *name);
char *ABICopyDemangledSwiftName(const char *name);
void ABIFreeString(char *string);

#ifdef __cplusplus
}
#endif

#endif
