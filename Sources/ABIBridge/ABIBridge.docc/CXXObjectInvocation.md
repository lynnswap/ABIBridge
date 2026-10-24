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
let add = try counter.resolveMethodAndWait(
    named: "add(int)",
    as: ((Int32) -> Int32).self
)
let result = try unsafe add.unsafeInvoke(5)
```

The storage address becomes `this`. Bind the object's own storage, even when another value holds a pointer to it.

Supply member declarations relative to the class, including parameter types and qualifiers such as `current() const`. The runtime reuses its image and owner indexes across lookups. Framework, path, and retained-image scopes are available through `cxxObject(_:typeNamed:in:)`.

A direct method handle calls the resolved implementation. For a virtual override, use a table-selected method. The supplied storage must represent a live object of the declared type or its correctly adjusted base subobject. Static members use `.cxx(.function(...))` with `runtime.resolve` or `runtime.resolveAndWait`, without a receiver.

## Resolve without blocking the caller

Await `resolveMethod` to search and prepare on a worker. Its `AndWait` counterpart performs the same work synchronously. Both prepare on demand and join only required work already started by optional earlier `prepare`:

```swift
@MainActor
func increment(_ counter: NativeCXXObject) async throws -> Int32 {
    let add = try await counter.resolveMethod(
        named: "add(int)", as: ((Int32) -> Int32).self
    )
    return try unsafe add.unsafeInvoke(5)
}
```

The receiver remains in the caller's isolation domain. `resolveVirtualMethod` follows the same pattern: it captures the slot in that domain, then acquires implementation images and prepares the call interface on a worker. Named table selection uses `resolveEntry`; `resolveEntryAndWait` searches synchronously. Creating `cxxObject` scopes, binding prepared methods, and selecting explicit `entry(at:authentication:)` slots remain synchronous because they perform no search or call preparation.

## Reuse a prepared implementation with another receiver

Object lookup returns `NativeBoundCXXMethod`, which retains its receiver storage. Its `method` property returns `NativeCXXMethod`, sharing the prepared target, adapter, and call signature without retaining that binding.

```swift
let bound = try counter.resolveMethodAndWait(
    named: "add(int)", as: ((Int32) -> Int32).self
)
let add = bound.method
let result = try unsafe add.unsafeInvoke(on: anotherStorage, 2)
let anotherBound = add.bind(to: anotherStorage)
try unsafe anotherBound.unsafeInvoke(3)
```

Supply the live object or adjusted subobject expected by the implementation. Binding does not inspect class layout or compare type names. A table-selected method keeps its captured function, adjustment thunk, and authentication when rebound; it does not select a different override. See the lifetime rules below for receiver and result ownership.

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
let current = try unsafe counter.resolveVirtualMethodAndWait(
    at: layout.currentSlot,
    in: table,
    authentication: layout.currentAuthentication,
    as: (() -> Int32).self
)
let value = try unsafe current.unsafeInvoke()
```

An absolute table's address point starts at its first function slot, excluding RTTI and offset-to-top headers. Bounds and null entries are checked. Readability, executable targets, and the matching native signature remain caller requirements. Relative tables require an adapter.

Lookup captures the selected function pointer and retains its implementation image when loader metadata is available. It also retains the supplied table owner, including any generated-code owner. Later table changes do not modify an existing handle.

## Select by implementation name

When the table's image has recoverable original chained fixups and symbols, select an entry using its implementation declaration:

```swift
let entry = try table.resolveEntryAndWait(
    named: "Example::Derived::current() const"
)
let current = try unsafe counter.resolveVirtualMethodAndWait(
    entry, as: (() -> Int32).self
)
let value = try unsafe current.unsafeInvoke()
```

Supply the known address point, entry count, and subobject view as before. Name an override with the derived method's qualified declaration. Selection matches receiver-adjustment and covariant-return thunks to their implementing method and preserves the original authentication schema. It reads original file metadata, so a hooked slot still has the same identity; method capture then reads that slot's current pointer.

Queries share per-image metadata through `ABIRuntime.shared`; pass `using:` for an independent runtime. Missing files, stripped identities, or unsupported fixups throw `metadataUnavailable`; multiple matching slots or folded aliases throw `ambiguousDeclaration`. For shared-cache rewritten tables or relative layouts, use an explicit adapter:

```swift
let entry = try unsafe table.entry(
    at: layout.currentSlot,
    authentication: layout.currentAuthentication
)
```

C callers include `<ABIBridge/VirtualEntries.h>` and use `ABICopyVirtualEntry(runtime, addressPoint, entryCount, name, &failure)`. The returned owner retains the table image; `ABIVirtualEntryGet` copies its slot and authentication metadata, and `ABIReleaseVirtualEntry` releases it. Table acquisition and bounds remain caller responsibilities in every frontend.

To intercept calls through a selected shared entry, see <doc:CXXVirtualHooks>.

## Match pointer authentication to the target

``NativePointerAuthentication`` accepts an explicit key, discriminator, and address-diversity setting. Use `unsigned` only for actually unsigned storage. On builds without the authenticated-call ABI, the stored pointer is used unchanged.

Clang's current arm64e C++ ABI distinguishes the object-vtable pointer from the virtual function slots. The former uses data key A with a primary-base vtable discriminator and address diversity; slots use instruction key A with the introducing declaration's discriminator and address diversity. Compiler versions, flags, and class attributes can change these contracts. See the [Clang pointer-authentication ABI documentation](https://clang.llvm.org/docs/PointerAuthentication.html#c-virtual-tables).

Pass the target compiler's constants to `cxxVTablePointer(discriminator:)` and `cxxVirtualFunction(discriminator:)`; signed pointers cannot supply them. Function entries are authenticated, re-signed to the generic C function-pointer convention, and kept signed through invocation. Authentication failure can terminate the process without a Swift error.

## Use a native ABI adapter

Nontrivial C++ parameters and results can require copy constructors, destructors, invisible references, or indirect result storage that a plain C layout does not express. Resolve a C-compatible bridge and pass it to method lookup:

```swift
let adapter = try ABIRuntime.shared.resolveAndWait(
    NativeDeclaration(name: "ExampleInvokeTransform", language: .c)
)
let transform = try counter.resolveMethodAndWait(
    named: "transform(Example::Token) const",
    as: ((Token) -> Token).self,
    using: adapter
)
```

Here the Swift function type describes the adapter's explicit arguments and result. Its native calling contract has two preceding parameters: a generic C function pointer (`void (*)(void)`) for the original implementation, then the receiver pointer. A C++ adapter casts that function pointer to the correct typed entry point and lets the compiler handle native value construction, copying, and destruction.

Keep the incoming target as a function pointer; stripping or treating it as an unsigned address can discard authentication. Native exceptions must be translated inside the adapter into its explicit C-compatible result or error contract.

## Preserve resource lifetime

Bound methods retain the receiver, implementation, adapter image, and explicit code owners. Reusable methods retain those code dependencies without a receiver; explicit-receiver calls keep the supplied storage alive until return. A custom result wrapper that keeps its converted `NativeValue` also retains the actual receiver and method. Raw pointer results remain borrowed.

A `NativeVTable(readingFrom:...)` view retains its source receiver. Captured targets retain their implementation images without retaining that source receiver through table storage. Use `retainingCode:` for generated code whose owner must survive capture. A `NativeVTable(borrowing:...retaining:)` owner remains retained for both table storage and captured code.

Perform receiver inspection, invocation, mutation, and final destruction on threads allowed by the native object. Async resolution moves image lookup and call preparation to a worker while retaining the receiver and explicit code owners with the caller. Handles do not make C++ instances Sendable. Independently owned receiver values must retain any dependencies required by their own destruction callbacks, as described in <doc:NativeValueAdapters>.
