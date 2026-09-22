# Calling C++ object methods

Bind native receiver storage and call a direct implementation or an explicitly described virtual-table entry.

## Bind a receiver

Borrow or adopt the object's own address in a ``NativeValue``, then identify its qualified C++ type:

```swift
let storage = unsafe NativeValue(
    borrowing: receiverAddress,
    as: try .opaque(named: "Example::Counter"),
    retaining: owner
)
let counter = ABIRuntime.shared.cxxObject(
    storage, typeNamed: "Example::Counter"
)
let add = try await counter.method(
    named: "add(int)",
    as: ((Int32) -> Int32).self
)
let result = try unsafe add.unsafeInvoke(5)
```

The receiver storage address becomes `this`. A value whose bytes contain a pointer is a different representation; borrow or adopt the pointee itself when binding an object.

Supply member declarations relative to the class, including parameter types and qualifiers such as `current() const`. The runtime reuses its image and owner indexes across lookups. Framework, path, and retained-image scopes are available through `cxxObject(_:typeNamed:in:)`.

A direct method handle calls the resolved implementation. For a virtual override, use a table-selected method. The supplied storage must represent a live object of the declared type or its correctly adjusted base subobject. Static members use `cxxFunction` without a receiver.

## Describe a subobject

For multiple inheritance, use offsets and extents established by a target-specific adapter:

```swift
let baseStorage = try storage.view(
    at: layout.baseOffset,
    as: layout.baseType
)
let base = ABIRuntime.shared.cxxObject(
    baseStorage, typeNamed: "Example::Base"
)
```

The bounded view retains its parent. A zero-byte opaque extent is sufficient for passing an existing address to a direct method, but it cannot authorize field reads or nonzero-offset views. Describe the necessary accessible extent before reading a vtable-pointer field.

## Select a virtual entry

The adapter supplies the vtable-pointer offset, accessible entry count, slot index, and authentication schemas:

```swift
let table = try unsafe NativeVTable(
    readingFrom: storage,
    at: layout.vtableOffset,
    entryCount: layout.entryCount,
    authentication: layout.vtableAuthentication
)
let current = try unsafe counter.virtualMethod(
    at: layout.currentSlot,
    in: table,
    authentication: layout.currentAuthentication,
    as: (() -> Int32).self
)
let value = try unsafe current.unsafeInvoke()
```

An absolute table's address point starts at its first function slot, excluding RTTI and offset-to-top headers. Bounds and null entries are checked. Readability, executable targets, and the matching native signature remain caller requirements. Relative tables require an adapter.

Lookup captures the selected function pointer and retains its implementation image when loader metadata is available. It also retains the supplied table owner, including any generated-code owner. Later table changes do not modify an existing handle.

## Match pointer authentication to the target

``NativePointerAuthentication`` accepts an explicit key, discriminator, and address-diversity setting. Use `unsigned` only for actually unsigned storage. On builds without the authenticated-call ABI, the stored pointer is used unchanged.

Clang's current arm64e C++ ABI distinguishes the object-vtable pointer from the virtual function slots. The former uses data key A with a primary-base vtable discriminator and address diversity; slots use instruction key A with the introducing declaration's discriminator and address diversity. Compiler versions, flags, and class attributes can change these contracts. See the [Clang pointer-authentication ABI documentation](https://clang.llvm.org/docs/PointerAuthentication.html#c-virtual-tables).

The `cxxVTablePointer(discriminator:)` and `cxxVirtualFunction(discriminator:)` helpers require the target compiler's constants. They do not derive those values from live signed pointers. Authentication failure can fault and is not translated to Swift error handling.

Function entries are authenticated and re-signed to the generic C function-pointer convention. That signed value is preserved through invocation. An unsigned address obtained for loader inspection is never substituted for the authenticated callable.

## Use a native ABI adapter

Nontrivial C++ parameters and results can require copy constructors, destructors, invisible references, or indirect result storage that a plain C layout does not express. Resolve a C-compatible bridge and pass it to method lookup:

```swift
let adapter = try await ABIRuntime.shared.resolve(
    NativeDeclaration(name: "ExampleInvokeTransform", language: .c)
)
let transform = try await counter.method(
    named: "transform(Example::Token) const",
    as: ((Token) -> Token).self,
    using: adapter
)
```

Here the Swift function type describes the adapter's explicit arguments and result. Its native calling contract has two preceding parameters: a generic C function pointer (`void (*)(void)`) for the original implementation, then the receiver pointer. A C++ adapter casts that function pointer to the correct typed entry point and lets the compiler handle native value construction, copying, and destruction.

Keep the incoming target as a function pointer; stripping or treating it as an unsigned address can discard authentication. Native exceptions must be translated inside the adapter into its explicit C-compatible result or error contract.

## Preserve resource lifetime

A method retains its receiver, selected implementation, adapter image, and supplied table owner. When a wrapper keeps the `NativeValue` returned during conversion, that result also keeps the binding alive, which supports borrowed native results. Raw pointer results have no such owner and remain borrowed.

Perform lookup, calls, mutation, and final destruction on threads allowed by the native object. Handles do not make C++ instances Sendable. Independently owned receiver values must retain any dependencies required by their own destruction callbacks, as described in <doc:NativeValueAdapters>.
