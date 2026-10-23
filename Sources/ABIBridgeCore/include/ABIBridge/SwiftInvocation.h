#ifndef ABIBRIDGE_SWIFT_INVOCATION_H
#define ABIBRIDGE_SWIFT_INVOCATION_H

#include <ABIBridge/Invocation.h>
#include <ABIBridge/SwiftDemangling.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABISwiftCallInterface ABISwiftCallInterface;

/// Storage and ownership operations for a complete Swift metadata pointer. These operations authenticate the metadata's value witnesses on arm64e.
typedef struct ABISwiftValueLayout {
    size_t size;
    size_t stride;
    size_t alignment;
} ABISwiftValueLayout;
ABISwiftValueLayout ABISwiftGetValueLayout(const void *metadata);
/// The value-witness flags word: alignment mask, POD, inline, bitwise-takable, copyable, and addressable-for-dependencies bits.
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/MetadataValues.h
uint32_t ABISwiftGetValueWitnessFlags(const void *metadata);
/// Initializes destination by copying source. The caller establishes Copyable conformance before invoking the native witness.
void ABISwiftCopyValue(const void *metadata, void *destination, const void *source);
/// Initializes destination by taking source, which is left uninitialized.
void ABISwiftTakeValue(const void *metadata, void *destination, void *source);
/// Destroys one initialized value, leaving its storage uninitialized.
void ABISwiftDestroyValue(const void *metadata, void *value);

/// Enum operations require valid enum metadata with enum value witnesses.
bool ABISwiftGetEnumTag(const void *metadata, const void *value, uint32_t *tag);
/// Initializes uninitialized enum storage using a tag already established to name a case without a payload. Returns false when enum value witnesses are unavailable.
bool ABISwiftInitializeEmptyEnumCase(const void *metadata, void *destination, uint32_t tag);
/// Initializes an enum case by taking its payload into direct storage or a new indirect box. Returns false without consuming payload when enum value witnesses are unavailable.
bool ABISwiftInitializeEnumCase(const void *metadata, void *destination, uint32_t tag,
    const void *payloadMetadata, bool indirect, void *payload);
/// Consumes an initialized enum copy into its payload. An indirect payload is copied out of its retained box; destination is uninitialized payload storage.
void ABISwiftTakeEnumPayload(const void *metadata, void *enumCopy,
    const void *payloadMetadata, bool indirect, void *destination);
typedef struct ABISwiftEnumCaseInfo {
    const char *name;
    bool hasPayload;
    bool indirect;
} ABISwiftEnumCaseInfo;
/// Case indexes follow the enum tag/field-record order. Names borrow compiler metadata.
bool ABISwiftGetEnumCaseInfo(const void *metadata, size_t index, ABISwiftEnumCaseInfo *result);
/// Resolves only this case's payload using the enum's existing generic metadata arguments.
const void *ABISwiftEnumCasePayloadMetadata(const void *metadata, size_t index);
/// Copies the case payload's formal type syntax, including indirect cases and unbound generic parameters.
ABISwiftSyntax *ABICopySwiftEnumCasePayloadSyntax(const void *metadata, size_t index);
typedef struct ABISwiftExistentialProjection {
    const void *metadata;
    const void *value;
    void *scratch;
} ABISwiftExistentialProjection;
/// Borrows one existential layer. The original value and result storage remain live while using the returned address; bridged Error values may borrow result.scratch.
bool ABISwiftProjectExistentialValue(const void *metadata, const void *value,
    ABISwiftExistentialProjection *result);

/// Standard library collection operations through libswiftCore's exported entry points. Metadata arguments are complete; hashable is the type's Hashable witness table. Collection values are single retained references: create functions return +1 values, other functions borrow them, and inout functions update them in place.
const void *ABISwiftHashableConformance(const void *metadata);
/// Returns an array of count elements whose uninitialized storage starts at *elements; the caller initializes every element.
const void *ABISwiftArrayCreate(const void *element, intptr_t count, void **elements);
intptr_t ABISwiftArrayCount(const void *array, const void *element);
/// Initializes destination with a copy of the element at index, which must be in bounds.
void ABISwiftArrayCopyElement(const void *array, intptr_t index, const void *element, void *destination);
const void *ABISwiftSetCreate(intptr_t capacity, const void *element, const void *hashable);
/// Takes member. Returns false, destroying it, when an equal member is present.
bool ABISwiftSetInsert(const void **set, void *member, const void *element, const void *hashable);
const void *ABISwiftDictionaryCreate(intptr_t capacity, const void *key, const void *value, const void *hashable);
/// Takes value and borrows key, replacing the value of an equal key.
void ABISwiftDictionaryUpdate(const void **dictionary, void *key, void *value,
    const void *keyType, const void *valueType, const void *hashable);
/// Receives one owned element (second is NULL) or one owned key and value, which it must take or destroy.
typedef void (*ABISwiftCollectionVisitor)(void *context, void *first, void *second);
/// Visits a set's members or a dictionary's pairs in iteration order.
void ABISwiftSetForEach(const void *set, const void *element, const void *hashable,
    void *context, ABISwiftCollectionVisitor visit);
void ABISwiftDictionaryForEach(const void *dictionary, const void *keyType, const void *valueType,
    const void *hashable, void *context, ABISwiftCollectionVisitor visit);

/// Reads a valid compiler-emitted generic protocol-requirement reference. Authenticates indirect Swift descriptor pointers before reading their flags.
bool ABISwiftProtocolRequirementIsClassBound(const void *reference);
/// Runtime metadata operations over valid compiler-emitted Swift descriptors. Type construction requires an already validated metadata/witness argument list.
const void *ABISwiftProtocolRequirementDescriptor(const void *reference);
const void *ABISwiftProtocolRequirementObjectiveCProtocol(const void *reference);
const void *ABISwiftConformance(const void *metadata, const void *protocol);
/// Canonical existential metadata for one valid Swift protocol descriptor.
const void *ABISwiftProtocolTypeMetadata(const void *protocol);
/// Canonical existential metadata for sorted Swift/Objective-C protocol references and an optional superclass. Class-bound protocols also impose the class constraint.
const void *ABISwiftExistentialTypeMetadata(const void *superclass,
    const void *const *protocols, size_t protocolCount, bool classBound);
/// Authenticates the shape reference in complete extended existential metadata.
const void *ABISwiftExtendedExistentialShape(const void *metadata);
/// Binds a compiler-emitted non-unique shape with validated generalization arguments.
const void *ABISwiftExtendedExistentialMetadata(const void *shape, const void *const *arguments);
const void *ABISwiftMetatypeMetadata(const void *instance);
const void *ABISwiftExistentialMetatypeMetadata(const void *instance);
/// Instantiates a validated, nontrivial writable computed-property descriptor without captures. Returns a retained Swift AnyKeyPath object; the caller retains the descriptor's image while using it.
const void *ABISwiftCreateWritableKeyPath(const void *descriptor,
    const void *root, const void *value);
/// Byte size of the writable key-path pattern, aligned to a native pointer.
size_t ABISwiftKeyPathPatternSize(void);
/// Instantiates the same descriptor with a KVC key. storage is pointer-aligned and has room for ABISwiftKeyPathPatternSize() plus the key's UTF-8 bytes and terminator. The caller retains storage for the returned object's lifetime.
const void *ABISwiftCreateWritableKeyPathWithKVCKey(const void *descriptor,
    const void *root, const void *value, const char *key, void *storage);
/// Labels are nil or one space-terminated name per element; an empty name is unlabeled. The labels buffer only needs to remain valid until this call returns.
const void *ABISwiftTupleTypeMetadata(const void *const *elements, size_t count, const char *labels);
/// Canonical native Swift function metadata from Swift ABI function/parameter flags. flags carries the parameter count and marks any supplied extended flags. Differentiability/globalActor agree with the corresponding bits in flags.
const void *ABISwiftFunctionTypeMetadata(uintptr_t flags, const void *const *parameters,
    const uint32_t *parameterFlags, const void *result, uint32_t extendedFlags, const void *thrownError,
    uintptr_t differentiability, const void *globalActor);
/// Parses the subject or type constraint of a compiler-emitted requirement. A protocol or layout requirement has no type constraint in its second field.
ABISwiftSyntax *ABICopySwiftGenericRequirementTypeSyntax(const void *requirement, bool constraint);
const void *ABISwiftConformanceDescriptor(const void *witnessTable);
/// The witness table pattern that a conformance descriptor references.
const void *ABISwiftConformanceWitnessTablePattern(const void *descriptor);
/// The address that slot `index` of a witness table holds without pointer-authentication bits: a witness's code, or the async function pointer of an async witness. The value identifies the witness; it is not authenticated for a call.
const void *ABISwiftWitnessTableEntry(const void *table, size_t index, bool asynchronous);
/// The code that an async function pointer's relative function field references. The value identifies the function; it is not signed for a call.
const void *ABISwiftAsyncFunctionPointerCode(const void *pointer);
/// Copies up to `capacity` descriptors of the conformances to `protocol` that the conformance records of the image containing `address` list, and returns how many the image lists.
size_t ABISwiftImageConformanceDescriptors(const void *address, const void *protocol,
    const void **descriptors, size_t capacity);
const void *ABISwiftAssociatedType(const void *metadata, const void *protocol, const char *name);
const void *ABISwiftGenericTypeMetadata(const void *descriptor, const void *const *arguments);
/// Interns a metadata pack in the Swift runtime. The returned tagged pointer remains owned by the runtime and may be used in type construction.
const void *ABISwiftMetadataPack(const void *const *elements, size_t count);
typedef struct ABISwiftTypeMetadata ABISwiftTypeMetadata;
/// Binds source-written type arguments through the runtime's generic type resolver, which validates constraints and obtains existing conformances.
ABISwiftTypeMetadata *ABICreateSwiftTypeMetadata(const void *descriptor,
    const void *const *arguments, size_t count, ABIResolutionFailure **error);
/// Returns an authenticated raw nominal descriptor, or null for a non-nominal type.
const void *ABISwiftTypeDescriptor(const void *metadata);
/// Reflection fields whose storage is inline in a struct or enum. Syntax trees preserve generic parameters and symbolic descriptor identities.
size_t ABISwiftTypeFieldCount(const void *metadata);
ABISwiftSyntax *ABICopySwiftTypeFieldSyntax(const void *metadata, size_t index);

/// What a struct or enum's nominal descriptor and reflection records state about its layout.
typedef struct ABISwiftValueDescriptorInfo {
    bool isEnum;
    bool isGeneric;
    /// 0 for static metadata, 1 for singleton initialization at run time, 2 for an imported foreign type.
    uint8_t metadataInitialization;
    /// A struct's stored properties, or an enum's payload and empty cases.
    uint32_t declaredFields;
    uint32_t payloadCases;
    /// Whether the descriptor references a reflection field descriptor, and its record count.
    bool hasFieldRecords;
    uint32_t fieldRecords;
} ABISwiftValueDescriptorInfo;
/// Returns false for metadata that is not a struct or enum.
bool ABISwiftGetValueDescriptorInfo(const void *metadata, ABISwiftValueDescriptorInfo *info);
/// The name in a struct field or enum case record, borrowing compiler metadata.
const char *ABISwiftTypeFieldName(const void *metadata, size_t index);
/// Metadata of a stored field or of a direct enum payload, resolved with the instance's generic arguments. Null when the record has no inline type or its type cannot be resolved. A weak field resolves to its Optional referent.
const void *ABISwiftTypeFieldMetadata(const void *metadata, size_t index);
/// A struct field's byte offset, read from the metadata's field offset vector.
bool ABISwiftStructFieldOffset(const void *metadata, size_t index, size_t *offset);
typedef enum ABISwiftReferenceStorage {
    ABISwiftReferenceStorageUnknown = -1,
    ABISwiftReferenceStorageNone = 0,
    ABISwiftReferenceStorageWeak = 1,
    ABISwiftReferenceStorageUnowned = 2,
    ABISwiftReferenceStorageUnmanaged = 3,
} ABISwiftReferenceStorage;
/// The reference ownership written in a field record's type: none, weak, unowned, or unowned(unsafe). Unknown when the record cannot be decoded.
ABISwiftReferenceStorage ABISwiftTypeFieldReferenceStorage(const void *metadata, size_t index);
/// Whether a field record's declared type mentions a generic parameter of its enclosing type.
bool ABISwiftTypeFieldIsGenericDependent(const void *metadata, size_t index);
/// The module that declares the nominal type, borrowing its descriptor's name.
const char *ABISwiftTypeModuleName(const void *metadata);
/// Whether the nominal type is declared in an extension of a generic type, directly or within another type declared in one: an extension that adds requirements, or one in another module than the type it extends. Such an extension has a generic signature, which its requirement records spell without conformances to marker protocols. An unconstrained extension in the extended type's module has no descriptor of its own.
bool ABISwiftTypeIsDeclaredInGenericExtension(const void *metadata);
/// Whether the nominal type is declared in an anonymous context, directly or within another type declared in one: a private or fileprivate declaration at its outermost private scope, or a declaration local to a function, closure, or initializer. A runtime type name spells an anonymous context by its address, where the compiler mangles the declaration's private or local discriminator.
bool ABISwiftTypeIsDeclaredInAnonymousContext(const void *metadata);
/// The mangled declaration, such as `4Main1P33_…LLV`, that the type's parent anonymous context records, which is the type's own, or null when its parent is not an anonymous context or records no name. Swift records it with -enable-anonymous-context-mangled-names, which the driver passes for -g -Onone builds.
const char *ABISwiftTypeAnonymousContextDeclaration(const void *metadata);
/// Whether the image declaring the type has a nongeneric, statically initialized struct or enum of the same module whose value witnesses set the addressable-for-dependencies bit. Swift 6.1 and earlier never set it.
bool ABISwiftModuleSetsAddressableForDependencies(const void *metadata);
/// The shape's generalized type expression, preserving symbolic references.
ABISwiftSyntax *ABICopySwiftExtendedExistentialTypeSyntax(const void *metadata);
ABISwiftSyntax *ABICopySwiftAssociatedTypeSyntax(const void *metadata, const void *protocol, const char *name);
/// Recovers the source-written arguments of existing complete metadata.
ABISwiftTypeMetadata *ABICopySwiftTypeMetadata(const void *metadata, ABIResolutionFailure **error);
size_t ABISwiftTypeMetadataArgumentCount(const ABISwiftTypeMetadata *result);
bool ABISwiftTypeMetadataArgumentIsPack(const ABISwiftTypeMetadata *result, size_t index);
size_t ABISwiftTypeMetadataArgumentElementCount(const ABISwiftTypeMetadata *result, size_t index);
const void *ABISwiftTypeMetadataArgumentElement(const ABISwiftTypeMetadata *result, size_t index, size_t element);
/// Reads the nominal declaration context for member binding. This additional information is not required to construct or inspect nominal metadata.
bool ABIPrepareSwiftTypeMetadataContext(ABISwiftTypeMetadata *result, ABIResolutionFailure **error);
/// Type references preserve source generic depth/index for member binding. Call ABIPrepareSwiftTypeMetadataContext first; returned strings borrow result.
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

/// A concrete thick Swift closure. Its context is a Swift heap reference, including closure capture contexts that are not ordinary class instances.
typedef struct ABISwiftClosureValue {
    const void *function;
    void *context;
} ABISwiftClosureValue;

/// Converts between the compiler's type-discriminated Swift function pointer and the backend's authenticated C function pointer. The discriminator must describe the concrete SIL signature, not its generic reabstraction.
ABIUnmanagedFunction ABIAuthenticateSwiftClosureFunction(const void *function, uint16_t discriminator);
const void *ABISignSwiftClosureFunction(ABIUnmanagedFunction function, uint16_t discriminator);
/// Async closures authenticate a descriptor with the data key. The descriptor contains a relative entry address and the required task-context size.
const void *ABIAuthenticateSwiftAsyncClosureDescriptor(const void *descriptor, uint16_t discriminator);
const void *ABISignSwiftAsyncClosureDescriptor(const void *descriptor, uint16_t discriminator);
typedef struct ABISwiftAsyncDescriptor ABISwiftAsyncDescriptor;
ABISwiftAsyncDescriptor *ABICopySwiftAsyncDescriptor(const void *descriptor, ABIResolutionFailure **error);
ABIUnmanagedFunction ABISwiftAsyncDescriptorFunction(const ABISwiftAsyncDescriptor *descriptor);
uint32_t ABISwiftAsyncDescriptorContextSize(const ABISwiftAsyncDescriptor *descriptor);
void ABIReleaseSwiftAsyncDescriptor(ABISwiftAsyncDescriptor *descriptor);

void ABIRetainSwiftClosureContext(void *context);
void ABIReleaseSwiftClosureContext(void *context);

/// Combines ABI scalar components and offsets with compiler-known Swift storage. Scalar field extents must fit size; component aggregate tail padding is excluded. Alignment must be a power of two. This layout is for Swift interfaces, not a libffi C calling convention.
ABIValueType *ABICreateSwiftOptionalSingletonType(void);

ABIValueType *ABICreateSwiftStorageType(
    const ABIValueType *components, size_t size, size_t alignment, ABIResolutionFailure **error);

/// Describes a formally indirect Swift value, independent of its current size. There is no C representation and no scalar component description.
ABIValueType *ABICreateSwiftIndirectStorageType(
    size_t size, size_t alignment, ABIResolutionFailure **error);

/// A formal tuple expands into independent SIL parameters/results. Offsets describe its concrete Swift storage, including nested tuple elements.
ABIValueType *ABICreateSwiftTupleStorageType(
    const ABIValueType *const *fields, const size_t *offsets, size_t count,
    size_t size, size_t alignment, ABIResolutionFailure **error);
/// A struct or enum lowered from its fields at their Swift offsets. Unlike a tuple, it is one formal value and is never split into separate parameters or results. Fields must be loadable: an address-only field makes the whole value indirect. Fails unless each field stays within its declared interval, leaf components do not overlap, and the fields rebuild size and alignment.
ABIValueType *ABICreateSwiftAggregateStorageType(
    const ABIValueType *const *fields, const size_t *offsets, size_t count,
    size_t size, size_t alignment, ABIResolutionFailure **error);
/// A formal pack passes an address vector for these concrete elements.
ABIValueType *ABICreateSwiftPackStorageType(
    const ABIValueType *const *fields, const size_t *offsets, size_t count,
    size_t size, size_t alignment, ABIResolutionFailure **error);

/// Prepares a concrete synchronous, nonthrowing Swift call from fixed value layouts. These are storage descriptions, not a C calling convention. Parameters must use ordinary guaranteed ownership. Declared formally indirect values use ABICreateSwiftIndirectStorageType; consumed/inout values and hidden generic arguments require a native adapter.
ABISwiftCallInterface *ABICreateSwiftCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, ABIResolutionFailure **error);
/// Prepares synchronous throwing invocation. Untyped errors use a pointer-sized owned Swift error reference; typed errors use their declared value layout.
ABISwiftCallInterface *ABICreateSwiftThrowingCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    const ABIValueType *errorResult, bool typedError, ABIResolutionFailure **error);
void ABIReleaseSwiftCallInterface(ABISwiftCallInterface *interface);
/// Whether a fixed value uses indirect Swift parameter/result storage.
bool ABISwiftValueIsIndirect(const ABIValueType *type);
/// Whether the value or one of its fields is address-only: formally indirect
/// whatever its size, as resilient values and generic storage are.
bool ABISwiftValueIsAddressOnly(const ABIValueType *type);
/// Whether a value with storage `value` passes as a Swift parameter or result
/// declared with storage `declared`: the call puts the same sequence of integer
/// and floating components, at the same offsets, in registers and stack slots,
/// and an address in the same role, as an argument, a formal output, or the
/// indirect result, wherever the declared value has one, for storage at least
/// as large and aligned as the declared storage. A parameter's tuples
/// expand into separate values, so a tuple and a struct with the same slots
/// pass alike. Scalar signedness and Swift types do not take part.
bool ABISwiftValuePassesAs(const ABIValueType *value, const ABIValueType *declared, bool result);
/// Describes how a fixed value passes as a parameter or a result, as
/// ABISwiftValuePassesAs compares it. Release with ABIFreeString.
char *ABICopySwiftValueLoweringDescription(const ABIValueType *type, bool result);

/// Calls a thin Swift implementation using prepared register/stack lowering. The caller retains code and all guaranteed arguments and supplies writable, uninitialized result storage. A successful nontrivial result is owned by the caller. No Swift errors, native exceptions or async suspension may cross this boundary. context is the Swift self register, or null for a free function.
bool ABIUnsafeInvokeSwiftCallInterface(
    ABISwiftCallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, const void *context,
    ABIResolutionFailure **error);

/// Invokes a prepared throwing interface. didThrow selects the initialized output: result on success, errorResult on native failure. Bridge preparation failures return false without entering native code. Each native error is +1.
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
