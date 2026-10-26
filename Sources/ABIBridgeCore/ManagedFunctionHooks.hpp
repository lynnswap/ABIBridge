#include <ABIBridge/Backend/ImportedHooks.h>
#pragma once
#include <ABIBridge/ImportedHooks.h>
#include <memory>
#include <vector>

namespace abibridge {
// Internal C-ABI transport. Caller frontends keep their own scope and receiver
// contracts while registrations on the same physical slot share one chain.
struct ManagedFunctionSlot {
    ABIImportSlot description;
    std::shared_ptr<void> owner;
    // Explicit caller keepalives must also survive when joining an existing
    // entry whose first registration may have borrowed its storage/code.
    bool retainOwnerOnOverlap = false;
};
// User cleanup must still enter hooks when its owner retires during internal
// allocation or chain bookkeeping.
void releaseManagedFunctionContext(void *, ABIImportedContextRelease);
struct TransferredContext {
    void *value;
    ABIImportedContextRelease release;
    TransferredContext(void *value, ABIImportedContextRelease release): value(value), release(release) {}
    TransferredContext(const TransferredContext&) = delete;
    TransferredContext& operator=(const TransferredContext&) = delete;
    ~TransferredContext() { if (release) releaseManagedFunctionContext(value,release); }
    void relinquish() { release = nullptr; }
};
ABIImportedHook *createManagedFunctionHook(std::vector<ManagedFunctionSlot> slots,
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    void *context, ABIImportedCallback callback, ABIImportedFailureHandler failure,
    ABIImportedContextRelease release);
// Prepared fixed arguments and libffi-sized result storage are supplied by the
// imported dispatcher. Forward without allocations or a result-copy import
// that could itself be hooked in the dispatcher's image.
void invokeManagedFunctionPredecessor(ABICallInterface *, ABIUnmanagedFunction,
    void *result, void *const *arguments);
}
