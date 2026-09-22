#ifndef ABIBRIDGE_SWIFT_INVOCATION_H
#define ABIBRIDGE_SWIFT_INVOCATION_H

#include <ABIBridge/Invocation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABISwiftCallInterface ABISwiftCallInterface;

/// Prepares a concrete synchronous, nonthrowing Swift call from fixed value
/// layouts. These are storage descriptions, not a C calling convention.
/// Parameters must use ordinary guaranteed ownership; consumed/inout values,
/// resilient layouts and hidden generic arguments require a native adapter.
ABISwiftCallInterface *ABICreateSwiftCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, ABIResolutionFailure **error);
void ABIReleaseSwiftCallInterface(ABISwiftCallInterface *interface);

/// Calls a thin Swift implementation using prepared register/stack lowering.
/// The caller retains code and all guaranteed arguments and supplies writable,
/// uninitialized result storage. A successful nontrivial result is owned by
/// the caller. No Swift errors, native exceptions or async suspension may cross
/// this boundary. context is the Swift self register, or null for a free function.
bool ABIUnsafeInvokeSwiftCallInterface(
    ABISwiftCallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, const void *context,
    ABIResolutionFailure **error);

#ifdef __cplusplus
}
#endif
#endif
