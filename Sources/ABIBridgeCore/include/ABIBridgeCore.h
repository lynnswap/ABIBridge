#ifndef ABIBRIDGE_CORE_H
#define ABIBRIDGE_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABIImageList ABIImageList;
typedef struct ABIImageLease ABIImageLease;

/// Information about one image load. This value does not retain the image.
typedef struct {
    /// In-process address of the Mach-O header.
    uintptr_t header;
    /// Displacement applied to link-time virtual addresses.
    intptr_t slide;
    /// Process-local identity of this load, distinct after unload/reload.
    uint64_t generation;
    /// LC_UUID bytes, or zero bytes when that command is absent.
    uint8_t uuid[16];
    /// Executable path, borrowed from the snapshot list.
    const char *path;
} ABIImageInfo;

/// Copies an immutable snapshot. The caller owns the list and frees it with
/// ABIFreeImageList. Path pointers remain valid until then. Returns null if the
/// process-lifetime catalog and its callback image cannot be retained.
ABIImageList *ABICopyLoadedImages(void);
/// Returns the number of entries in a non-null snapshot.
size_t ABIImageListCount(const ABIImageList *list);
/// Reads an entry. Index must be less than ABIImageListCount(list).
ABIImageInfo ABIImageListGet(const ABIImageList *list, size_t index);
/// Releases a snapshot and invalidates all path pointers borrowed from it.
void ABIFreeImageList(ABIImageList *list);

/// Acquires a loader reference without loading a missing image. Returns null
/// when the snapshot's generation is no longer loaded or cannot be retained.
ABIImageLease *ABIRetainLoadedImage(uint64_t generation);
/// Releases a lease. Actual unloading remains the dynamic loader's decision.
void ABIReleaseImage(ABIImageLease *lease);

/// Demangles an Itanium name with an optional Mach-O underscore. Returns null
/// when decoding fails; the caller frees a successful result with ABIFreeString.
char *ABICopyDemangledCXXName(const char *name);
/// Demangles a modern Swift symbol. Returns null when decoding is unavailable
/// or the name is unsupported. A successful result belongs to the caller.
char *ABICopyDemangledSwiftName(const char *name);
/// Frees a string returned by either demangling function.
void ABIFreeString(char *string);

#ifdef __cplusplus
}
#endif

#include <ABIBridge/Runtime.h>

#endif
