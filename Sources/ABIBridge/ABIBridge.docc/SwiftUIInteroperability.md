# Using native SwiftUI views

SwiftUI interoperability reuses the Swift invocation APIs. Choose a path based on what the native declaration returns and whether its types are available while compiling your consumer or adapter.

| Native interface | Consumer requirements | Verified path |
| --- | --- | --- |
| Compiled factory returning UIViewController or NSView | Platform SDK and the exact factory signature | Resolve and call the host factory, then embed it using normal platform containment |
| Concrete Text, Image, Color, or AnyView | Import SwiftUI and declare the established ABI with ABIBridgeSwiftValue | Pass/return the actual Swift value; the compiler owns its reference payloads |
| Factory returning some View | SwiftUI and the exact arguments; the provider module need not be importable | Receive NativeSwiftValue, cast its Any value to any View, and erase with AnyView |
| Concrete Container<Text> from a resilient module | Import the provider and declare its indirect convention | Use a nongeneric factory or concrete entry |
| Generic function constrained to View, such as `(T) -> T` | Import SwiftUI and bind the concrete content type | Use `genericArguments:` to supply metadata and existing View witnesses |

Generic bindings use the declaration's formal calling convention and existing View conformance. A concrete nominal result still needs an established representation; knowing its metatype does not infer an arbitrary SwiftUI value's direct calling convention. See <doc:GenericSwiftValues> and <doc:ExplicitSwiftValues>.

## A compiled host factory

A provider or adapter can expose a nongeneric factory:

```swift
@MainActor
public func makeHost(_ title: String) -> UIViewController {
    UIHostingController(rootView: Text(verbatim: title).padding())
}
```

The consumer uses its supported object result:

```swift
let make = try await runtime.swiftFunction(
    named: "Example.makeHost(_:)",
    as: ((String) -> UIViewController).self
)
// Call and embed on MainActor, following UIKit child-controller containment.
let controller = try unsafe make.unsafeInvoke("Native panel")
```

An AppKit provider can return NSView backed by NSHostingView. The provider compiler handles all View metadata and composition. A separate adapter must be able to import the declarations it compiles against; a consumer calling the finished host factory need not import the provider's private view types.

## An opaque result from an unimportable provider

Resolve a native factory returning some View with NativeSwiftValue. Swift's runtime can open its existing View conformance even when the concrete type is private or its module is unavailable at consumer compile time.

```swift
let make = try await runtime.swiftFunction(
    named: "Example.makePanel(_:)",
    as: ((String) -> NativeSwiftValue).self
)
let result = try unsafe make.unsafeInvoke("Native panel")
```

Generic opaque factories use the same result representation with `genericArguments:`. Bind the factory's complete declaration, including any enclosing type arguments; see <doc:SwiftOpaqueResults>.

Add the ABIBridgeSwiftUI product and create its owned NativeSwiftView on MainActor:

```swift
import ABIBridgeSwiftUI

let panel = try NativeSwiftView(result)
let controller = UIHostingController(rootView: panel)
```

NativeSwiftView retains the opaque result and implementation images through the view's lifetime. Copies share that owner; the original result and call handle may be released after construction. It throws ABIInvocationError.incompatibleValue when the result is not a View. The core ABIBridge product remains independent of SwiftUI.

Use ordinary SwiftUI composition or platform hosting with the returned view. See [ABIBridgeSwiftUI](https://lynnswap.github.io/ABIBridge/documentation/abibridgeswiftui) for the public API and lifetime contract.

## Concrete values and composition

The verified SDK declarations mark Text, Image, Color, and AnyView frozen. Image, Color, and AnyView each lower to one owned provider/storage reference. Text has a string-sized enum payload, a tag, and a modifier-array reference. The fixture declares these layouts explicitly and compares an independently compiled caller on four architectures, including the distinct 32-bit Text lowering.

These are fixture/consumer conformances, not automatic SwiftUI conformances installed by ABIBridge. One example is:

```swift
extension Color: @retroactive ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .pointer }
}
```

Use <doc:ExplicitSwiftValues> for the contract. Validate the actual target declaration against its SDK/compiler ABI before adding a conformance. A .pointer layout here describes an actual managed Swift value, not an arbitrary reinterpretation of a foreign object.

An imported resilient Container<Text> can declare a formally indirect convention and use a concrete function signature. The architecture fixture uses the compiled `wrapText(_:)` specialization for that rendering check. The external consumer separately calls a generic `echo<Content: View>(_:) -> Content` with `genericArguments: [.type(Text.self)]` and compares its rendered result. A factory returning some View can hide a generic composition without exposing its concrete type to the consumer.

## Isolation, updates, and lifetime

Construct, invoke, embed, mutate, and release the tested UI on MainActor. Native call handles are Sendable; that does not establish the native declaration's executor requirements. The hidden view and its host do not become Sendable.

The fixture's Observable model is the source of displayed state. Hosts render an initial value and its update, then release the model and view after teardown. Button actions invoke the retained native closure after its original wrapper and lookup runtime have gone away. SwiftUI owns its normal view identity and state lifecycle; changing the erased view type follows AnyView's standard hierarchy replacement behavior.

The validation covers rendered pixel equivalence for concrete values, opaque state changes, real host graph updates, and final reference release. Image comparison permits one 8-bit channel level of rasterization rounding; dimensions and larger visual differences must match. Provider-without-module tests compile an external consumer against ABIBridge and load only the provider dylib. This does not establish arbitrary private view-tree synthesis, undocumented SwiftUI APIs, or generic calls without their metadata/witness arguments.

See Apple's [UIHostingController](https://developer.apple.com/documentation/swiftui/uihostingcontroller), [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview), [AnyView](https://developer.apple.com/documentation/swiftui/anyview), and [ImageRenderer](https://developer.apple.com/documentation/swiftui/imagerenderer) contracts.
