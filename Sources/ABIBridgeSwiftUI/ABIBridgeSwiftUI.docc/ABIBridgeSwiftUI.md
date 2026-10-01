# ``ABIBridgeSwiftUI``

Display native opaque SwiftUI results while retaining their values and implementation images.

## Overview

Use this optional product to place a native view in a SwiftUI hierarchy or a standard hosting controller. ``NativeSwiftView`` owns the opaque result and its implementation images. The provider's concrete view type and module need not be importable by the consumer.

Start with <doc:DisplayingNativeViews> for setup, a complete example, and ownership and isolation requirements. The core ABIBridge product remains available separately and does not depend on SwiftUI.

## Topics

### Essentials

- <doc:DisplayingNativeViews>

### Owned native views

- ``NativeSwiftView``
