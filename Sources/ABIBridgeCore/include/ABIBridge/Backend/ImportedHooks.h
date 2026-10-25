#pragma once
#include <ABIBridge/ImportedHooks.h>
#include <ABIBridge/Backend/NativeDispatch.h>

#ifdef __cplusplus
extern "C" {
#endif

// Internal lookup/installation bridge shared by all caller frontends.
typedef struct ABIImportSelection ABIImportSelection;
typedef struct {
    uintptr_t slot;
    uint64_t generation;
    int32_t key;
    uintptr_t discriminator;
    bool addressDiversity;
} ABIImportSlot;
ABIImportSelection *ABICopyImportSelection(ABISymbolRuntime *, const ABIDeclaration *, ABIImageSelector,
    const ABIImageSelector *, ABIResolutionFailure **);
void ABIRetainImportSelection(ABIImportSelection *);
void ABIReleaseImportSelection(ABIImportSelection *);
size_t ABIImportSelectionCount(const ABIImportSelection *);
ABIImportSlot ABIImportSelectionGet(const ABIImportSelection *, size_t);
ABIImportedHook *ABICreateImportedHook(ABIImportSelection *, const ABIValueType *, const ABIValueType *const *, size_t,
    void *, ABIImportedCallback, ABIImportedFailureHandler, ABIImportedContextRelease);
ABIImportedHook *ABICreateFailedImportedHook(ABIResolutionFailure *ownedFailure);
#ifdef __cplusplus
}
#endif
