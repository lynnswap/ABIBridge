#ifndef ABIBRIDGE_SWIFT_INVOCATION_H
#define ABIBRIDGE_SWIFT_INVOCATION_H

#include <ABIBridge/Invocation.h>
#include <ABIBridge/SwiftDemangling.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABISwiftCallInterface ABISwiftCallInterface;

/// Reads a valid compiler-emitted generic protocol-requirement reference.
/// Authenticates indirect Swift descriptor pointers before reading their flags.
bool ABISwiftProtocolRequirementIsClassBound(const void *reference);
/// Runtime metadata operations over valid compiler-emitted Swift descriptors.
/// Type construction requires an already validated metadata/witness argument list.
const void *ABISwiftProtocolRequirementDescriptor(const void *reference);
const void *ABISwiftProtocolRequirementObjectiveCProtocol(const void *reference);
const void *ABISwiftConformance(const void *metadata, const void *protocol);
/// Canonical existential metadata for one valid Swift protocol descriptor.
const void *ABISwiftProtocolTypeMetadata(const void *protocol);
const void *ABISwiftMetatypeMetadata(const void *instance);
const void *ABISwiftExistentialMetatypeMetadata(const void *instance);
/// Labels are nil or one space-terminated name per element; an empty name is unlabeled.
/// The labels buffer only needs to remain valid until this call returns.
const void *ABISwiftTupleTypeMetadata(const void *const *elements, size_t count, const char *labels);
/// Parses the subject or type constraint of a compiler-emitted requirement.
/// A protocol or layout requirement has no type constraint in its second field.
ABISwiftSyntax *ABICopySwiftGenericRequirementTypeSyntax(const void *requirement, bool constraint);
const void *ABISwiftConformanceDescriptor(const void *witnessTable);
const void *ABISwiftAssociatedType(const void *metadata, const void *protocol, const char *name);
const void *ABISwiftGenericTypeMetadata(const void *descriptor, const void *const *arguments);
/// Interns a metadata pack in the Swift runtime. The returned tagged pointer
/// remains owned by the runtime and may be used in type construction.
const void *ABISwiftMetadataPack(const void *const *elements, size_t count);
typedef struct ABISwiftTypeMetadata ABISwiftTypeMetadata;
/// Binds source-written type arguments through the runtime's generic type
/// resolver, which validates constraints and obtains existing conformances.
ABISwiftTypeMetadata *ABICreateSwiftTypeMetadata(const void *descriptor,
    const void *const *arguments, size_t count, ABIResolutionFailure **error);
/// Returns an authenticated raw nominal descriptor, or null for a non-nominal type.
const void *ABISwiftTypeDescriptor(const void *metadata);
/// Reflection fields whose storage is inline in a struct or enum. Syntax trees
/// preserve generic parameters and symbolic descriptor identities.
size_t ABISwiftTypeFieldCount(const void *metadata);
ABISwiftSyntax *ABICopySwiftTypeFieldSyntax(const void *metadata, size_t index);
ABISwiftSyntax *ABICopySwiftAssociatedTypeSyntax(const void *metadata, const void *protocol, const char *name);
/// Recovers the source-written arguments of existing complete metadata.
ABISwiftTypeMetadata *ABICopySwiftTypeMetadata(const void *metadata, ABIResolutionFailure **error);
size_t ABISwiftTypeMetadataArgumentCount(const ABISwiftTypeMetadata *result);
bool ABISwiftTypeMetadataArgumentIsPack(const ABISwiftTypeMetadata *result, size_t index);
size_t ABISwiftTypeMetadataArgumentElementCount(const ABISwiftTypeMetadata *result, size_t index);
const void *ABISwiftTypeMetadataArgumentElement(const ABISwiftTypeMetadata *result, size_t index, size_t element);
/// Reads the nominal declaration context for member binding. This additional
/// information is not required to construct or inspect nominal metadata.
bool ABIPrepareSwiftTypeMetadataContext(ABISwiftTypeMetadata *result, ABIResolutionFailure **error);
/// Type references preserve source generic depth/index for member binding.
/// Call ABIPrepareSwiftTypeMetadataContext first; returned strings borrow result.
const char *ABISwiftTypeMetadataParameterReference(const ABISwiftTypeMetadata *result, size_t index);
bool ABISwiftTypeMetadataArgumentIsKey(const ABISwiftTypeMetadata *result, size_t index);
size_t ABISwiftTypeMetadataRequirementCount(const ABISwiftTypeMetadata *result);
/// Borrows a compiler-emitted generic requirement descriptor.
const void *ABISwiftTypeMetadataRequirement(const ABISwiftTypeMetadata *result, size_t index);
const void *ABISwiftTypeMetadataValue(const ABISwiftTypeMetadata *result);
size_t ABISwiftTypeMetadataConformanceCount(const ABISwiftTypeMetadata *result);
/// index must be less than ABISwiftTypeMetadataConformanceCount(result).
const void *ABISwiftTypeMetadataConformance(const ABISwiftTypeMetadata *result, size_t index);
void ABIReleaseSwiftTypeMetadata(ABISwiftTypeMetadata *result);
const void *ABISwiftTypeForMangledName(const char *name, size_t length,
                                    const void *context, const void *const *arguments);

/// A concrete thick Swift closure. Its context is a Swift heap reference,
/// including closure capture contexts that are not ordinary class instances.
typedef struct ABISwiftClosureValue {
    const void *function;
    void *context;
} ABISwiftClosureValue;

/// Converts between the compiler's type-discriminated Swift function pointer
/// and the backend's authenticated C function pointer. The discriminator must
/// describe the concrete SIL signature, not its generic reabstraction.
ABIUnmanagedFunction ABIAuthenticateSwiftClosureFunction(const void *function, uint16_t discriminator);
const void *ABISignSwiftClosureFunction(ABIUnmanagedFunction function, uint16_t discriminator);
/// Async closures authenticate a descriptor with the data key. The descriptor
/// contains a relative entry address and the required task-context size.
const void *ABIAuthenticateSwiftAsyncClosureDescriptor(const void *descriptor, uint16_t discriminator);
const void *ABISignSwiftAsyncClosureDescriptor(const void *descriptor, uint16_t discriminator);
typedef struct ABISwiftAsyncDescriptor ABISwiftAsyncDescriptor;
ABISwiftAsyncDescriptor *ABICopySwiftAsyncDescriptor(const void *descriptor, ABIResolutionFailure **error);
ABIUnmanagedFunction ABISwiftAsyncDescriptorFunction(const ABISwiftAsyncDescriptor *descriptor);
uint32_t ABISwiftAsyncDescriptorContextSize(const ABISwiftAsyncDescriptor *descriptor);
void ABIReleaseSwiftAsyncDescriptor(ABISwiftAsyncDescriptor *descriptor);

void ABIRetainSwiftClosureContext(void *context);
void ABIReleaseSwiftClosureContext(void *context);

/// Combines ABI scalar components and offsets with compiler-known Swift storage.
/// Scalar field extents must fit size; component aggregate tail padding is
/// excluded. Alignment must be a power of two.
/// This layout is for Swift interfaces, not a libffi C calling convention.
ABIValueType *ABICreateSwiftOptionalSingletonType(void);

ABIValueType *ABICreateSwiftStorageType(
    const ABIValueType *components, size_t size, size_t alignment, ABIResolutionFailure **error);

/// Describes a formally indirect Swift value, independent of its current size.
/// There is no C representation and no scalar component description.
ABIValueType *ABICreateSwiftIndirectStorageType(
    size_t size, size_t alignment, ABIResolutionFailure **error);

/// A formal tuple expands into independent SIL parameters/results. Offsets
/// describe its concrete Swift storage, including nested tuple elements.
ABIValueType *ABICreateSwiftTupleStorageType(
    const ABIValueType *const *fields, const size_t *offsets, size_t count,
    size_t size, size_t alignment, ABIResolutionFailure **error);
/// A formal pack passes an address vector for these concrete elements.
ABIValueType *ABICreateSwiftPackStorageType(
    const ABIValueType *const *fields, const size_t *offsets, size_t count,
    size_t size, size_t alignment, ABIResolutionFailure **error);

/// Prepares a concrete synchronous, nonthrowing Swift call from fixed value
/// layouts. These are storage descriptions, not a C calling convention.
/// Parameters must use ordinary guaranteed ownership. Declared formally
/// indirect values use ABICreateSwiftIndirectStorageType; consumed/inout values
/// and hidden generic arguments require a native adapter.
ABISwiftCallInterface *ABICreateSwiftCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, ABIResolutionFailure **error);
/// Prepares synchronous throwing invocation. Untyped errors use a pointer-sized
/// owned Swift error reference; typed errors use their declared value layout.
ABISwiftCallInterface *ABICreateSwiftThrowingCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    const ABIValueType *errorResult, bool typedError, ABIResolutionFailure **error);
void ABIReleaseSwiftCallInterface(ABISwiftCallInterface *interface);
/// Whether a fixed value uses indirect Swift parameter/result storage.
bool ABISwiftValueIsIndirect(const ABIValueType *type);

/// Calls a thin Swift implementation using prepared register/stack lowering.
/// The caller retains code and all guaranteed arguments and supplies writable,
/// uninitialized result storage. A successful nontrivial result is owned by
/// the caller. No Swift errors, native exceptions or async suspension may cross
/// this boundary. context is the Swift self register, or null for a free function.
bool ABIUnsafeInvokeSwiftCallInterface(
    ABISwiftCallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, const void *context,
    ABIResolutionFailure **error);

/// Invokes a prepared throwing interface. didThrow selects the initialized
/// output: result on success, errorResult on native failure. Bridge preparation
/// failures return false without entering native code. Each native error is +1.
bool ABIUnsafeInvokeSwiftThrowingCallInterface(
    ABISwiftCallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, const void *context,
    void *errorResult, bool *didThrow, ABIResolutionFailure **error);

/// Internal preparation for the Swift frontend's asynchronous bridge.
typedef struct ABISwiftAsyncCallInterface ABISwiftAsyncCallInterface;
typedef struct ABISwiftAsyncInvocation ABISwiftAsyncInvocation;
ABISwiftAsyncCallInterface *ABICreateSwiftAsyncCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    const ABIValueType *errorResult, bool typedError, bool inheritsCallerIsolation,
    ABIResolutionFailure **error);
void ABIReleaseSwiftAsyncCallInterface(ABISwiftAsyncCallInterface *interface);

/// Buffers and code must remain live until the compiler-driven async bridge completes.
ABISwiftAsyncInvocation *ABICreateSwiftAsyncInvocation(
    ABISwiftAsyncCallInterface *interface, ABIUnmanagedFunction function, uint32_t contextSize,
    void *result, void *const *arguments, const void *context, void *errorResult,
    ABIResolutionFailure **error);
bool ABISwiftAsyncInvocationDidThrow(const ABISwiftAsyncInvocation *invocation);
void ABIReleaseSwiftAsyncInvocation(ABISwiftAsyncInvocation *invocation);

#ifdef __cplusplus
}
#endif
#endif
