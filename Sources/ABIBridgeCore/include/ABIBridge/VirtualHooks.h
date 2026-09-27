#ifndef ABIBRIDGE_VIRTUAL_HOOKS_H
#define ABIBRIDGE_VIRTUAL_HOOKS_H
#include <ABIBridge/VirtualEntries.h>
#include <ABIBridge/PointerSlot.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABIVirtualHook ABIVirtualHook;
typedef struct ABIVirtualInvocation ABIVirtualInvocation;
typedef bool (*ABIVirtualCallback)(void *, ABIVirtualInvocation *, ABIResolutionFailure **);
typedef void (*ABIVirtualFailureHandler)(void *, const ABIResolutionFailure *);
typedef void (*ABIVirtualContextRelease)(void *);
enum { ABIVirtualInactive = 0, ABIVirtualActive = 1, ABIVirtualDisplaced = 2, ABIVirtualUnreadable = 3 };

/// Intercepts one absolute entry shared by all objects dispatching through this
/// table. Parameters describe explicit C-compatible arguments, excluding this.
/// The incoming subobject and captured adjustment thunk are preserved by proceed.
/// The caller establishes the signature, table format, bounds and schema. Native
/// exceptions, nontrivial C++ values and construction/destruction dispatch need
/// compiled adapters; direct/devirtualized calls bypass the table.
///
/// Callback, onFailure and releaseContext are required. A nonnull releaseContext
/// transfers context on entry, including failure. If releaseStorage is nonnull,
/// storageContext transfers too. A null releaseContext returns null taking neither.
/// Other outcomes return an owned hook; inspect failure and partial mutation
/// results before releasing it. Protected pages may reject installation.
///
/// Published callable entries, image leases and explicit storage keepalives are
/// process-lived, including pass-through entries after invalidation. Callback
/// captures release when their final active snapshot ends. Callback code and
/// captured native resources must outlive their final invocation and release.
/// Coordinate external
/// writers and keep unowned table/generated code alive independently.
ABIVirtualHook *ABIInstallSharedVirtualHook(ABIVirtualEntryInfo entry,
    void *storageContext, ABIVirtualContextRelease releaseStorage,
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    void *context, ABIVirtualCallback callback, ABIVirtualFailureHandler onFailure,
    ABIVirtualContextRelease releaseContext);
ABIVirtualHook *ABIRetainVirtualHook(ABIVirtualHook *hook);
/// Idempotently removes this callback from future snapshots, without waiting,
/// restoring the pointer, or overwriting an external writer's replacement.
void ABIInvalidateVirtualHook(ABIVirtualHook *hook);
/// Last-owner release invalidates the registration. Null is accepted.
void ABIReleaseVirtualHook(ABIVirtualHook *hook);
/// Borrowed install failure; null means installation completed.
const ABIResolutionFailure *ABIVirtualHookFailure(const ABIVirtualHook *hook);
/// False when preparation failed before a slot was selected.
bool ABIVirtualHookHasEntry(const ABIVirtualHook *hook);
/// Require HasEntry; copied address, current state and immutable effect records.
uintptr_t ABIVirtualHookSlot(const ABIVirtualHook *hook);
int32_t ABIVirtualHookStatus(const ABIVirtualHook *hook);
ABIPointerSlotResult ABIVirtualHookMutation(const ABIVirtualHook *hook);
ABIPointerSlotResult ABIVirtualHookRollback(const ABIVirtualHook *hook);

/// Invocation pointers and receiver/pointees are borrowed only on the incoming
/// callback's thread. Never use them after callback return. A failed callback
/// passes through with original arguments, or keeps its latest proceed result.
void *ABIVirtualInvocationReceiver(ABIVirtualInvocation *, ABIResolutionFailure **);
/// Reads an explicit argument (index zero excludes this).
bool ABIVirtualReadArgument(ABIVirtualInvocation *, size_t index, void *bytes, size_t size, ABIResolutionFailure **);
/// Calls the next callback/predecessor, preserving the incoming subobject pointer.
bool ABIVirtualProceed(ABIVirtualInvocation *, void *const *arguments, size_t count, ABIResolutionFailure **);
bool ABIVirtualCopyResult(ABIVirtualInvocation *, void *bytes, size_t size, ABIResolutionFailure **);
bool ABIVirtualSetResult(ABIVirtualInvocation *, const void *bytes, size_t size, ABIResolutionFailure **);
#ifdef __cplusplus
}
#endif
#endif
