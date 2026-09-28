#ifndef ABIBRIDGE_SWIFT_INVOCATION_H
#define ABIBRIDGE_SWIFT_INVOCATION_H

#include <ABIBridge/Invocation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABISwiftCallInterface ABISwiftCallInterface;

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
ABIValueType *ABICreateSwiftStorageType(
    const ABIValueType *components, size_t size, size_t alignment, ABIResolutionFailure **error);

/// Describes a formally indirect Swift value, independent of its current size.
/// There is no C representation and no scalar component description.
ABIValueType *ABICreateSwiftIndirectStorageType(
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
