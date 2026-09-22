# ABIBridge

Resolve native symbols by source-level name from Swift, with a C++ and Objective-C++ foundation.

## Requirements

- iOS 18.4+, macOS 15.4+, visionOS 2.4+, watchOS 11.4+, or tvOS 18.4+
- Xcode on macOS with Swift 6.3+ and C++20 support

## Installation

Add this Swift package dependency and the `ABIBridge` product to your target:

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

Use `.path(executableURL)` instead of `.framework(named:)` to select a particular loaded binary. Lookups do not load missing frameworks. Typed native invocation is being developed separately.

See the [DocC catalog](Sources/ABIBridge/ABIBridge.docc/ABIBridge.md) for API contracts and [CONTRIBUTING.md](CONTRIBUTING.md) for build and test instructions.

## License

MIT License. Copyright (c) 2026 Kazuki Nakashima.
