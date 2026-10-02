# Declaring a managed Swift value layout

Adopt ``ABIBridgeSwiftValue`` when an importable Swift struct or enum has a known fixed calling convention. Describe the ABI once; the compiler handles the actual Swift value's copying, transfer, and destruction.

## Declare and call a managed struct

For a frozen native value containing an object reference followed by a Double:

```swift
extension Sample.Record: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "Record", fields: [.pointer, .double])
    }
}

let transform = try await ABIRuntime.shared.swiftFunction(
    named: "Sample.transform(_:)",
    as: ((Sample.Record) -> Sample.Record).self
)
let result = try unsafe transform.unsafeInvoke(input)
```

The target declaration and actual Swift value must share this layout and calling convention. Verify that fact from the module's ABI contract and compiler-generated calls. The descriptor does not infer field types from a metatype, and `@frozen` alone does not imply C layout.

The Swift frontend prepares the existing integer/floating register and stack movements. Large fixed values can use the existing indirect transport when their lowered components exceed the platform Swift limit. The compiler owns the value in the bridge's temporary storage, so reference payloads do not require handwritten retain/release methods.

## Describe enums and padding

A fixed multi-payload enum can use this contract if its complete native payload/tag lowering is established. For example, the verified fixture has an Int64 case, an object-reference case, and an empty case. Its descriptor uses pointer-width integer chunks covering the 64-bit payload, followed by a UInt8 tag. This describes that fixture, not every enum.

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

``NativeType`` computes natural C field offsets. A Swift struct may reuse a nested value's trailing padding; flatten the scalar descriptions when needed to describe the actual offsets. The compiler supplies storage size, stride, and alignment independently of the component descriptor. For this enum on arm64_32, two UInt32 payload components precede the tag, while the actual Swift value retains 8-byte alignment. The component descriptor's extent must cover the Swift size without exceeding its stride, and each scalar field must lie within the value's accessible bytes. Native transfers exclude aggregate trailing padding, while owned allocations preserve Swift alignment and stride. These bounds do not verify the semantic ABI.

## Declare formally indirect values

A non-frozen value imported from a library-evolution module can require addresses for its arguments and results even when its current storage is small. Select that convention explicitly:

```swift
extension Sample.ResilientRecord: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .opaque(named: "ResilientRecord")
    }
}
```

Within this Swift-specific conformance, an opaque descriptor declares formally indirect passing. The actual Swift metatype supplies live size, stride, alignment, and value operations; the descriptor's optional size/alignment fields are not used. This does not change opaque NativeValue storage or permit opaque C by-value calls. The C backend rejects these indirect Swift representations before preparing a libffi interface.

The caller must establish the declaration's indirect convention. Selecting opaque storage does not convert a direct fixed-layout declaration into an indirect one, and small storage is not a reason to change the declared convention.

## Use callbacks and members

The same conformance works with ``NativeSwiftClosure``:

```swift
let callback = try NativeSwiftClosure<(Sample.Record) -> Sample.Record> { value in
    value
}
```

Concrete nominal callback signatures use the native declaration identity for pointer authentication. Generic substitutions can change register lowering while retaining the same nominal discriminator. The bridge derives that identity from the supplied metatype using validated Swift demangling, including nested and Unicode names; callers do not write mangled strings. Formally indirect values and indirectly lowered large fixed values use the compiler's indirect identity. Returned values transfer their ordinary Swift ownership. Initializers and setters transfer argument copies under their existing contracts, and borrowed calls preserve the caller's value. Array elements can already use arbitrary compiler-supported storage without adopting this protocol individually.

The captured body retains the existing synchronous, nonthrowing, Sendable contract. A conformance does not make the value itself Sendable or establish an actor/thread requirement.

## Distinguish Swift values from foreign conversions

``ABIBridgeSwiftValue`` describes the actual Swift type. ``ABIBridgeValue`` converts between a user wrapper and a possibly different foreign representation; its methods can throw and own foreign-resource adoption. C and C++ calls keep using that conversion contract. If a type adopts both protocols, Swift calls use its explicit Swift layout and compiler-owned value operations.

Generic native declarations still require hidden metadata and witness arguments beyond this value contract. Simple protocol existential containers use <doc:SwiftExistentialValues>, and effectful closures use <doc:SwiftClosureValues>. Extended existentials, tuples without an established representation, noncopyable values, and nested closure values remain separate work. If the nominal identity cannot be established from the metatype, closure preparation reports that limitation before publishing an entry. Do not treat metadata size, a matching descriptor extent, or this conformance as proof that such a declaration is callable.

The fixtures verify mixed reference/floating structs, tagged reference-bearing enums, large indirect fixed values, callbacks and returned closures, member ownership, and rejected undersized layouts. Compiler probes cover arm64, x86_64, arm64e, and arm64_32; execution evidence is recorded separately.

See <doc:ManagedSwiftValues> and <doc:GenericSwiftValues> for compiler-adapter routes when the target convention is not established.
