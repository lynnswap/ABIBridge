#ifndef ABIBRIDGE_MANAGED_VIRTUAL_ENTRY_H
#define ABIBRIDGE_MANAGED_VIRTUAL_ENTRY_H
#include <ABIBridge/ImportedHooks.h>
#ifdef __cplusplus
extern "C" {
#endif

// Internal bounded-entry delivery. Public operation-specific frontends are
// separate; the imported-function owner/invocation types are the C-ABI transport.
typedef struct {
    const void *addressPoint;
    size_t entryCount;
    size_t index;
    int32_t key;
    uintptr_t discriminator;
    bool addressDiversity;
} ABIManagedVirtualEntry;

/// Operates on one absolute pointer-sized entry, affecting every caller using
/// that shared table. The signature includes the incoming subobject pointer as
/// parameter zero. Proceed passes that pointer unchanged to the captured thunk.
///
/// A nonnull releaseContext takes callback context on entry, including failure;
/// a null releaseContext takes neither context and returns null. If nonnull,
/// releaseStorage transfers storageContext too. A borrowed storage owner must
/// independently keep its memory/code alive. Table-image and predecessor-image
/// leases are captured separately and published entries remain process-lived.
/// Explicit caller keepalives also remain with existing entries they join;
/// repeated registrations can therefore retain additional storage/code owners.
ABIImportedHook *ABICreateManagedVirtualHook(ABIManagedVirtualEntry entry,
    void *storageContext, ABIImportedContextRelease releaseStorage,
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    void *context, ABIImportedCallback callback, ABIImportedFailureHandler onFailure,
    ABIImportedContextRelease releaseContext);
#ifdef __cplusplus
}
#endif
#endif
