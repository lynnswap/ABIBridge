# Working with managed Swift values

Use a compiled adapter when a Swift value needs copying, destruction, or a calling convention that the direct Swift frontend does not support.

## Choose the invocation boundary

A concrete metatype lets Swift code allocate and operate on a value through the compiler's metadata and value-witness machinery. It does not tell ABIBridge how an arbitrary declaration passes that value in registers or through indirect arguments and results.

| Value | Direct Swift frontend | Compiled adapter |
| --- | --- | --- |
| String and class references | Supported with Swift ownership | Available when another part of the signature needs adaptation |
| Fixed trivial layouts described by ABIBridgeValue | Supported within the documented Swift subset | Required if the declaration has additional unsupported conventions |
| A struct containing a reference | No general by-value support | The compiler copies and destroys the actual Swift type |
| A value Optional, such as Int64? | No general by-value support | The compiler handles both the payload and the nil representation |
| A non-frozen struct from a library-evolution module | No general by-value support | An importing adapter handles resilient metadata and indirect results |
| A type unavailable to the adapter's compiler | No inferred by-value ABI | Requires an existing compatible adapter supplied by the owning module |

This is a bounded adapter-based contract. It does not add arbitrary managed values to ``NativeSwiftFunction``, infer layouts for tuples or enums, or implement generic, existential, opaque-result, noncopyable, async, or throwing Swift invocation.

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

let function = try await ABIRuntime.shared.cFunction(
    named: "ExampleTransformRecord",
    as: ((UnsafeRawPointer, UnsafeMutableRawPointer) -> Void).self
)
let layout = try NativeType.opaque(
    named: "Example.Record",
    size: MemoryLayout<Record>.size,
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

Here `record` is the caller's existing `Record`. Typed initialization copies its managed references. Loading the result makes a Swift-owned copy, so the result can outlive the output storage. Each storage destructor deinitializes exactly the value it owns before `NativeValue` frees the allocation. Assignment of a `NativeValue` reference shares its storage; it does not copy the underlying Swift value.

The opaque layout above describes only an allocation's extent. Do not put it into ``NativeSignature`` as a by-value Swift parameter. A `NativeSignature` describes a C-compatible adapter signature, which in this example has two pointer parameters and no result.

## Keep runtime-only values opaque

A caller without an importable type can use an adapter's explicitly documented create, copy, inspect, and destroy operations. Adopt each owned result with ``NativeValue/init(adopting:as:retaining:release:)`` and pass its address using ``NativeValue/reference(to:)``. A zero-byte opaque extent is sufficient when the caller only forwards a handle and the adapter owns all memory accesses.

The destroy operation must match the allocation and Swift type created by that adapter. Retain every implementation image needed by the value's operations and destruction, including the adapter and the type's module, until final release. A resolved destructor retains its implementation image; separately loaded dependencies still need their applicable loader or image owners. The imported example above uses linked modules whose code stays loaded.

A runtime metatype and value witnesses can establish storage size/alignment and value operations. They do not supply a declaration's complete calling convention or authorize calling an arbitrary metadata address. This prototype uses typed compiler-generated operations and explicit C adapters, without reading private value-witness table offsets or synthesizing a general runtime-only Swift signature.

## Preserve ownership on failure

- Copy initialization creates another live value. Destroy each initialized copy once.
- Move initialization consumes an initialized source into fresh destination storage. After a successful move, free the source allocation without destroying the former value again.
- When `NativeValue` initialization throws, it frees the allocation without calling its destructor. The initializer must clean up any partially initialized resources before throwing.
- Argument-conversion failure releases earlier argument owners and prevents dispatch. An adapter with an output pointer must therefore leave that output uninitialized when dispatch never occurs.
- When a native operation returns an owned handle, adopt it before any subsequent conversion that can throw. The adopted owner's cleanup must also run if that conversion fails.

The two-pointer adapter above is synchronous and nonthrowing. It initializes its output exactly once if entered. An adapter that can fail needs an explicit C-compatible success/error contract before the caller can decide whether to destroy the output. Thread and actor requirements remain those of the target declaration and value operations; storing a value does not make it Sendable.

## Verification boundary

The executable managed-value fixtures compare ordinary compiler calls with ABIBridge's C adapter calls for a reference-bearing frozen struct, both cases of `Int64?`, and a non-frozen struct imported across a library-evolution boundary. They cover copied and moved storage, indirect-result ownership, runtime-only opaque handles, and cleanup after argument/result conversion failures.

The compiler probe separately records the generated call signatures and resilient copy/take/destroy operations for arm64, x86_64, arm64e, and arm64_32 targets. Compilation evidence is not runtime execution coverage. The initial runtime checks use macOS arm64 in Debug and Release; other targets require their own execution evidence.

See <doc:SwiftFunctionInvocation> for direct-call support and <doc:NativeValueAdapters> for the underlying storage API.
