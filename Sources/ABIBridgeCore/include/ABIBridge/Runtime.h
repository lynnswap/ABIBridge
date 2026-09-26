#ifndef ABIBRIDGE_RUNTIME_H
#define ABIBRIDGE_RUNTIME_H

#include <ABIBridge/Inspection.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABIValueType ABIValueType;
/// Generic C entry point used by the internal call interfaces.
typedef void (*ABIUnmanagedFunction)(void);

/// Internal failure construction for the native backends. The caller supplies
/// a non-null UTF-8 message, which is copied into the returned owned failure.
ABIResolutionFailure *ABICreateResolutionFailure(int32_t code, const char *message);

// Internal acquisition primitives used by the shared resolver. A successful
// lease owns the dlopen reference; its info strings remain borrowed from it.
ABIImageLease *ABIOpenImage(const char *path, bool loadIfNeeded, ABIResolutionFailure **error);
ABIImageLease *ABIOpenLoadedImage(uint64_t generation, ABIResolutionFailure **error);
ABIImageInfo ABIImageLeaseGet(const ABIImageLease *lease);
bool ABIImageIsInSharedCache(const char *path);

#ifdef __cplusplus
}
#endif
#endif
