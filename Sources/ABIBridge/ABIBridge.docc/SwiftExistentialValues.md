# Passing Swift existential values

Use Any or an imported protocol existential in the existing function metatype. Swift constructs and manages the container, including its dynamic type and protocol witnesses.

For a loaded module declaring `func echo(_ value: any Summary) -> any Summary`:

```swift
let echo = try await ABIRuntime.shared.swiftFunction(
    named: "Example.echo(_:)",
    as: ((any Summary) -> any Summary).self
)
let result = try unsafe echo.unsafeInvoke(existingSummary)
print(result)
```

The native declaration must accept and return that existential type. Selecting Any does not convert a native function declared with a concrete struct result into an existential-returning function.

## Representations and ownership

| Declared type | Native representation |
| --- | --- |
| Any, any P, any P & Q | Opaque container, passed and returned indirectly |
| Class-constrained protocol or composition | Object reference and protocol witnesses; large component lists use indirect physical storage |
| any Error | Swift's boxed error reference |
| Single-level Optional of these types | The matching optional container, including nil |

A payload can be inline or allocated outside the container. It may be a concrete struct, enum, class, or resilient value whose standalone call layout is unknown to the bridge. The compiler constructs the existential and performs copying, opening, casting, and destruction. The payload does not need ABIBridgeSwiftValue conformance.

Ordinary parameters borrow their container for the call. Results transfer an owned container. NativeSwiftConsuming transfers a separate owned copy, and NativeSwiftInout provides exclusive mutable container storage; see <doc:SwiftArgumentConventions>. Async calls retain containers until completion, including cooperative cancellation. Existential values do not acquire Sendable or actor-safety guarantees from the bridge: those requirements come from the native declaration and contained value.

Keep implementation images alive while their values can execute native code, including witness calls or destruction, as described in <doc:SwiftFunctionInvocation>.

## Closures and authentication

The same representations work in generated and returned Swift closures. Use the matching synchronous or async wrapper from <doc:SwiftClosureValues>.

Authentication follows the formal Swift signature. Opaque containers are formally indirect. A class-constrained existential remains class-based for authentication even when its object/witness component list uses indirect physical storage. Optional class and error containers have distinct authentication identities. Compiler probes compare these identities with generated arm64e calls.

## Scope

This path recognizes Swift's simple existential metadata: protocol compositions, class/superclass constraints, and the special Error container. Existing AnyObject behavior is preserved. It uses the actual imported existential metatype; it does not synthesize witness tables or discover a missing conformance.

Extended existentials such as `any Collection<Int>` and noncopyable containers are separate contracts. Existential metatypes preserve their runtime type and witness components; ordinary protocol metatypes such as `(any P).Type` retain the protocol type's identity. Opaque `some P` results use <doc:SwiftOpaqueResults>. Swift 6.3's generic storage for `any Error & AnyObject` disagrees with its native object/witness layout; the existing storage-layout validation rejects that composition. Use a compiled adapter for it. Bind a function's hidden generic metadata and witnesses with `genericArguments:`, as described in <doc:GenericSwiftValues>.

The metadata classification follows Swift's [simple existential metadata](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h) and [existential flags](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/MetadataValues.h). Compiler fixtures cover arm64, x86_64, arm64e, and arm64_32; runtime validation is recorded separately.
