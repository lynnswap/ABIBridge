# Adapting native values

Describe a foreign representation once and use a Swift wrapper in typed calls.

## Define a wrapper

For a C-compatible structure containing two doubles, declare its native field layout and the conversions between that storage and your Swift type:

```swift
import ABIBridge

struct Pair: ABIBridgeValue {
    static let abiType = try! NativeType.structure(
        named: "Example::Pair", fields: [.double, .double]
    )

    var left: Double
    var right: Double

    init(left: Double, right: Double) {
        self.left = left
        self.right = right
    }

    init(nativeValue: NativeValue) throws {
        left = try unsafe nativeValue.field(at: 0).read(as: Double.self)
        right = try unsafe nativeValue.field(at: 1).read(as: Double.self)
    }

    static func nativeValue(from value: Self) -> NativeValue {
        NativeValue(type: abiType) { bytes in
            bytes.baseAddress!.storeBytes(
                of: value.left, toByteOffset: abiType.fields[0].offset, as: Double.self
            )
            bytes.baseAddress!.storeBytes(
                of: value.right, toByteOffset: abiType.fields[1].offset, as: Double.self
            )
        }
    }
}
```

The wrapper's Swift layout does not need to match its native representation. ABIBridge uses the layout from `abiType` and the bytes returned by the conversion. Keep `abiType` stable for every prepared handle that uses it. The constant layout above contains supported fields, so its initialization is a program invariant; use ordinary error handling for layouts obtained at runtime.

Once an image defining the following C-compatible declaration is loaded:

```swift
let translate = try await ABIRuntime.shared.cxxFunction(
    named: "Example::translate(Example::Pair)",
    as: ((Pair) -> Pair).self
)
let result = try unsafe translate.unsafeInvoke(Pair(left: 2, right: 3))
```

No value container is required at the call site. Pointer-representation wrappers also support `Optional`: nil becomes a null pointer, and null results become nil without calling the wrapper initializer. Optional wrappers with other representations require an explicit native adapter.

## Use layouts discovered at runtime

A ``NativeSignature`` accepts native parameter and result descriptions. The resulting ``DynamicNativeFunction`` accepts native values and returns storage that you can cast:

```swift
let translate = try await ABIRuntime.shared.cxxFunction(
    named: "Example::translate(Example::Pair)",
    signature: .init(parameters: [Pair.abiType], returns: Pair.abiType)
)
let input = Pair.nativeValue(from: Pair(left: 2, right: 3))
let value = try unsafe translate.unsafeInvoke(with: [input])
let pair = try value.cast(to: Pair.self)
```

Argument count and layouts are checked before native dispatch. `cast(to:)` checks representations, sizes, alignments, and field layouts before calling the wrapper's initializer. Diagnostic names may differ without preventing a compatible conversion. A matching description cannot prove that an external function or memory region actually has that ABI; the adapter remains responsible for that contract.

``NativeType/structure(named:fields:)`` computes the platform C layout. Packed structures, unions, and nontrivial C++ values require a compatible native entry point. ``NativeType/opaque(named:size:alignment:)`` describes an accessible byte extent for adapters and resource owners; byte size alone is insufficient for by-value invocation.

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

Native argument storage and its owners stay alive through the call, including cleanup when another argument fails conversion. Conversion does not transfer an argument's ownership to the callee. Use a native adapter to handle consumed arguments, foreign copy constructors, and nontrivial result conventions at the actual call boundary.
