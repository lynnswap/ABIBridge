# ABIBridge

Resolve native symbols by source-level name from Swift and C++. Invoke C/C++ functions with typed C++ handles.

## Requirements

- iOS 18.4+, macOS 15.4+, visionOS 2.4+, watchOS 11.4+, or tvOS 18.4+
- Xcode on macOS with Swift 6.3+ and C++20 support

## Installation

Add this Swift package dependency, then use the `ABIBridge` product for Swift or `ABIBridgeCore` for C++:

```swift
.package(url: "https://github.com/lynnswap/ABIBridge.git", branch: "main")
```

## Quick start

### Find a function without specifying its library

Search the process's loaded images:

```swift
import ABIBridge

let runtime = ABIRuntime.shared
let symbol = try await runtime.resolve(
    NativeDeclaration(name: "getpid", language: .c)
)
print(symbol.image.path)
```

### Resolve C++ and Swift declarations without mangled names

For an already-loaded framework named `Example` that defines these declarations:

```swift
let add = try await runtime.resolve(
    NativeDeclaration(name: "Example::Math::add(int, int)", language: .cxx),
    in: .framework(named: "Example")
)

let refresh = try await runtime.resolve(
    NativeDeclaration(name: "Example.Renderer.refresh() -> ()", language: .swift),
    in: .framework(named: "Example")
)
```

### Reuse an image for several lookups

Obtain an image once and reuse its cached index:

```swift
let images = try await runtime.images(
    matching: .framework(named: "Example")
)
if let image = images.first {
    let start = try await runtime.resolve(
        NativeDeclaration(name: "ExampleStart", language: .c), in: image
    )
    let stop = try await runtime.resolve(
        NativeDeclaration(name: "ExampleStop", language: .c), in: image
    )
}
```

Use `.path(executableURL)` instead of `.framework(named:)` to select a particular loaded binary. Lookups do not load missing frameworks. Swift typed invocation is being developed separately.

See the [documentation](https://lynnswap.github.io/ABIBridge/documentation/abibridge/) for API contracts and [CONTRIBUTING.md](CONTRIBUTING.md) for build and test instructions.

### Call a C++ function

For an already-loaded library defining `Example::Math::add(int, int)`:

```cpp
#include <ABIBridge/ABIBridge.hpp>

auto runtime = abi_bridge::Runtime::current();
auto add = runtime.cxx_function<int(int, int)>(
    abi_bridge::declaration("Example::Math::add(int, int)")
);

int result = add.unsafe_invoke(20, 22);
```

## Planned API

These examples preview APIs that are **not implemented yet** and may change. Typed invocation is tracked in [#4](https://github.com/lynnswap/ABIBridge/issues/4) and [#5](https://github.com/lynnswap/ABIBridge/issues/5).

### Call a method on an existing instance

For an existing `renderer` with a Swift `setImage(_:animated:)` method, bind the receiver once and pass ordinary Swift values:

```swift
import UIKit

let object = runtime.object(renderer)
let setImage = try await object.method(
    named: "setImage(_:animated:)",
    as: ((UIImage?, Bool) -> Void).self
)

try setImage.unsafeInvoke(image, true)
try setImage.unsafeInvoke(nil, false)
```

### Reuse a type for multiple methods

Resolve several methods through the same type handle, then select the receiver when calling them:

```swift
let rendererType = try await runtime.swiftType(named: "Example.Renderer")
let start = try await rendererType.method(
    named: "start()",
    as: (() -> Void).self
)
let stop = try await rendererType.method(
    named: "stop()",
    as: (() -> Void).self
)

try start.unsafeInvoke(on: renderer)
try stop.unsafeInvoke(on: renderer)
```

### Call C++ from Swift

Use a source-level declaration and a Swift function type:

```swift
let add = try await runtime.cxxFunction(
    named: "Example::Math::add(int, int)",
    as: ((Int32, Int32) -> Int32).self
)

let result = try add.unsafeInvoke(20, 22)
```

### Call an Objective-C selector from Objective-C++

Bind a selector to an existing `view`:

```objc++
#include <ABIBridge/ABIBridgeObjCXX.hpp>

auto setHidden = abi_bridge::objc_method<void(BOOL)>(
    view, @selector(setHidden:)
);
setHidden.unsafe_invoke(YES);
```

## Acknowledgements

ABIBridge's symbol resolution relies on [MachOKit](https://github.com/p-x9/MachOKit) for reading Mach-O images and dyld shared caches. Its parsing support provides the foundation for this package.

Thank you to [p-x9](https://github.com/p-x9) and the [MachOKit contributors](https://github.com/p-x9/MachOKit/graphs/contributors) for building and sharing that foundation.

## License

MIT License. Copyright (c) 2026 Kazuki Nakashima.
