# Displaying native SwiftUI views

Display a native opaque view with ``NativeSwiftView``.

## Add the product

Add the ABIBridgeSwiftUI product to your SwiftUI consumer:

```swift
.product(name: "ABIBridgeSwiftUI", package: "ABIBridge")
```

## Load and display a view

Resolve a native factory returning some View through ABIBridge, then create a ``NativeSwiftView`` on MainActor:

```swift
import ABIBridge
import ABIBridgeSwiftUI
import SwiftUI

@MainActor
func loadPanel(title: String) throws -> NativeSwiftView {
    let make = try ABIRuntime.shared.resolveSwiftFunctionAndWait(
        named: "Example.makePanel(_:)",
        as: ((String) -> NativeSwiftValue).self
    )
    return try NativeSwiftView(unsafe make.unsafeInvoke(title))
}
```

Place the result in your hierarchy, apply modifiers, or pass it to UIHostingController or NSHostingView. The provider's type and module need not be importable. Its type must conform to View, and the native declaration must match the supplied ABI.

## Preserve ownership and isolation

Copies of NativeSwiftView share an immutable owner that retains the opaque storage and implementation images. You may release the original result and call handle after construction. The erased view is destroyed before its implementation images are released.

Construction and body evaluation are MainActor-isolated. NativeSwiftView is not Sendable; hidden views may have further thread or actor requirements. Keep the view or its host alive for the UI lifetime. Values extracted separately from the original opaque result still need their own code owners.

For a result that does not conform to View, construction throws ABIInvocationError.incompatibleValue with the actual runtime type. The original result remains usable.

## Supported integration paths

NativeSwiftView wraps owned opaque results using the provider's View conformance. It does not supply SwiftUI value layouts, synthesize generic arguments, or call undocumented SwiftUI APIs. For compiled hosts, explicit Text/Image/Color/AnyView layouts, and compiled generic specializations, see [SwiftUI interoperability](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftuiinteroperability).

State and view identity follow normal SwiftUI behavior. An Observable model captured by the native view continues to drive updates, and native callbacks can be retained by the view. Replacing the erased underlying type follows AnyView's standard hierarchy replacement semantics.
