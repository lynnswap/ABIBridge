#ifndef ABIBRIDGE_VIRTUAL_HOOKS_H
#define ABIBRIDGE_VIRTUAL_HOOKS_H
#include <ABIBridge/VirtualEntries.h>
#include <ABIBridge/HookEffects.h>
#include <ABIBridge/ValueTypes.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABIVirtualHook ABIVirtualHook;
typedef struct ABIVirtualInvocation ABIVirtualInvocation;
typedef bool (*ABIVirtualCallback)(void *, ABIVirtualInvocation *, ABIResolutionFailure **);
typedef void (*ABIVirtualFailureHandler)(void *, const ABIResolutionFailure *);
typedef void (*ABIVirtualContextRelease)(void *);
typedef int32_t ABIVirtualHookState;
enum { ABIVirtualInactive = 0, ABIVirtualActive = 1, ABIVirtualDisplaced = 2, ABIVirtualUnreadable = 3 };

/// Intercepts one absolute entry shared by all objects dispatching through this table. Parameters describe explicit C-compatible arguments, excluding this. The incoming subobject and captured adjustment thunk are preserved by proceed. The caller establishes the signature, table format, bounds and schema. Native exceptions, nontrivial C++ values and construction/destruction dispatch need compiled adapters; direct/devirtualized calls bypass the table.
///
/// Callback, onFailure and releaseContext are required. A nonnull releaseContext transfers context on entry, including failure. If releaseStorage is nonnull, storageContext transfers too. A null releaseContext returns null without taking either context. Other outcomes return an owned hook; inspect failure and partial mutation results before releasing it. Protected pages may reject installation.
///
/// Published entries, image leases, and explicit storage owners have process lifetime, including pass-through entries after invalidation. Callback captures are released after their final active snapshot. Callback code and native resources must survive their final invocation and release. Coordinate external writers; retain unowned tables and generated code independently.
ABIVirtualHook *ABIInstallSharedVirtualHook(ABIVirtualEntryInfo entry,
    void *storageContext, ABIVirtualContextRelease releaseStorage,
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    void *context, ABIVirtualCallback callback, ABIVirtualFailureHandler onFailure,
    ABIVirtualContextRelease releaseContext);
ABIVirtualHook *ABIRetainVirtualHook(ABIVirtualHook *hook);
/// Idempotently removes this callback from future snapshots, without waiting, restoring the pointer, or overwriting an external writer's replacement.
void ABIInvalidateVirtualHook(ABIVirtualHook *hook);
/// Last-owner release invalidates the registration. Null is accepted.
void ABIReleaseVirtualHook(ABIVirtualHook *hook);
/// Borrowed install failure; null means installation completed.
const ABIResolutionFailure *ABIVirtualHookGetFailure(const ABIVirtualHook *hook);
/// False when preparation failed before a slot was selected.
bool ABIVirtualHookHasEntry(const ABIVirtualHook *hook);
/// Require HasEntry; copied address, current state and immutable effect records.
uintptr_t ABIVirtualHookGetSlot(const ABIVirtualHook *hook);
ABIVirtualHookState ABIVirtualHookGetStatus(const ABIVirtualHook *hook);
ABIPointerSlotResult ABIVirtualHookGetMutation(const ABIVirtualHook *hook);
ABIPointerSlotResult ABIVirtualHookGetRollback(const ABIVirtualHook *hook);

/// Invocation pointers and receiver/pointees are borrowed only on the incoming callback's thread. Never use them after callback return. A failed callback passes through with original arguments, or keeps its latest proceed result.
void *ABIVirtualInvocationGetReceiver(ABIVirtualInvocation *, ABIResolutionFailure **);
/// Reads an explicit argument (index zero excludes this).
bool ABIVirtualInvocationReadArgument(ABIVirtualInvocation *, size_t index, void *bytes, size_t size, ABIResolutionFailure **);
/// Calls the next callback/predecessor with every explicit argument, preserving the incoming subobject pointer. NULL/zero is valid only for a zero-argument signature.
bool ABIVirtualInvocationProceed(ABIVirtualInvocation *, const void *const *arguments, size_t count, ABIResolutionFailure **);
/// Calls the next implementation with the unchanged incoming arguments.
bool ABIVirtualInvocationProceedWithOriginalArguments(ABIVirtualInvocation *, ABIResolutionFailure **);
/// Reads the most recent downstream result. Pointer values remain borrowed for the callback.
bool ABIVirtualInvocationReadResult(ABIVirtualInvocation *, void *bytes, size_t size, ABIResolutionFailure **);
bool ABIVirtualInvocationSetResult(ABIVirtualInvocation *, const void *bytes, size_t size, ABIResolutionFailure **);
#ifdef __cplusplus
}
#endif
#endif
