# Using native SwiftUI views

SwiftUI interoperability reuses the Swift invocation APIs. Choose a path based on what the native declaration returns and whether its types are available while compiling your consumer or adapter.

| Native interface | Consumer requirements | Verified path |
| --- | --- | --- |
| Compiled factory returning UIViewController or NSView | Platform SDK and the exact factory signature | Resolve and call the host factory, then embed it using normal platform containment |
| Concrete Text, Image, Color, or AnyView | Import SwiftUI and declare the established ABI with ABIBridgeSwiftValue | Pass/return the actual Swift value; the compiler owns its reference payloads |
| Nongeneric factory returning some View | SwiftUI and the exact arguments; the provider module need not be importable | Receive NativeSwiftOpaqueValue, cast its Any value to any View, and erase with AnyView |
| Concrete Container<Text> from a resilient module | Import the provider and declare its indirect convention | Use a nongeneric factory or concrete entry |
| Generic Container<Content> construction or arbitrary View modifiers | A compiler-authored specialization/adapter | Let Swift supply generic metadata, View witnesses, closures, and body composition |

Knowing a metatype does not infer an arbitrary SwiftUI value's calling convention. Knowing that a symbol returns some View does not provide hidden arguments for a generic function. The direct-call responsibility described in <doc:SwiftFunctionInvocation> still applies.

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

Resolve a nongeneric native factory returning some View with NativeSwiftOpaqueValue. Swift's runtime can open its existing View conformance even when the concrete type is private or its module is unavailable at consumer compile time.

```swift
let make = try await runtime.swiftFunction(
    named: "Example.makePanel(_:)",
    as: ((String) -> NativeSwiftOpaqueValue).self
)
let result = try unsafe make.unsafeInvoke("Native panel")
```

On MainActor, use a retaining view around ordinary AnyView erasure:

```swift
@MainActor
struct NativePanel: View {
    let owner: NativeSwiftOpaqueValue
    let content: AnyView

    init(_ value: NativeSwiftOpaqueValue) throws {
        owner = value
        content = try value.withValue { payload in
            guard let view = payload as? any View else {
                throw PanelError.notAView
            }
            return AnyView(view)
        }
    }

    var body: some View { content }
}
enum PanelError: Error { case notAView }
```

Keep the opaque owner with the resulting view hierarchy. Extracting AnyView from a temporary withValue body alone does not retain the implementation-image owner. The prototype uses this wrapper in UIHostingController and NSHostingView; a dedicated supported convenience API is tracked in [#228](https://github.com/lynnswap/ABIBridge/issues/228).

## Concrete values and composition

The verified SDK declarations mark Text, Image, Color, and AnyView frozen. Image, Color, and AnyView each lower to one owned provider/storage reference. Text has a string-sized enum payload, a tag, and a modifier-array reference. The fixture declares these layouts explicitly and compares an independently compiled caller on four architectures, including the distinct 32-bit Text lowering.

These are fixture/consumer conformances, not automatic SwiftUI conformances installed by ABIBridge. One example is:

```swift
extension Color: @retroactive ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .pointer }
}
```

Use <doc:ExplicitSwiftValues> for the contract. Validate the actual target declaration against its SDK/compiler ABI before adding a conformance. A .pointer layout here describes an actual managed Swift value, not an arbitrary reinterpretation of a foreign object.

An imported resilient Container<Text> can declare a formally indirect convention and use a concrete function signature. For the generic wrap<Content: View> entry, the fixture instead compiles wrapText(_:) as an adapter. A nongeneric factory returning some View can hide the same generic composition without exposing its concrete type to the consumer.

## Isolation, updates, and lifetime

Construct, invoke, embed, mutate, and release the tested UI on MainActor. Native call handles are Sendable; that does not establish the native declaration's executor requirements. The hidden view and its host do not become Sendable.

The fixture's Observable model is the source of displayed state. Hosts render an initial value and its update, then release the model and view after teardown. Button actions invoke the retained native closure after its original wrapper and lookup runtime have gone away. SwiftUI owns its normal view identity and state lifecycle; changing the erased view type follows AnyView's standard hierarchy replacement behavior.

The validation covers rendered pixel equivalence for concrete values, opaque state changes, real host graph updates, and final reference release. Image comparison permits one 8-bit channel level of rasterization rounding; dimensions and larger visual differences must match. Provider-without-module tests compile an external consumer against ABIBridge and load only the provider dylib. This does not establish arbitrary private view-tree synthesis, undocumented SwiftUI APIs, or generic calls without their metadata/witness arguments.

See Apple's [UIHostingController](https://developer.apple.com/documentation/swiftui/uihostingcontroller), [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview), [AnyView](https://developer.apple.com/documentation/swiftui/anyview), and [ImageRenderer](https://developer.apple.com/documentation/swiftui/imagerenderer) contracts.
