#ifndef ABIBRIDGE_INVOCATION_H
#define ABIBRIDGE_INVOCATION_H

#include <ABIBridge/Runtime.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABICallInterface ABICallInterface;

/// Scalar C representations. Signedness affects extension of narrow results.
enum {
    ABIValueVoid = 0, ABIValueUInt8, ABIValueInt8, ABIValueUInt16, ABIValueInt16,
    ABIValueUInt32, ABIValueInt32, ABIValueUInt64, ABIValueInt64,
    ABIValueFloat, ABIValueDouble, ABIValuePointer
};

/// Creates an owned scalar type, or returns null with an owned failure.
ABIValueType *ABICreateScalarType(int32_t kind, ABIResolutionFailure **error);
/// Creates a naturally laid-out C aggregate, retaining its field descriptions.
/// Packed layouts, unions, bitfields, and non-trivial value ownership require
/// separate adapters. Fields may be released after this function returns.
ABIValueType *ABICreateStructType(
    const ABIValueType *const *fields, size_t count, ABIResolutionFailure **error);
void ABIReleaseValueType(ABIValueType *type);
/// Actual value size; void has size zero.
size_t ABIValueTypeSize(const ABIValueType *type);
size_t ABIValueTypeAlignment(const ABIValueType *type);
size_t ABIValueTypeFieldCount(const ABIValueType *type);
/// Index must be less than ABIValueTypeFieldCount(type).
size_t ABIValueTypeFieldOffset(const ABIValueType *type, size_t index);

/// Prepares the platform C ABI and retains all type descriptions. The interface
/// may be reused concurrently after creation. Void is permitted only as a
/// result. Parameters may be null when count is zero.
ABICallInterface *ABICreateCCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, ABIResolutionFailure **error);
void ABIReleaseCallInterface(ABICallInterface *interface);

/// Signs an unsigned executable address as a generic C function pointer when
/// required by the target. Does not validate storage, signature, or lifetime.
ABIUnmanagedFunction ABIUnsafeFunctionAtAddress(const void *address);

/// Invokes a function using a prepared C ABI. The caller must keep the code,
/// argument values, and referenced objects alive, and satisfy the actual native
/// signature and ownership contract. Foreign exceptions must not cross this
/// boundary. This is not a Swift calling-convention entry point.
///
/// Each argument points to aligned storage of the corresponding value, not
/// directly to a pointee for pointer arguments. The array must contain the
/// interface's parameter count. Result storage needs only the actual value's
/// size/alignment; word-sized libffi returns are handled internally. Void allows
/// null result storage. False reports an invalid invocation request.
bool ABIUnsafeInvokeCCallInterface(
    ABICallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, ABIResolutionFailure **error);

#ifdef __cplusplus
}
#endif
#endif
