# Calling Swift functions with opaque results

Use NativeSwiftValue for a native declaration whose result is a single `some P`. The bridge obtains complete underlying metadata from the matched declaration's opaque descriptor. Its class constraints select a direct object result or indirect storage; the metadata supplies the actual storage size and alignment.

For a loaded module declaring `func makeSummary(_ title: String) -> some Summary`:

```swift
let make = try await ABIRuntime.shared.swiftFunction(
    named: "Example.makeSummary(_:)",
    as: ((String) -> NativeSwiftValue).self
)
let result = try unsafe make.unsafeInvoke("Title")
try result.withCopy { value in
    if let summary = value as? any Summary {
        print(summary)
    }
}
```

The same result type works with supported synchronous, throwing, and async functions, methods, static methods, and property getters, including declarations in another module's extension. Match the native effects, argument ownership, receiver, and isolation conventions exactly as for ordinary calls.

## Values and lifetime

The result handle owns initialized storage for the hidden concrete value. Assigning the handle shares that owner; copy() creates an independent native copy when the actual type is copyable. The native value is destroyed once after its final owner releases it, or transferred by take(as:), while its implementation images remain alive.

The type property exposes a retained NativeSwiftType, including the underlying type name. It does not make distinct opaque declarations interchangeable in Swift's type system.

The withCopy body receives an ordinary Any copy and retains its implementation images throughout the body. Copying a noncopyable value throws NativeSwiftValueError.noncopyableType. Standard casts can open existing protocol conformances or recognize a known underlying type. The hidden payload needs no ABIBridgeSwiftValue conformance or caller-invented fixed layout. The handle is deliberately not Sendable because its hidden value may carry actor or thread requirements.

Keep the handle alive if a value or metatype escapes withCopy and will later execute native code, including during destruction. Indirect native resources and code dependencies retain their original lifetime requirements. A scoped body that extracts an independent String or number is a convenient consumption path.

Use withBorrowedValue for scoped access without copying. A saved borrowed view expires when the body returns. take(as:) moves an exact known type, including a noncopyable type, and leaves the handle consumed; a type mismatch preserves the original value. Conflicting access during an active native operation throws NativeSwiftValueError.valueInUse.

Only native success adopts the output storage. Native errors and cooperative cancellation preserve the existing NativeSwiftError behavior without destroying an uninitialized result. Async storage and descriptors remain alive until the operation completes.

## Call ordinary members

Prepare members through the result's type and pass the owner directly. For a hidden resilient value whose implementation provides `read()` and a mutating `add(_:)`:

```swift
let selfABI = try NativeType.opaque(named: result.type.name)
let read = try await result.type.method(
    named: "read()", as: (() -> Int64).self, receiverABI: selfABI
)
let add = try await result.type.method(
    named: "add(_:)", as: ((Int64) -> Void).self,
    receiverABI: selfABI, mutating: true
)
try unsafe add.unsafeInvoke(on: result, 5)
print(try unsafe read.unsafeInvoke(on: result))
```

The opaque descriptor describes the factory's result convention, not every underlying member's self convention. Supply receiverABI when that convention is unavailable from the type's representation or generic declaration. Fixed components use the same NativeType contract as ABIBridgeSwiftValue; an opaque descriptor selects formally indirect self. Class receivers use their reference representation without an override.

Consuming members prepared with `consuming: true` transfer the owner's native value, including noncopyable payloads. The same handle accepts an active borrowed view for nonmutating, nonconsuming members. NativeSwiftBorrowedMethod, borrowedMethod and borrowedGetter are replaced by these ordinary handles; getter signatures now use the complete zero-argument function type.

## Why an existential result is different

A function returning `some P` does not directly initialize an `any P` or Any container. Class-constrained opaque contracts return an owned object pointer. Unconstrained contracts use indirect storage, including hidden integers, empty tuples, and class instances. The bridge first receives the actual concrete value, then lets the compiler build the Any copy inside withCopy. See <doc:SwiftExistentialValues> for declarations that themselves accept or return existential containers.

## Scope

The first supported contract is a nongeneric declaration with one opaque result at the outermost return position whose interface guarantees Escapable. Copyability comes from the concrete metadata; some ~Copyable results use the same owned storage and can be moved without Any erasure. Enclosing generic metadata/witness substitutions, opaque results nested inside tuples or closures, nonescapable contracts, opaque callback results, and managed hook bodies require a compiled adapter. Lookup checks captured generic arguments and inverse Escapable requirements before asking the runtime to instantiate or erase the type.

This does not synthesize protocol witnesses. Existing View conformance can be opened and erased with AnyView while retaining the result owner; see <doc:SwiftUIInteroperability>. Use the native protocol API or an explicitly compiled adapter for other operations.

Compiler controls compare provider descriptors and independently compiled caller signatures on arm64, x86_64, arm64e, and arm64_32. The runtime operation follows Swift's [opaque descriptor layout](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h), [generic requirements](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/GenericContext.h), and [opaque metadata accessor ABI](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/Runtime/RuntimeFunctions.def). Runtime execution is verified separately from cross-compilation.
