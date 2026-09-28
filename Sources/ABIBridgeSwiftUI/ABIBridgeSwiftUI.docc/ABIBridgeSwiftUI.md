# ``ABIBridgeSwiftUI``

Display native opaque SwiftUI results while retaining their values and implementation images.

## Overview

Add the ABIBridgeSwiftUI product to a SwiftUI consumer. The ABIBridge product remains available separately for native-only code and does not depend on SwiftUI.

```swift
.product(name: "ABIBridgeSwiftUI", package: "ABIBridge")
```

Resolve a nongeneric native factory returning some View through ABIBridge, then create a ``NativeSwiftView`` on MainActor:

```swift
import ABIBridge
import ABIBridgeSwiftUI
import SwiftUI

@MainActor
func loadPanel(title: String) async throws -> NativeSwiftView {
    let make = try await ABIRuntime.shared.swiftFunction(
        named: "Example.makePanel(_:)",
        as: ((String) -> NativeSwiftOpaqueValue).self
    )
    return try NativeSwiftView(unsafe make.unsafeInvoke(title))
}
```

Use the result like any other SwiftUI view: place it in your hierarchy, apply ordinary modifiers, or pass it to UIHostingController or NSHostingView. The native provider's concrete view type and module need not be importable when compiling the consumer. The provider must already have an established View conformance and the native declaration must match the supplied ABI.

Copies of NativeSwiftView share an immutable owner. The original opaque result and call handle may be released after construction. The view keeps the opaque storage and implementation images alive and destroys its erased content while those owners remain retained.

Construction and body evaluation are MainActor-isolated. NativeSwiftView does not conform to Sendable, and arbitrary hidden native views retain their own thread and actor requirements. Retain the view or its host for the whole UI lifetime; code dependencies of values deliberately extracted from the original opaque result keep their original owner requirements.

If the opaque result does not conform to View, construction throws ABIInvocationError.incompatibleValue with the actual runtime type. The failed conversion does not consume or invalidate the original result.

## Supported integration paths

This product supplies the owned opaque-view wrapper. It does not install SwiftUI value layout conformances, synthesize generic function arguments, or call undocumented SwiftUI APIs. Compiled host adapters, explicit Text/Image/Color/AnyView layouts, and compiled generic specializations remain the paths described in the [SwiftUI interoperability guide](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftuiinteroperability).

State and view identity follow normal SwiftUI behavior. An Observable model captured by the native view continues to drive updates, and native callbacks can be retained by the view. Replacing the erased underlying type follows AnyView's standard hierarchy replacement semantics.

## Topics

### Owned native views

- ``NativeSwiftView``
