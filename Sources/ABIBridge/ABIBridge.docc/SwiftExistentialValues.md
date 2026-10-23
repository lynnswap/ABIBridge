# Passing Swift existential values

Use Any or an imported protocol existential in the existing function metatype. Swift constructs and manages the container, including its dynamic type and protocol witnesses.

For a loaded module declaring `func echo(_ value: any Summary) -> any Summary`:

```swift
let echo = try ABIRuntime.shared.resolveAndWait(.function(
    "Example.echo(_:)",
    as: ((any Summary) -> any Summary).self
))
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

A payload can be inline or separately allocated, including a struct, enum, class, or resilient value with an unknown standalone call layout. The compiler constructs, copies, opens, casts, and destroys the container. Its payload needs no ``ABIBridgeSwiftValue`` conformance.

Ordinary parameters borrow their container for the call. Results transfer an owned container. NativeSwiftConsuming transfers a separate owned copy, and NativeSwiftInout provides exclusive mutable container storage; see <doc:SwiftArgumentConventions>. Async calls retain containers until completion, including cooperative cancellation. Existential values do not acquire Sendable or actor-safety guarantees from the bridge: those requirements come from the native declaration and contained value.

Keep implementation images alive while their values can execute native code, including witness calls or destruction, as described in <doc:SwiftFunctionInvocation>.

## Associated type constraints

Use a matching parameterized protocol in a typed signature:

```swift
let echo = try runtime.resolveAndWait(.function(
    "Example.echoCollection(_:)",
    as: ((any Collection<Int>) -> any Collection<Int>).self
))
let values: any Collection<Int> = try unsafe echo.unsafeInvoke([1, 2, 3])
```

Generic declarations substitute their bound types into those constraints. A signature using `any Collection<Int>` cannot describe a binding that requires `any Collection<String>`.

Superclass compositions bind their generic arguments too. For `any SourceBase<T> & Source<T>`, bind `T` through `genericArguments:` and use `any SourceBase<Int> & Source<Int>` in `as:` when `T` is `Int`. Both the superclass specialization and associated types must match, including nested superclass contexts. Additional superclass witnesses are subject to the storage limitations below.

Parameterized existential metatypes use the same interface. For a declaration accepting and returning `any Collection<Int>.Type`, use `((any Collection<Int>.Type) -> any Collection<Int>.Type).self` and pass a conforming type such as `Array<Int>.self`. The bridge preserves its type metadata and protocol witness through typed calls, runtime-only values, and callbacks. Tuple and single-level Optional containers keep this representation as well.

``NativeSwiftValue`` can receive an extended existential whose provider types are unavailable to the consumer. The bridge reuses matching metadata or obtains the shape's constraints from the protocol and superclass declarations. Swift interns the shape, keeping its descriptor and declaration images available for the runtime cache. Payloads and arguments keep their ordinary lifetimes.

An ordinary protocol-returning getter can also use `(() -> NativeSwiftValue).self` without the consumer naming its protocol in Swift code. Resolution obtains the existential metadata from the matched declaration's protocol descriptors. The returned handle owns the existential container; use `copyUnderlyingValue()` to obtain its concrete value before looking up that value's members.

## Closures and authentication

The same representations work in generated and returned Swift closures. Use the matching synchronous or async wrapper from <doc:SwiftClosureValues>.

Authentication follows the formal Swift signature. Opaque containers are formally indirect. A class-constrained existential remains class-based for authentication even when its object/witness component list uses indirect physical storage. Optional class and error containers have distinct authentication identities. Compiler probes compare these identities with generated arm64e calls.

## Scope and compiler limitations

The bridge uses existing metadata and conformances for simple and extended existentials; it does not synthesize witness tables. Ordinary protocol metatypes such as `(any P).Type` keep the protocol type's identity, while existential metatypes preserve runtime type and witness components. Noncopyable containers require their own ownership contract. Opaque `some P` results follow <doc:SwiftOpaqueResults>.

Swift compiler/runtime discrepancies can make native container storage disagree with value witnesses. Preparation rejects such layouts before invocation. Use a compiled adapter for these combinations; [issue #302](https://github.com/lynnswap/ABIBridge/issues/302) records the discrepancies and workarounds:

- `any Error & AnyObject` has inconsistent generic and native object/witness storage in Swift 6.3.
- A class composition of two unrelated protocols binding `Element` to the same type uses three native words, while runtime witnesses report two.
- Swift 6.3.3 can report excess storage for `any Base<T> & P<T>` when superclass constraints need conformance witnesses. The observed `Base<T: Hashable>` case had two native words and three runtime words on macOS 26.6.2. Associated-type conformance and same-type constraints can have the same issue.

Simple compositions such as `any PackBase<repeat each T> & Marker` support empty and mixed superclass packs. Primary-associated-type constraints require extended metadata, whose Swift 6.3 generalization omits the superclass-pack layout. A Swift 6.3.3 compiler control fails with `Expected metadata but got a metadata pack` before ABIBridge is entered; bridge preparation reports this unsupported shape.

The metadata classification follows Swift's [simple existential metadata](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h) and [existential flags](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/MetadataValues.h). Compiler fixtures cover arm64, arm64e, and arm64_32; runtime validation is recorded separately.
