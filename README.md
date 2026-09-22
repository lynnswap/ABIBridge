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

Find a C function in the process's loaded images:

```swift
import ABIBridge

let symbol = try await ABIRuntime.shared.resolve(
    NativeDeclaration(name: "getpid", language: .c)
)
print(symbol.image.path)
```

C++ and Swift declarations can also be resolved without mangled names. Native invocation is being developed separately.

See the [DocC catalog](Sources/ABIBridge/ABIBridge.docc/ABIBridge.md) for API contracts and [CONTRIBUTING.md](CONTRIBUTING.md) for build and test instructions.

## License

MIT License. Copyright (c) 2026 Kazuki Nakashima.
