# Adapting native values

Describe a foreign representation once and use a Swift wrapper in typed calls.

## Choose the native calling convention

Caller-described types work across C, C++, Objective-C, and Swift. The native declaration determines how a value crosses the call boundary; a Swift metatype determines how the caller interprets it.

| Declaration | Where its value layout comes from |
| --- | --- |
| C or C-compatible C++ | `ABIBridgeValue.abiType`, or `NativeSignature` and `NativeValue` |
| Objective-C | The method's runtime type encoding; select a compatible Swift function metatype |
| Swift | Built-in representations or `ABIBridgeSwiftValue.swiftABIType` for the actual imported Swift value |

These paths preserve each language's ownership and register conventions. Nontrivial C++ construction, destruction, and call lowering require a compiler adapter.

## Declare a byte-compatible layout once

For a C-compatible structure containing two doubles, declare the native layout on a bitwise-copyable Swift value:

```swift
import ABIBridge

struct Pair: BitwiseCopyable, ABIBridgeValue {
    static let abiType = try! NativeType.structure(
        named: "Example::Pair", fields: [.double, .double]
    )
    var left: Double
    var right: Double
}

let translate = try ABIRuntime.shared.cxxFunction(
    named: "Example::translate(Example::Pair)",
    as: ((Pair) -> Pair).self
)
let result = try unsafe translate.unsafeInvoke(Pair(left: 2, right: 3))
```

``ABIBridgeValue`` supplies default byte conversions for `BitwiseCopyable` conformers. The caller's conformance guarantees field representations, offsets, and valid values. Native tail padding can extend to the Swift value's stride and is zero-filled when copied. Pointer fields copy their bits; they do not retain pointees.

C functions, C-compatible C++ members, and their callbacks share this codec. Keep `abiType` stable for each handle. Implement `init(nativeValue:)` and `nativeValue(from:)` when storage differs or referenced resources need ownership.

A Swift enum's raw-value type can differ from its stored tag. For example, two cases with Int32 raw values can use a one-byte tag. C/C++ calls need the native enum representation: pass its raw-value type or convert through `rawValue`. Actual Swift enums use ``ABIBridgeSwiftValue``; see <doc:ExplicitSwiftValues>.

## Use layouts discovered at runtime

A ``NativeSignature`` accepts native parameter and result descriptions. The resulting ``DynamicNativeFunction`` accepts native values and returns storage that you can cast:

```swift
let translate = try ABIRuntime.shared.cxxFunction(
    named: "Example::translate(Example::Pair)",
    signature: .init(parameters: [Pair.abiType], returns: Pair.abiType)
)
let input = try Pair.nativeValue(from: Pair(left: 2, right: 3))
let value = try unsafe translate.unsafeInvoke(with: [input])
let pair = try value.cast(to: Pair.self)
```

If the caller type does not conform to `ABIBridgeValue`, pass its byte-compatible value and read the result with its metatype:

```swift
struct PairBytes: BitwiseCopyable {
    var left: Double
    var right: Double
}
let input = try NativeValue(
    copying: PairBytes(left: 2, right: 3), as: Pair.abiType
)
let nativeResult = try unsafe translate.unsafeInvoke(with: [input])
let result = try unsafe nativeResult.read(as: PairBytes.self)
```

This uses the runtime-signature `translate` above. The unsafe read checks bounds; guarantee the representation and valid bit patterns yourself. `PairBytes` needs no protocol conformance or registration.

Argument count and layouts are checked before native dispatch. `cast(to:)` checks representations, sizes, alignments, and field layouts before calling the wrapper's initializer. Diagnostic names may differ without preventing a compatible conversion. A matching description cannot prove that an external function or memory region actually has that ABI; the adapter remains responsible for that contract.

``NativeType/structure(named:fields:)`` computes the platform C layout. Packed structures, unions, and nontrivial C++ values require a compatible native entry point. ``NativeType/opaque(named:size:alignment:)`` describes an accessible byte extent for adapters and resource owners; byte size alone is insufficient for by-value invocation.

For Swift values containing managed references or resilient layouts, see <doc:ManagedSwiftValues>. The value's allocation and ownership are separate from its declaration's Swift calling convention.

## Establish storage and resource lifetime

Native values provide three ownership paths:

- Allocated storage is released automatically after an optional destruction callback. The initialization closure receives its exact byte extent.
- Adopted storage uses the caller's release callback to destroy and free an external allocation exactly once.
- Borrowed storage does not destroy or free memory. A retained owner can keep the allocation alive; ownerless storage must outlive all uses and views.

For an external resource whose release function is already available:

```swift
let resource = unsafe NativeValue(
    adopting: resourceAddress,
    as: try .opaque(named: "Example::Resource"),
    retaining: implementationOwner,
    release: { releaseResource($0) }
)
let argument = NativeValue.reference(to: resource)
```

The release callback must match the allocator and foreign destructor. Retain dependencies needed during release, such as a function handle that keeps the implementation image loaded. The zero-byte opaque extent above allows the address to be passed to a native adapter without claiming to know its object layout.

A field view retains its containing value. A pointer value made by `reference(to:)` retains its pointee. Pointer bits copied into a value do not otherwise retain the referenced resource. In particular, a pointer returned from native code needs the lifetime prescribed by that function's contract; ABIBridge cannot infer that it aliases an argument or transfers ownership.

Values and views are not Sendable. Perform accesses and final release on threads permitted by the foreign resource. Borrowed bytes can be read unaligned, and by-value invocation copies arguments to aligned call buffers. Passing an address as a pointer also requires whatever alignment and validity the native callee expects.

## Handle initialization and conversion failures

When an initialization closure throws, ABIBridge frees its allocation without calling the destruction callback. The closure must undo any partially initialized foreign resources before throwing.

A wrapper adopting an owned native result should establish its release operation before later validation that can throw. If conversion fails after adoption, ordinary Swift lifetime cleanup releases the adopted resource. If the wrapper throws before taking ownership, it must release any resource already transferred by the native function.

Argument storage and owners survive the call and cleanup after conversion failure. Conversion alone transfers no ownership. For consumed Objective-C parameters, use `NativeMethodOptions.consumedArguments`; for Core Foundation references, use `Unmanaged<T>` with the manual ownership rules in <doc:CFunctionInvocation>.
