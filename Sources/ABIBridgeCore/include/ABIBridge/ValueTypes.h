#ifndef ABIBRIDGE_VALUE_TYPES_H
#define ABIBRIDGE_VALUE_TYPES_H

#include <ABIBridge/Inspection.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// An owned description of a supported C value representation.
typedef struct ABIValueType ABIValueType;

/// Scalar C representations. Signedness affects extension of narrow results.
typedef int32_t ABIValueKind;
enum {
    ABIValueVoid = 0, ABIValueUInt8, ABIValueInt8, ABIValueUInt16, ABIValueInt16,
    ABIValueUInt32, ABIValueInt32, ABIValueUInt64, ABIValueInt64,
    ABIValueFloat, ABIValueDouble, ABIValuePointer
};

/// Creates an owned scalar type, or returns null with an owned failure.
ABIValueType *ABICreateScalarType(ABIValueKind kind, ABIResolutionFailure **error);
/// Creates a naturally laid-out C aggregate, retaining its field descriptions. Packed layouts, unions, bitfields, and non-trivial value ownership require separate adapters. Fields may be released after this function returns.
ABIValueType *ABICreateStructType(
    const ABIValueType *const *fields, size_t count, ABIResolutionFailure **error);
void ABIReleaseValueType(ABIValueType *type);
/// Actual value size; void has size zero.
size_t ABIValueTypeGetSize(const ABIValueType *type);
size_t ABIValueTypeGetAlignment(const ABIValueType *type);
/// Whether the representation is a scalar native pointer.
bool ABIValueTypeIsPointer(const ABIValueType *type);
/// Compares scalar kinds and recursively finalized storage layouts.
bool ABIValueTypesEqual(const ABIValueType *first, const ABIValueType *second);
size_t ABIValueTypeGetFieldCount(const ABIValueType *type);
/// Index must be less than ABIValueTypeGetFieldCount(type).
size_t ABIValueTypeGetFieldOffset(const ABIValueType *type, size_t index);

#ifdef __cplusplus
}
#endif
#endif
