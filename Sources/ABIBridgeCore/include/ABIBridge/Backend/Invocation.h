#ifndef ABIBRIDGE_INVOCATION_H
#define ABIBRIDGE_INVOCATION_H

#include <ABIBridge/Backend/Runtime.h>
#include <ABIBridge/ValueTypes.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABICallInterface ABICallInterface;
typedef struct ABICallClosure ABICallClosure;

/// Prepares the platform C ABI and retains all type descriptions. The interface may be reused concurrently after creation. Void is permitted only as a result. Parameters may be null when count is zero.
ABICallInterface *ABICreateCCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, ABIResolutionFailure **error);
/// Prepares one concrete variadic call. The nonempty fixed prefix ends at fixedCount. Anonymous Float and narrow integers undergo C promotions; invocation storage still uses the supplied input representations.
ABICallInterface *ABICreateVariadicCCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, size_t fixedCount, ABIResolutionFailure **error);
void ABIReleaseCallInterface(ABICallInterface *interface);
void ABIRetainCallInterface(ABICallInterface *interface);
size_t ABICallInterfaceParameterCount(const ABICallInterface *interface);

/// Internal callback transport. Context and argument storage remain borrowed; the callback writes the interface's result representation. This does not manage Objective-C ownership or allow exceptions to cross the C boundary. Variadic entries require every caller to use the prepared tail. Anonymous callback arguments use their promoted C representations.
typedef void (*ABICallClosureHandler)(void *context, void *result, void *const *arguments);
/// Retains the prepared interface. A failed creation publishes no callable code.
ABICallClosure *ABICreateCallClosure(ABICallInterface *interface,
    ABICallClosureHandler handler, void *context, ABIResolutionFailure **error);
/// Returns a signed generic function pointer. Its lifetime is the closure's.
ABIUnmanagedFunction ABICallClosureFunction(const ABICallClosure *closure);
/// Requires that no caller can enter or still be executing this closure.
void ABIReleaseCallClosure(ABICallClosure *closure);

/// Signs an unsigned executable address as a generic C function pointer when required by the target. Does not validate storage, signature, or lifetime.
ABIUnmanagedFunction ABIUnsafeFunctionAtAddress(const void *address);

/// Invokes a function using a prepared C ABI. The caller must keep the code, argument values, and referenced objects alive, and satisfy the actual native signature and ownership contract. Foreign exceptions must not cross this boundary. This is not a Swift calling-convention entry point.
///
/// Each argument points to aligned storage of the corresponding value, not directly to a pointee for pointer arguments. The array must contain the interface's parameter count. Result storage needs only the actual value's size/alignment; word-sized libffi returns are handled internally. Void allows null result storage. False reports an invalid invocation request.
bool ABIUnsafeInvokeCCallInterface(
    ABICallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, ABIResolutionFailure **error);

#ifdef __cplusplus
}
#endif
#endif
