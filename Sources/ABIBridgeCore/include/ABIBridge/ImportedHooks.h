#ifndef ABIBRIDGE_IMPORTED_HOOKS_H
#define ABIBRIDGE_IMPORTED_HOOKS_H
#include <ABIBridge/PointerSlot.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct ABIImportedHook ABIImportedHook;
typedef struct ABIImportedInvocation ABIImportedInvocation;
typedef bool (*ABIImportedCallback)(void *, ABIImportedInvocation *, ABIResolutionFailure **);
typedef void (*ABIImportedFailureHandler)(void *, const ABIResolutionFailure *);
typedef void (*ABIImportedContextRelease)(void *);
enum { ABIImportedInactive = 0, ABIImportedActive = 1, ABIImportedDisplaced = 2, ABIImportedUnreadable = 3 };

/// Installs on matching references in currently loaded importing images. The
/// provider, if nonnull, filters the dependency name recorded in each binding;
/// it is not a search for the current target address. Neither scope loads images.
/// Only C/C++ function declarations and fixed C ABI value types are supported.
/// Function-pointer pointees/results are borrowed. Native exceptions must not
/// cross the callback boundary. Callback and failure handler are required.
///
/// A nonnull releaseContext transfers context on entry, including failure. The
/// returned owner carries installation errors and per-slot effects. Release it
/// after inspecting failure. A null releaseContext returns null without taking
/// context. Other results are nonnull unless allocation terminates execution.
///
/// Published entries/code/image leases remain process-lived, independently of
/// callback captures. Keep generated predecessor code alive and coordinate with
/// external writers/loader activity. Calls copied before installation bypass it.
ABIImportedHook *ABIInstallImportedFunctionHook(ABISymbolRuntime *runtime,
    const ABIDeclaration *declaration, ABIImageSelector importer, const ABIImageSelector *provider,
    const ABIValueType *result, const ABIValueType *const *parameters, size_t parameterCount,
    void *context, ABIImportedCallback callback, ABIImportedFailureHandler onFailure, ABIImportedContextRelease releaseContext);

ABIImportedHook *ABIRetainImportedHook(ABIImportedHook *hook);
/// Removes only this registration from future call snapshots, without waiting
/// or restoring slots. Callback captures survive only as long as active calls.
void ABIInvalidateImportedHook(ABIImportedHook *hook);
void ABIReleaseImportedHook(ABIImportedHook *hook);
/// Borrowed failure; null means installation completed, SIZE_MAX is no failed slot.
const ABIResolutionFailure *ABIImportedHookFailure(const ABIImportedHook *hook);
size_t ABIImportedHookFailedIndex(const ABIImportedHook *hook);
size_t ABIImportedHookCount(const ABIImportedHook *hook);
uintptr_t ABIImportedHookSlot(const ABIImportedHook *hook, size_t index);
int32_t ABIImportedHookStatus(const ABIImportedHook *hook, size_t index);
/// Immutable installation and rollback outcomes, including incomplete cleanup.
ABIPointerSlotResult ABIImportedHookMutation(const ABIImportedHook *hook, size_t index);
ABIPointerSlotResult ABIImportedHookRollback(const ABIImportedHook *hook, size_t index);

/// Invocation pointers are borrowed on the callback's thread only. C callers
/// must not access an expired pointer. Failed callbacks pass through with the
/// original arguments, or preserve the latest completed proceed result.
bool ABIImportedReadArgument(ABIImportedInvocation *, size_t index, void *bytes, size_t size, ABIResolutionFailure **);
bool ABIImportedProceed(ABIImportedInvocation *, void *const *arguments, size_t count, ABIResolutionFailure **);
bool ABIImportedCopyResult(ABIImportedInvocation *, void *bytes, size_t size, ABIResolutionFailure **);
bool ABIImportedSetResult(ABIImportedInvocation *, const void *bytes, size_t size, ABIResolutionFailure **);

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
#endif
