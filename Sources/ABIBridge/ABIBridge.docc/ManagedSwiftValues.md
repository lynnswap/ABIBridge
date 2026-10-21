# Working with managed Swift values

Use a compiled adapter for managed Swift values whose calling convention is not described by the direct Swift frontend.

## Choose the invocation boundary

A concrete metatype lets Swift code allocate and operate on a value through the compiler's metadata and value-witness machinery. It does not tell ABIBridge how an arbitrary declaration passes that value in registers or through indirect arguments and results.

| Value | Direct Swift frontend | Compiled adapter |
| --- | --- | --- |
| String, Array<Element>, Dictionary<Key, Value>, Set<Element>, their single-level optional forms, and class references | Supported with Swift ownership | Available when another part of the signature needs adaptation |
| Fixed trivial layouts described by ABIBridgeValue | Supported within the documented Swift subset | Required if the declaration has additional unsupported conventions |
| A struct or enum containing a reference | An explicit ABIBridgeSwiftValue conformance supports an established fixed ABI | The compiler adapts additional calling conventions |
| A value Optional, such as Int64? or a closure Optional | Supported when the wrapped value has a direct representation; an Optional runtime value is unsupported | The compiler handles other payloads and their nil representation |
| A non-frozen struct from a library-evolution module | An explicit opaque ABIBridgeSwiftValue descriptor selects its declared indirect convention | Available for additional signature adaptation |
| A type unavailable to the consumer compiler | Runtime value handles and scoped callback borrows with an established declaration ABI; see <doc:SwiftOpaqueResults> and <doc:BorrowedSwiftValues> | Explicit create, inspect, and destroy operations can expose otherwise unsupported interfaces |

Use a compiled adapter when the signature falls outside the direct frontend's supported representations. Metadata and storage size alone do not establish a calling convention. Generic, existential, opaque-result, closure, and ownership support is described in <doc:SwiftValues>.

## Pass imported values through storage

Compile an adapter in a module that can import the target type and declaration. For an `Example` module exposing a copyable `Record` and `transform(_:)`, an adapter can borrow one initialized input and initialize one output:

```swift
import Example

@_cdecl("ExampleTransformRecord")
public func transformRecord(
    _ input: UnsafeRawPointer,
    _ output: UnsafeMutableRawPointer
) {
    output.bindMemory(to: Record.self, capacity: 1)
        .initialize(to: transform(input.load(as: Record.self)))
}
```

The adapter calls `transform` using the compiler-generated Swift ABI. The C entry point accepts only pointers; it must be invoked through the C frontend. Its input and output allocations must be distinct, properly aligned, and large enough for one `Record`. The input remains initialized and owned by its caller. The output must be uninitialized before this call.

In a caller that also imports `Example`, use ``NativeValue`` for the storage and lifetime:

```swift
import ABIBridge
import Example

let function = try ABIRuntime.shared.resolveCFunctionAndWait(
    named: "ExampleTransformRecord",
    as: ((UnsafeRawPointer, UnsafeMutableRawPointer) -> Void).self
)
let layout = try NativeType.opaque(
    named: "Example.Record",
    size: MemoryLayout<Record>.stride,
    alignment: MemoryLayout<Record>.alignment
)
let input = NativeValue(
    type: layout,
    destroy: { $0.assumingMemoryBound(to: Record.self).deinitialize(count: 1) }
) { bytes in
    bytes.baseAddress!.bindMemory(to: Record.self, capacity: 1)
        .initialize(to: record)
}
let output = try NativeValue(
    type: layout,
    retaining: function,
    destroy: { $0.assumingMemoryBound(to: Record.self).deinitialize(count: 1) }
) { bytes in
    try unsafe input.withUnsafeBytes {
        try unsafe function.unsafeInvoke($0.baseAddress!, bytes.baseAddress!)
    }
}
let result: Record = unsafe output.withUnsafeBytes {
    $0.baseAddress!.load(as: Record.self)
}
```

Here `record` is the caller's existing `Record`. Typed initialization copies its managed references, and loading the result creates a Swift-owned copy that can outlive the output storage. Each destructor deinitializes its value before `NativeValue` frees the allocation. Assigning a `NativeValue` shares the storage.

Use the full stride for storage bound to one typed value, including any tail padding. The opaque layout above describes only an allocation's extent. Do not put it into ``NativeSignature`` as a by-value Swift parameter. A `NativeSignature` describes a C-compatible adapter signature, which in this example has two pointer parameters and no result.

## Keep runtime-only values opaque

Use ``NativeSwiftValue`` for supported owned runtime results and ``NativeSwiftBorrowedValue`` for scoped callback inputs. They support members and ownership operations under the contracts in <doc:SwiftOpaqueResults> and <doc:BorrowedSwiftValues>. For an interface outside those contracts, expose an adapter's own opaque handles.

A caller without an importable type can use an adapter's explicitly documented create, copy, inspect, and destroy operations. Adopt each owned result with ``NativeValue/init(adopting:as:retaining:release:)`` and pass its address using ``NativeValue/reference(to:)``. A zero-byte opaque extent is sufficient when the caller only forwards a handle and the adapter owns all memory accesses.

The destroy operation must match the allocation and Swift type created by that adapter. Retain every implementation image needed by the value's operations and destruction, including the adapter and the type's module, until final release. A resolved destructor retains its implementation image; separately loaded dependencies still need their applicable loader or image owners. The imported example above uses linked modules whose code stays loaded.

A runtime metatype supplies storage dimensions and value operations. The adapter's declaration must still establish its calling convention; an arbitrary metadata address is not a callable entry.

## Preserve ownership on failure

- Copy initialization creates another live value. Destroy each initialized copy once.
- Move initialization consumes an initialized source into fresh destination storage. After a successful move, free the source allocation without destroying the former value again.
- When `NativeValue` initialization throws, it frees the allocation without calling its destructor. The initializer must clean up any partially initialized resources before throwing.
- Argument-conversion failure releases earlier argument owners and prevents dispatch. An adapter with an output pointer must therefore leave that output uninitialized when dispatch never occurs.
- When a native operation returns an owned handle, adopt it before any subsequent conversion that can throw. The adopted owner's cleanup must also run if that conversion fails.

The two-pointer adapter above is synchronous and nonthrowing. It initializes its output exactly once if entered. An adapter that can fail needs an explicit C-compatible success/error contract before the caller can decide whether to destroy the output. Thread and actor requirements remain those of the target declaration and value operations; storing a value does not make it Sendable.

## Verification

Managed-value fixtures compare compiler calls with C adapter calls for a reference-bearing frozen struct, `Int64?`, and an imported resilient struct. They check copy/move ownership and failure cleanup on macOS arm64 in Debug and Release. Cross-architecture compiler probes check generated conventions separately from runtime execution; see <doc:Architectures>.

See <doc:SwiftFunctionInvocation> for direct-call support, <doc:NativeValueAdapters> for the underlying storage API, and <doc:GenericSwiftValues> for metatype substitutions and existing protocol conformances.
