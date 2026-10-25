#ifndef ABIBRIDGE_HOOK_EFFECTS_H
#define ABIBRIDGE_HOOK_EFFECTS_H

#include <stdbool.h>
#include <stdint.h>

/// Installation and rollback outcomes of a managed hook slot.
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

#endif
