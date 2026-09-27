#pragma once
#include <ABIBridge/PointerSlot.h>
#include <mach/mach.h>

namespace abibridge {
struct SlotRegion {
    vm_prot_t protection = 0;
    vm_prot_t maximum = 0;
    uint32_t flags = 0;
};

// The VM transport is injected only at this internal boundary. Production and
// failure fixtures run the same mutation/recovery sequence without global hooks.
template <class Memory>
ABIPointerSlotResult exchangePointerSlot(Memory& memory, uintptr_t address, uintptr_t expected, uintptr_t replacement) {
    ABIPointerSlotResult result{};
    auto failed = [&](int32_t status, kern_return_t code = KERN_SUCCESS) {
        result.status = status;
        result.systemErrorCode = code;
        return result;
    };
    if (!address || address % alignof(uintptr_t) != 0 || address > UINTPTR_MAX - sizeof(uintptr_t))
        return failed(ABIPointerSlotInvalidStorage);
    SlotRegion region;
    auto code = memory.query(address, region);
    if (code != KERN_SUCCESS) return failed(ABIPointerSlotQueryFailed, code);
    result.protectionBefore = region.protection;
    result.maximumBefore = region.maximum;
    result.regionFlags = region.flags;
    if (region.protection & VM_PROT_EXECUTE) return failed(ABIPointerSlotExecutableStorage);
    code = memory.read(address, result.observed);
    if (code != KERN_SUCCESS) return failed(ABIPointerSlotReadFailed, code);
    if (result.observed != expected) return failed(ABIPointerSlotDisplaced);
    const bool makeWritable = !(region.protection & VM_PROT_WRITE);
    const bool copy = makeWritable && !(region.maximum & VM_PROT_WRITE);
    if (makeWritable) {
        code = memory.protect(address, false, region.protection | VM_PROT_WRITE | (copy ? VM_PROT_COPY : 0));
        if (code != KERN_SUCCESS) return failed(ABIPointerSlotProtectFailed, code);
    }
    result.observed = expected;
    result.didWrite = memory.exchange(address, result.observed, replacement);
    result.status = result.didWrite ? ABIPointerSlotComplete : ABIPointerSlotDisplaced;
    if (makeWritable) {
        result.restoreProtectionError = memory.protect(address, false, region.protection);
        if (copy) result.restoreMaximumError = memory.protect(address, true, region.maximum);
        if (result.status == ABIPointerSlotComplete && (result.restoreProtectionError || result.restoreMaximumError))
            result.status = ABIPointerSlotRestoreFailed;
    }
    return result;
}
}

namespace abibridge {
// Retry only protections that a preceding pointer operation failed to restore.
// The expected representation prevents repairing a slot already displaced by
// another writer; callers still coordinate changes elsewhere on the same page.
template <class Memory>
ABIPointerSlotResult restorePointerSlotProtection(Memory& memory, uintptr_t address, uintptr_t expected,
    vm_prot_t protection, vm_prot_t maximum, bool restoreCurrent, bool restoreMaximum) {
    ABIPointerSlotResult result{};
    if (!address || address % alignof(uintptr_t) != 0 || address > UINTPTR_MAX - sizeof(uintptr_t)) {
        result.status = ABIPointerSlotInvalidStorage; return result;
    }
    SlotRegion region;
    auto code = memory.query(address, region);
    if (code != KERN_SUCCESS) { result.status = ABIPointerSlotQueryFailed; result.systemErrorCode = code; return result; }
    result.protectionBefore = region.protection; result.maximumBefore = region.maximum; result.regionFlags = region.flags;
    if (region.protection & VM_PROT_EXECUTE) { result.status = ABIPointerSlotExecutableStorage; return result; }
    code = memory.read(address, result.observed);
    if (code != KERN_SUCCESS) { result.status = ABIPointerSlotReadFailed; result.systemErrorCode = code; return result; }
    if (result.observed != expected) { result.status = ABIPointerSlotDisplaced; return result; }
    if (restoreCurrent && region.protection != protection) result.restoreProtectionError = memory.protect(address, false, protection);
    if (restoreMaximum && region.maximum != maximum) result.restoreMaximumError = memory.protect(address, true, maximum);
    if (result.restoreProtectionError || result.restoreMaximumError) result.status = ABIPointerSlotRestoreFailed;
    return result;
}
}
