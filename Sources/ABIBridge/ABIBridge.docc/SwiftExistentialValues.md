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
| Parameterized protocols, such as any Collection<Int> | The extended shape preserves associated type constraints and the opaque or class-constrained convention |
| Single-level Optional of these types | The matching optional container, including nil |

A payload can be inline or allocated outside the container. It may be a concrete struct, enum, class, or resilient value whose standalone call layout is unknown to the bridge. The compiler constructs the existential and performs copying, opening, casting, and destruction. The payload does not need ABIBridgeSwiftValue conformance.

Ordinary parameters borrow their container for the call. Results transfer an owned container. NativeSwiftConsuming transfers a separate owned copy, and NativeSwiftInout provides exclusive mutable container storage; see <doc:SwiftArgumentConventions>. Async calls retain containers until completion, including cooperative cancellation. Existential values do not acquire Sendable or actor-safety guarantees from the bridge: those requirements come from the native declaration and contained value.

Keep implementation images alive while their values can execute native code, including witness calls or destruction, as described in <doc:SwiftFunctionInvocation>.

## Associated type constraints

Use a matching parameterized protocol in a typed signature:

```swift
let echo = try await runtime.swiftFunction(
    named: "Example.echoCollection(_:)",
    as: ((any Collection<Int>) -> any Collection<Int>).self
)
let values: any Collection<Int> = try unsafe echo.unsafeInvoke([1, 2, 3])
```

Generic declarations substitute their bound types into those constraints. A signature using `any Collection<Int>` cannot describe a binding that requires `any Collection<String>`.

Superclass compositions also bind their generic arguments. For a declaration returning `any SourceBase<T> & Source<T>`, bind `T` through `genericArguments:` and use `any SourceBase<Int> & Source<Int>` in `as:` when `T` is `Int`. The superclass specialization and the protocol's associated types must both match. Binding includes nested generic superclass contexts. Compositions whose superclass requires additional conformance witnesses are also subject to the storage limitation below.

NativeSwiftValue also receives an extended existential when the provider's types are unavailable to the consumer. The bridge reuses matching caller metadata or the provider's generalized shape. If the provider did not emit a shape, the protocol and superclass declarations supply its constraints and existing witnesses. Swift's runtime interns that shape; its descriptor and referenced declaration images remain available for the runtime cache's lifetime. User payloads and invocation arguments keep their ordinary value lifetimes.

## Closures and authentication

The same representations work in generated and returned Swift closures. Use the matching synchronous or async wrapper from <doc:SwiftClosureValues>.

Authentication follows the formal Swift signature. Opaque containers are formally indirect. A class-constrained existential remains class-based for authentication even when its object/witness component list uses indirect physical storage. Optional class and error containers have distinct authentication identities. Compiler probes compare these identities with generated arm64e calls.

## Scope

This path recognizes simple existential metadata and extended parameterized protocols, including class-constrained protocols. Existing AnyObject behavior is preserved. It uses the actual imported existential metatype; it does not synthesize witness tables or discover a missing conformance.

Extended superclass compositions use the same typed and runtime-only paths described above. Superclass parameter packs remain outside shape construction: Swift 6.3's extended-existential generalization does not emit their pack layout. Noncopyable containers also require their own ownership contract. Existential metatypes preserve their runtime type and witness components; ordinary protocol metatypes such as `(any P).Type` retain the protocol type's identity. Opaque `some P` results use <doc:SwiftOpaqueResults>. Swift 6.3's generic storage for `any Error & AnyObject` disagrees with its native object/witness layout; the existing storage-layout validation rejects that composition. Use a compiled adapter for it. Bind a function's hidden generic metadata and witnesses with `genericArguments:`, as described in <doc:GenericSwiftValues>.

Swift 6.3.3 can report a larger generic storage size for `any Base<T> & P<T>` when `Base` constrains `T` to a protocol. For example, `Base<T: Hashable>` produced a two-word native container and a three-word runtime layout on macOS 26.6.2. The bridge uses the native container convention and fails preparation if the runtime storage disagrees. This also affects superclass constraints involving associated-type conformances or same-type parameters. The compiler/runtime discrepancy and possible workarounds are tracked in [#302](https://github.com/lynnswap/ABIBridge/issues/302).

The metadata classification follows Swift's [simple existential metadata](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h) and [existential flags](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/MetadataValues.h). Compiler fixtures cover arm64, x86_64, arm64e, and arm64_32; runtime validation is recorded separately.
