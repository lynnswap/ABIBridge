#ifndef ABIBRIDGE_OBJECTIVE_C_HOOKS_H
#define ABIBRIDGE_OBJECTIVE_C_HOOKS_H
#include <ABIBridge/Inspection.h>
#include <objc/runtime.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABIObjCMethodHook ABIObjCMethodHook;
/// Borrowed, valid only on the callback's thread and for its duration.
/// Dereferencing an expired C context cannot be diagnosed safely.
typedef struct ABIObjCHookInvocation ABIObjCHookInvocation;
/// Explicit initializer arguments; never exposes uninitialized self or proceed.
typedef struct ABIObjCInitializerArguments ABIObjCInitializerArguments;

/// Encoding and actual caller storage layout. Strings are copied at installation.
/// Types must have supported C layouts; explicit consumed arguments, unions,
/// bitfields, packed/nontrivial values and foreign exception unwinding are excluded.
typedef struct {
    const char *encoding;
    size_t size;
    size_t alignment;
} ABIObjCHookValueType;
typedef struct {
    ABIObjCHookValueType result;
    const ABIObjCHookValueType *parameters;
    size_t parameterCount;
} ABIObjCHookSignature;

/// Zero-initialized options infer selector-family ownership.
enum { ABIObjCOwnershipAutomatic = 0, ABIObjCOwnershipBorrowed = 1, ABIObjCOwnershipTransferred = 2 };
typedef struct {
    bool classMethod;
    bool requiresMainThread;
    int32_t resultOwnership;
    int32_t receiverOwnership;
    /// Optional weak identity filter, for ordinary instance methods only.
    void *object;
    /// Optional live Objective-C owner for first-created fallback code/class.
    /// Retained independently of callbacks for the dispatcher's process lifetime.
    void *fallbackOwner;
} ABIObjCHookOptions;

enum { ABIObjCHookInvalidated = 0, ABIObjCHookActive = 1, ABIObjCHookDisplaced = 2 };
/// Must not unwind foreign exceptions. False transfers *error (if supplied)
/// to the bridge. Construct callback errors with ABICreateResolutionFailure.
typedef bool (*ABIObjCHookCallback)(void *context, ABIObjCHookInvocation *invocation, ABIResolutionFailure **error);
typedef bool (*ABIObjCInitializerBefore)(void *context, ABIObjCInitializerArguments *arguments, ABIResolutionFailure **error);
/// Initialized is borrowed for this callback; nil is a legitimate native result.
typedef bool (*ABIObjCInitializerAfter)(void *context, void *initialized, ABIResolutionFailure **error);
/// Failure is borrowed for this synchronous notification. Must not throw.
typedef void (*ABIObjCHookFailureHandler)(void *context, const ABIResolutionFailure *failure);
/// Called exactly once after registration failure or the last active snapshot.
/// Must not throw. May reenter hook APIs; no registry lock is held.
typedef void (*ABIObjCHookContextRelease)(void *context);

/// Installs on a concrete class/selector. Class and any supplied objects must
/// be live runtime values. Coordinates only managed writers: external writers
/// must synchronize installation. Later registrations wrap earlier ones.
///
/// A nonnull releaseContext transfers context ownership on entry, including
/// installation failure. A null releaseContext is rejected without taking it.
/// onFailure and callback are required. Errors are owned; success clears *error.
/// Each published class/selector entry and its fallback are process-lived.
ABIObjCMethodHook *ABIInstallObjCMethodHook(
    Class type, const char *selector, const ABIObjCHookSignature *signature,
    ABIObjCHookOptions options, void *context, ABIObjCHookCallback callback,
    ABIObjCHookFailureHandler onFailure, ABIObjCHookContextRelease releaseContext,
    ABIResolutionFailure **error);
/// Automatically initializes once, preserving consumed self and the native +1
/// result. Optional before/after callbacks never receive a continuation. Class
/// methods and object filters are unsupported. Other ownership rules match above.
ABIObjCMethodHook *ABIInstallObjCInitializerHook(
    Class type, const char *selector, const ABIObjCHookSignature *signature,
    ABIObjCHookOptions options, void *context, ABIObjCInitializerBefore before,
    ABIObjCInitializerAfter after, ABIObjCHookFailureHandler onFailure,
    ABIObjCHookContextRelease releaseContext, ABIResolutionFailure **error);
/// Acquires another reference to a live handle. Null returns null.
ABIObjCMethodHook *ABIRetainObjCMethodHook(ABIObjCMethodHook *hook);
/// Logical nonblocking removal. Does not overwrite external implementations.
/// Null is accepted. Current snapshots finish; future snapshots skip the hook.
void ABIInvalidateObjCMethodHook(ABIObjCMethodHook *hook);
/// The last reference invalidates the registration. Null is accepted.
void ABIReleaseObjCMethodHook(ABIObjCMethodHook *hook);
/// Readable after displacement/invalidation. Null has no active registration.
int32_t ABIObjCMethodHookStatus(const ABIObjCMethodHook *hook);

/// Receiver is borrowed. This operation exists only for ordinary callbacks.
void *ABIObjCHookReceiver(ABIObjCHookInvocation *invocation, ABIResolutionFailure **error);
/// Copies one value into caller storage of exactly the declared size. Object
/// pointers remain borrowed for the callback; blocks require copy if escaping.
bool ABIObjCHookReadArgument(ABIObjCHookInvocation *invocation, size_t index,
    void *value, size_t size, ABIResolutionFailure **error);
/// Calls the next member of this snapshot, not selector dispatch. Null arguments
/// and count zero reuse incoming arguments. Otherwise supply the full explicit
/// argument list with aligned storage of each declared type.
bool ABIObjCHookProceed(ABIObjCHookInvocation *invocation,
    const void *const *arguments, size_t count, ABIResolutionFailure **error);
/// Copies the most recent downstream result. Object/block references remain
/// valid until this callback ends, including across further proceed calls.
bool ABIObjCHookReadResult(ABIObjCHookInvocation *invocation,
    void *value, size_t size, ABIResolutionFailure **error);
/// Sets a candidate result, retained/copied until callback completion. Committed
/// only if the callback succeeds. Void accepts null/zero. Failure discards it,
/// preserving a completed downstream result or continuing original arguments.
bool ABIObjCHookSetResult(ABIObjCHookInvocation *invocation,
    const void *value, size_t size, ABIResolutionFailure **error);

bool ABIObjCInitializerReadArgument(ABIObjCInitializerArguments *arguments, size_t index,
    void *value, size_t size, ABIResolutionFailure **error);
/// Replaces one explicit argument; object/block values are retained/copied for
/// continuation. A failing before callback discards all replacements.
bool ABIObjCInitializerSetArgument(ABIObjCInitializerArguments *arguments, size_t index,
    const void *value, size_t size, ABIResolutionFailure **error);

/// One declaration in a coordinated installation. Each request owns one context
/// reference; callbacks and signatures have the single-installation contracts.
typedef struct {
    Class type;
    const char *selector;
    const ABIObjCHookSignature *signature;
    ABIObjCHookOptions options;
    bool initializer;
    void *context;
    ABIObjCHookCallback callback;
    ABIObjCInitializerBefore before;
    ABIObjCInitializerAfter after;
    ABIObjCHookFailureHandler onFailure;
    ABIObjCHookContextRelease releaseContext;
} ABIObjCHookRequest;
typedef struct ABIObjCHookInstallation ABIObjCHookInstallation;
enum { ABIObjCHookPreparation = 1, ABIObjCHookActivation = 2 };
/// Validates every request before publishing, then revalidates/installs in order.
/// On activation failure, invalidates only this operation's earlier registrations.
/// Visibility is not atomic across methods. Published entries can remain.
///
/// A null table with nonzero count, or any null releaseContext, takes no contexts.
/// Otherwise all context references transfer on entry, including later failures.
/// The result owns successful/invalidated partial handles and any failure.
ABIObjCHookInstallation *ABIInstallObjCHooks(const ABIObjCHookRequest *requests, size_t count);
/// Logical group invalidation; shared aliases remain valid but inactive.
void ABIInvalidateObjCHookInstallation(ABIObjCHookInstallation *installation);
/// Releases the result's references. Independently retained handles remain owned.
void ABIReleaseObjCHookInstallation(ABIObjCHookInstallation *installation);
size_t ABIObjCHookInstallationCount(const ABIObjCHookInstallation *installation);
/// Borrows a handle; index must be less than Count, including on partial failure.
ABIObjCMethodHook *ABIObjCHookInstallationGet(const ABIObjCHookInstallation *installation, size_t index);
/// Borrowed failure, or null on success. Readable regardless of method ownership.
const ABIResolutionFailure *ABIObjCHookInstallationFailure(const ABIObjCHookInstallation *installation);
/// SIZE_MAX on success; otherwise the zero-based failing request index.
size_t ABIObjCHookInstallationFailedIndex(const ABIObjCHookInstallation *installation);
/// Zero on success; otherwise preparation or activation.
int32_t ABIObjCHookInstallationPhase(const ABIObjCHookInstallation *installation);

#ifdef __cplusplus
}
#endif
#endif
