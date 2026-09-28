# Calling Swift functions with opaque results

Use NativeSwiftOpaqueValue for a native declaration whose result is a single `some P`. The bridge obtains complete underlying metadata from the matched declaration's opaque descriptor. Its class constraints select a direct object result or indirect storage; the metadata supplies the actual storage size and alignment.

For a loaded module declaring `func makeSummary(_ title: String) -> some Summary`:

```swift
let make = try await ABIRuntime.shared.swiftFunction(
    named: "Example.makeSummary(_:)",
    as: ((String) -> NativeSwiftOpaqueValue).self
)
let result = try unsafe make.unsafeInvoke("Title")
result.withValue { value in
    if let summary = value as? any Summary {
        print(summary)
    }
}
```

The same result type works with supported synchronous, throwing, and async functions, methods, static methods, and property getters, including declarations in another module's extension. Match the native effects, argument ownership, receiver, and isolation conventions exactly as for ordinary calls.

## Values and lifetime

The result handle owns initialized storage for the hidden concrete value. Copies of the handle share that immutable storage. The native value is destroyed once after the last handle releases it, while its retained function, descriptor, and runtime-accessor images are still alive.

The valueType property exposes the underlying runtime metatype. It does not reveal a source-level type that the client can name, and it does not make distinct opaque declarations interchangeable in Swift's type system.

The withValue body receives an ordinary Any copy made by the Swift compiler. Standard casts can open existing protocol conformances or recognize a known underlying type. The hidden payload needs no ABIBridgeSwiftValue conformance or caller-invented fixed layout. The handle is deliberately not Sendable because its hidden value may carry actor or thread requirements.

Keep the handle alive if a value or metatype escapes withValue and will later execute native code, including during destruction. Indirect native resources and code dependencies retain their original lifetime requirements. A scoped body that extracts an independent String or number is a convenient consumption path.

Only native success adopts the output storage. Native errors and cooperative cancellation preserve the existing NativeSwiftError behavior without destroying an uninitialized result. Async storage and descriptors remain alive until the operation completes.

## Why an existential result is different

A function returning `some P` does not directly initialize an `any P` or Any container. Class-constrained opaque contracts return an owned object pointer. Unconstrained contracts use indirect storage, including hidden integers, empty tuples, and class instances. The bridge first receives the actual concrete value, then lets the compiler build the Any copy inside withValue. See <doc:SwiftExistentialValues> for declarations that themselves accept or return existential containers.

## Scope

The first supported contract is a nongeneric declaration with one opaque result at the outermost return position whose interface guarantees Copyable and Escapable. Enclosing generic metadata/witness substitutions, opaque results nested inside tuples or closures, noncopyable/nonescapable contracts, opaque callback results, and managed hook bodies require a compiled adapter. Lookup checks captured generic arguments and inverse Copyable/Escapable requirements before asking the runtime to instantiate or erase the type.

This does not synthesize protocol witnesses or provide automatic conversion to AnyView or another framework wrapper. Use the native protocol API or an explicitly compiled adapter for the desired operation.

Compiler controls compare provider descriptors and independently compiled caller signatures on arm64, x86_64, arm64e, and arm64_32. The runtime operation follows Swift's [opaque descriptor layout](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h), [generic requirements](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/GenericContext.h), and [opaque metadata accessor ABI](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/Runtime/RuntimeFunctions.def). Runtime execution is verified separately from cross-compilation.
