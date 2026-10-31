#ifndef ABIBRIDGE_SWIFT_PROTOCOL_CONFORMANCE_H
#define ABIBRIDGE_SWIFT_PROTOCOL_CONFORMANCE_H

#include <ABIBridge/Backend/SwiftCallbacks.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABISwiftProtocolConformance ABISwiftProtocolConformance;

/// Creates and registers a unique Objective-C proxy class. The class and its
/// Swift metadata have process lifetime, including when later preparation fails.
const void *ABICreateSwiftProtocolClass(ABIResolutionFailure **error);
/// Returns the Swift metadata for this Objective-C class, suitable for binding
/// the formal Self type before publishing its protocol conformance.
const void *ABISwiftProtocolClassMetadata(const void *type);

/// Builds and registers a prepared class's native Swift conformance. The
/// descriptor, witness table and returned handle have process lifetime.
/// Witness code and its dependencies must have the same lifetime. Failure
/// registers nothing and retains no caller-owned resources. Runtime preparation
/// supplies one complete witness and its validated discriminator per requirement.
ABISwiftProtocolConformance *ABICreateSwiftProtocolConformance(
    const void *type, const void *protocolDescriptor, const ABIUnmanagedFunction *witnesses,
    const uint16_t *discriminators, size_t count, ABIResolutionFailure **error);

const void *ABISwiftProtocolConformanceWitnessTable(const ABISwiftProtocolConformance *conformance);

/// Creates a +1 native object. Success transfers context's release obligation
/// to the object; failure leaves it with the caller. invoke runs synchronously
/// on the caller's thread. It returns true after initializing an owned error,
/// false after initializing the result; errorResult is null for nonthrowing calls.
void *ABICreateSwiftProtocolInstance(const ABISwiftProtocolConformance *conformance,
    void *context,
    bool (*invoke)(void *context, size_t slot, void *const *arguments, void *result, void *errorResult),
    void (*releaseContext)(void *), ABIResolutionFailure **error);
/// Dispatches from a witness trampoline. A consuming requirement transfers one
/// owned Self reference, which is released after the invocation on both outcomes.
bool ABIInvokeSwiftProtocolInstance(const void *object, size_t slot, bool consumesReceiver,
    void *const *arguments, void *result, void *errorResult);

/// Prepares a synchronous Void witness entry for a validated requirement slot.
/// Owns only its native interface, slot and receiver convention; the native instance owns callbacks.
/// Its code is a witness entry, not a standalone Swift closure entry.
ABISwiftClosureCallback *ABICreateSwiftProtocolWitnessCallback(
    ABISwiftCallInterface *interface, size_t slot, bool consumesReceiver, ABIResolutionFailure **error);

#ifdef __cplusplus
}
#endif
#endif
