# Using native SwiftUI views

Choose a Swift invocation path from the native result type and the types available to your consumer or adapter.

| Native interface | Consumer requirements | Verified path |
| --- | --- | --- |
| Compiled factory returning UIViewController or NSView | Platform SDK and the exact factory signature | Resolve and call the host factory, then embed it using normal platform containment |
| Concrete Text, Image, Color, or AnyView | Import SwiftUI and declare the established ABI with ABIBridgeSwiftValue | Pass/return the actual Swift value; the compiler owns its reference payloads |
| Factory returning some View | SwiftUI and the exact arguments; the provider module need not be importable | Receive NativeSwiftValue and wrap it in NativeSwiftView from ABIBridgeSwiftUI |
| Concrete Container<Text> from a resilient module | Import the provider and declare its indirect convention | Use a nongeneric factory or concrete entry |
| Generic function constrained to View, such as `(T) -> T` | Import SwiftUI and bind the concrete content type | Use `genericArguments:` to supply metadata and existing View witnesses |

Generic bindings use the declaration's formal calling convention and existing View conformance. A concrete nominal result still needs an established representation when ABIBridge cannot infer its convention from metadata; see <doc:SwiftFunctionInvocation#Infer-struct-and-enum-conventions>. See <doc:GenericSwiftValues> and <doc:ExplicitSwiftValues>.

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
let make = try runtime.resolveAndWait(.function(
    "Example.makeHost(_:)",
    as: ((String) -> UIViewController).self
))
// Call and embed on MainActor, following UIKit child-controller containment.
let controller = try unsafe make.unsafeInvoke("Native panel")
```

An AppKit provider can return NSView backed by NSHostingView. The provider compiler handles all View metadata and composition. A separate adapter must be able to import the declarations it compiles against; a consumer calling the finished host factory need not import the provider's private view types.

## An opaque result from an unimportable provider

Resolve a native factory returning some View with NativeSwiftValue. Swift's runtime can open its existing View conformance even when the concrete type is private or its module is unavailable at consumer compile time.

```swift
let make = try runtime.resolveAndWait(.function(
    "Example.makePanel(_:)",
    as: ((String) -> NativeSwiftValue).self
))
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

Compose or host `panel` using standard SwiftUI APIs. See [ABIBridgeSwiftUI](https://lynnswap.github.io/ABIBridge/documentation/abibridgeswiftui) for its API contract.

## Concrete values and composition

The checked SDK declarations mark Text, Image, Color, and AnyView frozen. Image, Color, and AnyView lower to one owned storage reference. Text has a string-sized enum payload, a tag, and a modifier-array reference, with distinct 32-bit lowering.

Consumers declare these conformances themselves. For example:

```swift
extension Color: @retroactive ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .pointer }
}
```

Use <doc:ExplicitSwiftValues> for the contract. Validate the actual target declaration against its SDK/compiler ABI before adding a conformance. A .pointer layout here describes an actual managed Swift value, not an arbitrary reinterpretation of a foreign object.

An imported resilient `Container<Text>` can declare a formally indirect convention and use a concrete signature. A generic `echo<Content: View>(_:) -> Content` instead binds `Text` with `genericArguments: [.type(Text.self)]`. A `some View` factory hides the composition behind its opaque result.

## Isolation, updates, and lifetime

Construct, invoke, embed, mutate, and release the tested UI on MainActor. Native call handles are Sendable; that does not establish the native declaration's executor requirements. The hidden view and its host do not become Sendable.

SwiftUI keeps its normal view identity and state lifecycle. An Observable model remains the source of displayed state. Changing the erased view type follows AnyView's hierarchy replacement behavior, and stored native actions need their closure context and code owners alive.

Tests compare concrete rendered values, opaque state updates, retained actions, and final reference release. An external consumer loads the provider dylib without importing its module. Those checks cover the declared interfaces; private view-tree synthesis and undocumented SwiftUI APIs are outside this path.

See Apple's [UIHostingController](https://developer.apple.com/documentation/swiftui/uihostingcontroller), [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview), [AnyView](https://developer.apple.com/documentation/swiftui/anyview), and [ImageRenderer](https://developer.apple.com/documentation/swiftui/imagerenderer) contracts.
