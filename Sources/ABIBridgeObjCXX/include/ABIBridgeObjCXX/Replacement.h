#pragma once

#include <ABIBridgeObjCXX/Invocation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Internal replacement boundary, not a public installation API.
typedef struct ABIObjCReplacement ABIObjCReplacement;
/// Borrowed stack frame, valid only inside its callback.
typedef struct ABIObjCReplacementCall ABIObjCReplacementCall;
typedef void (*ABIObjCReplacementHandler)(void *context, ABIObjCReplacementCall *call);
typedef void (*ABIObjCReplacementDestroy)(void *context);

/// Retains binding/interface. Takes context ownership only on success. The
/// prepared interface must exactly describe the binding, including self/_cmd.
/// Fallback owner keeps generated original code/classes valid independently of
/// callback invalidation. Without one, their lifetime remains the caller's duty.
ABIObjCReplacement * _Nullable ABICreateObjCReplacement(
    ABIObjCInvocation *binding, ABICallInterface *interface,
    ABIObjCReplacementHandler handler, void *context, ABIObjCReplacementDestroy destroy,
    id _Nullable fallbackOwner,
    NSError * _Nullable * _Nullable error);
/// Publishing makes entry code and fallback owners process-lived. Releasing
/// the owner disables its callback, but cached IMPs remain valid pass-throughs.
IMP ABIPublishObjCReplacement(ABIObjCReplacement *replacement);
/// Releases captures after in-flight callbacks finish; does not wait or change
/// a method table. May be called inside a callback. Idempotent.
void ABIInvalidateObjCReplacement(ABIObjCReplacement *replacement);
/// Destroys unpublished entries; published entries keep callable fallback code.
void ABIReleaseObjCReplacement(ABIObjCReplacement *replacement);

/// A consuming receiver is never exposed to the Swift callback as an object.
void * _Nullable ABIObjCReplacementReceiver(const ABIObjCReplacementCall *call);
const void *ABIObjCReplacementArgument(const ABIObjCReplacementCall *call, size_t index);
/// Uses the incoming self/_cmd; never adds a retain of consumed self. Null
/// arguments uses the original argument storage. Initializers may proceed once.
BOOL ABIObjCReplacementProceed(ABIObjCReplacementCall *call,
    const void * _Nonnull const * _Nullable arguments, NSError * _Nullable * _Nullable error);
/// Copies the last native result. Retainable values are transferred at +1.
BOOL ABICopyObjCReplacementResult(ABIObjCReplacementCall *call, void *result,
    NSError * _Nullable * _Nullable error);
/// Stores a typed callback result, retaining objects/blocks. Not for init: its
/// incoming receiver must be consumed by the native initializer exactly once.
BOOL ABISetObjCReplacementResult(ABIObjCReplacementCall *call, const void *result,
    NSError * _Nullable * _Nullable error);

/// Internal managed Objective-C method hooks. Context ownership transfers on entry,
/// including failure. Signature/ownership validation precedes method mutation.
typedef struct ABIObjCMethodHook ABIObjCMethodHook;
FOUNDATION_EXPORT NSString * const ABIObjCMethodHookErrorDomain;
/// Checks operation/ownership compatibility without publishing an entry.
BOOL ABIValidateObjCMethodHook(Class type, SEL selector, BOOL classMethod, BOOL initializer,
    ABIObjCInvocation *binding, id _Nullable object, NSError * _Nullable * _Nullable error);
ABIObjCMethodHook * _Nullable ABICreateObjCMethodHook(
    Class type, SEL selector, BOOL classMethod, BOOL initializer,
    ABIObjCInvocation *binding, ABICallInterface *interface,
    ABIObjCReplacementHandler handler, void *context, ABIObjCReplacementDestroy destroy,
    id _Nullable object, id _Nullable fallbackOwner,
    NSError * _Nullable * _Nullable error);
/// Reports displacement even when a subsequent method lookup cannot capture
/// the external implementation (for example, a forwarding trampoline).
BOOL ABIObjCMethodHookIsDisplaced(Class type, SEL selector, BOOL classMethod);
void ABIInvalidateObjCMethodHook(ABIObjCMethodHook *hook);
void ABIReleaseObjCMethodHook(ABIObjCMethodHook *hook);
/// 0 = invalidated, 1 = active, 2 = displaced by another runtime writer.
int32_t ABIObjCMethodHookStatus(const ABIObjCMethodHook *hook);

#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
