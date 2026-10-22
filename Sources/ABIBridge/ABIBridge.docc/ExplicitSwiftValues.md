# Declaring a managed Swift value layout

Adopt ``ABIBridgeSwiftValue`` when an importable Swift struct or enum has an established calling convention that ABIBridge cannot infer from its metadata, or to state that convention explicitly. Describe its fixed or formally indirect ABI once; the compiler handles copying, transfer, and destruction.

## Declare and call a managed struct

For a frozen native value containing an object reference followed by a Double:

```swift
extension Sample.Record: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "Record", fields: [.pointer, .double])
    }
}

let transform = try ABIRuntime.shared.resolveSwiftFunctionAndWait(
    named: "Sample.transform(_:)",
    as: ((Sample.Record) -> Sample.Record).self
)
let result = try unsafe transform.unsafeInvoke(input)
```

The target declaration and actual Swift value must share this layout and calling convention. Verify that fact from the module's ABI contract and compiler-generated calls. A conformance takes precedence over the convention ABIBridge infers from metadata, which fails when binary evidence does not decide a value's convention; see <doc:SwiftFunctionInvocation#Infer-struct-and-enum-conventions>. `@frozen` alone does not imply C layout.

The frontend passes the described components in Swift registers and stack storage. Large fixed values use indirect transport when their components exceed the platform limit. Compiler-owned temporary storage handles reference payloads without handwritten retain/release operations.

## Describe enums and padding

A fixed multi-payload enum needs an established payload and tag layout. For the fixture's Int64, object-reference, and empty cases, the descriptor uses pointer-width integer chunks covering a 64-bit payload, followed by a UInt8 tag:

```swift
extension Sample.Choice: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        let payload = Array(repeating: NativeType.uint,
                            count: MemoryLayout<Int64>.size / MemoryLayout<UInt>.size)
        return try! .structure(named: "Choice", fields: payload + [.uint8])
    }
}
```

Typed Swift operations inspect the actual case when copying or destroying the value. The bridge does not retain every payload word as though it were always an object pointer.

``NativeType`` computes natural C field offsets. Swift can reuse a nested value's trailing padding, so flatten scalar descriptions when needed to preserve the actual offsets. The compiler supplies storage size, stride, and alignment independently. On arm64_32, this enum has two UInt32 payload components before its tag and retains 8-byte alignment.

The descriptor must cover the Swift size without exceeding its stride, and every scalar field must lie within accessible bytes. Native transfers exclude aggregate trailing padding; owned allocations preserve Swift alignment and stride. Matching these bounds still does not prove that the component layout matches the native ABI.

## Declare formally indirect values

A non-frozen value imported from a library-evolution module can require addresses for its arguments and results even when its current storage is small. Select that convention explicitly:

```swift
extension Sample.ResilientRecord: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .opaque(named: "ResilientRecord")
    }
}
```

Within this conformance, `.opaque` declares formally indirect passing. The Swift metatype supplies size, stride, alignment, and value operations; the descriptor's optional size/alignment fields are unused. This rule applies to Swift calls. The C backend rejects an indirect Swift representation before preparing a libffi interface.

The caller must establish the declaration's indirect convention. Selecting opaque storage does not convert a direct fixed-layout declaration into an indirect one, and small storage is not a reason to change the declared convention.

## Describe Optionals

Swift passes an Optional as its enum storage, the payload and tag as integer data, or by address when its payload is address-only, whatever ABI describes the Optional. ABIBridge derives that convention from the payload's, so an Optional of a built-in value, or of a value with an explicit or inferred convention, needs no ABI of its own: `UInt32?` passes in one integer register, and nil as `0x1_0000_0000`.

An explicit ABI for such an Optional, a `valueABIs:` entry or a conformance, must pass the same way. Otherwise preparation throws ``ABIResolutionError/unsupportedDeclaration(_:)``, naming both conventions, instead of passing the Optional by address or in floating-point registers. When ABIBridge cannot establish the payload's convention, describe the payload rather than the Optional; the Optional then follows it.

## Use callbacks and members

The same conformance works with ``NativeSwiftClosure``:

```swift
let callback = try NativeSwiftClosure<(Sample.Record) -> Sample.Record> { value in
    value
}
```

Callback authentication uses the native nominal type identity derived from the metatype, including nested and Unicode names. Generic substitutions may change register lowering while preserving that identity. Formally indirect values and large fixed values use the compiler's indirect identity.

Results transfer Swift ownership. Initializers and setters transfer argument copies; borrowed calls preserve the caller's value. Array elements use compiler-supported storage without adopting this protocol individually.

The example requires a Sendable body safe for the native caller's thread. A conformance does not make the value Sendable or establish its actor/thread requirements. Throwing and async callback signatures follow <doc:SwiftClosureValues>.

## Distinguish Swift values from foreign conversions

``ABIBridgeSwiftValue`` describes the actual Swift type. ``ABIBridgeValue`` converts between a user wrapper and a possibly different foreign representation; its methods can throw and own foreign-resource adoption. C and C++ calls keep using that conversion contract. If a type adopts both protocols, Swift calls use its explicit Swift layout and compiler-owned value operations.

To describe a Swift type for one lookup without a conformance, pass its ``NativeSwiftType`` and layout in `valueABIs:`. Arguments, results, and tuple fields of that closed type then use the given layout, and the lookup's layout takes precedence over a conformance.

This conformance describes a value representation. Generic bindings, existential containers, tuples, nested closures, and runtime-only noncopyable values follow the separate contracts in <doc:SwiftValues>. Closure preparation fails before publication if the nominal identity cannot be established from the metatype. Metadata size or a matching descriptor extent alone does not establish a callable declaration.

The fixtures verify mixed reference/floating structs, tagged reference-bearing enums, large indirect fixed values, callbacks and returned closures, member ownership, and rejected undersized layouts. Compiler probes cover arm64, arm64e, and arm64_32; execution evidence is recorded separately.

Use <doc:GenericSwiftValues> for generic declaration conventions and <doc:ManagedSwiftValues> when a compiled adapter is needed.
