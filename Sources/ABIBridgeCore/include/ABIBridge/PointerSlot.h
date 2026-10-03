#ifndef ABIBRIDGE_POINTER_SLOT_H
#define ABIBRIDGE_POINTER_SLOT_H

#include <ABIBridge/NativeDispatch.h>

#ifdef __cplusplus
extern "C" {
#endif

// Internal mutation transport, not a supported consumer hook API.
enum {
    ABIPointerSlotComplete = 0,
    ABIPointerSlotInvalidStorage,
    ABIPointerSlotQueryFailed,
    ABIPointerSlotReadFailed,
    ABIPointerSlotExecutableStorage,
    ABIPointerSlotDisplaced,
    ABIPointerSlotProtectFailed,
    ABIPointerSlotRestoreFailed
};

typedef struct {
    int32_t status;
    bool didWrite;
    uintptr_t observed;
    int32_t systemErrorCode;
    int32_t restoreProtectionError;
    int32_t restoreMaximumError;
    int32_t protectionBefore;
    int32_t maximumBefore;
    uint32_t regionFlags;
} ABIPointerSlotResult;

/// Compares and exchanges the pointer representation in aligned data storage.
/// Calls through this transport serialize protection changes, including changes
/// on a shared page. The caller keeps the storage mapped, coordinates all other
/// writers/protection changes, and keeps both old/new code and pointees alive.
/// An atomic pointer change does not make a multi-slot update atomic.
///
/// Observed holds the original/read or competing pointer bits when available.
/// On any result, didWrite identifies whether this operation published the new
/// value. Failed protection restoration does not automatically roll it back.
/// Both restoration errors are preserved, including with a displaced result.
/// Executable pages are rejected; this operation never patches instructions.
ABIPointerSlotResult ABICompareExchangePointerSlot(void *storage, uintptr_t expected, uintptr_t replacement);

// Internal retry of failed protection restoration. Does not write a pointer.
ABIPointerSlotResult ABIRestorePointerSlotProtection(void *storage, uintptr_t expected,
    int32_t protection, int32_t maximum, bool restoreCurrent, bool restoreMaximum);

/// Re-signs an already valid generic C function pointer for the target slot's
/// explicit schema. On unsigned storage it authenticates before removing the
/// signature. A nil function encodes zero. Invalid storage/schema returns false.
/// Authentication failure may fault; it is not converted to false or repaired.
/// No storage is read or changed. The caller verifies the function's native ABI.
bool ABIEncodePointerSlotFunction(ABIUnmanagedFunction function, const void *storage,
    int32_t key, uintptr_t discriminator, bool addressDiversity, uintptr_t *bits);

/// Signs a raw data pointer for a slot with an established data schema.
bool ABIEncodePointerSlotData(const void *pointer, const void *storage,
    int32_t key, uintptr_t discriminator, bool addressDiversity, uintptr_t *bits);

#ifdef __cplusplus
}
#endif
#endif
