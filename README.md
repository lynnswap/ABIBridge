# ABIBridge

Resolve native declarations by source-level name and call Swift, Objective-C, C, and C++ code with Swift types and values.

## Installation

Add `https://github.com/lynnswap/ABIBridge` as a Swift package dependency and select the `ABIBridge` product. Add `ABIBridgeSwiftUI` to display native SwiftUI views.

Requirements:

- Xcode with Swift 6.3+
- iOS 18.4+, macOS 15.4+, visionOS 2.4+, watchOS 11.4+, or tvOS 18.4+
- arm64, arm64e, or arm64_32

## Quick start

For a loaded module defining `func decorate(_ value: String) -> String`:

```swift
import ABIBridge

let decorate = try await ABIRuntime.shared.resolve(.swift(.function(
    "Example.decorate(_:)", as: ((String) -> String).self
)))
let message = try unsafe decorate.unsafeInvoke("Hello")
```

Use `.objc(...)`, `.c(...)`, or `.cxx(...)` for other languages. Keep the returned handle for repeated calls and invoke it on the thread required by the native API. Use `resolveAndWait` for synchronous lookup.

## Documentation

[API reference and guides](https://lynnswap.github.io/ABIBridge/documentation/abibridge/):

- [Swift functions](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftfunctioninvocation) and [type members](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftmemberinvocation)
- [Objective-C methods and IMPs](https://lynnswap.github.io/ABIBridge/documentation/abibridge/objectivecinvocation)
- [C and C++ functions](https://lynnswap.github.io/ABIBridge/documentation/abibridge/cfunctioninvocation) and [C++ object methods](https://lynnswap.github.io/ABIBridge/documentation/abibridge/cxxobjectinvocation)
- [Native SwiftUI views](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftuiinteroperability)
- [Symbol lookup](https://lynnswap.github.io/ABIBridge/documentation/abibridge/symbollookup), [values and memory](https://lynnswap.github.io/ABIBridge/documentation/abibridge/valuesandmemory), and [hooks](https://lynnswap.github.io/ABIBridge/documentation/abibridge/hooksandreplacements)
- [C, C++, and Objective-C++ interfaces](https://lynnswap.github.io/ABIBridge/documentation/abibridge/nativeinspection)
- [Migrating from earlier APIs](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftapimigration)

See [CONTRIBUTING.md](CONTRIBUTING.md) for build and test instructions.

## Acknowledgements

Symbol resolution uses [MachOKit](https://github.com/p-x9/MachOKit) to read Mach-O images and dyld shared caches. Objective-C type decoding uses [ObjCTypeDecodeKit](https://github.com/p-x9/swift-objc-dump). Thank you to [p-x9](https://github.com/p-x9) and the contributors to [MachOKit](https://github.com/p-x9/MachOKit/graphs/contributors) and [swift-objc-dump](https://github.com/p-x9/swift-objc-dump/graphs/contributors).

The C ABI backend uses [libffi](https://github.com/libffi/libffi), packaged for SwiftPM by [ZDLibffi](https://github.com/faimin/ZDLibffi). ABIBridge uses [a fork](https://github.com/lynnswap/ZDLibffi) with arm64e authentication fixes. Thank you to their authors and contributors.

## License

MIT License. Copyright (c) 2026 Kazuki Nakashima.
