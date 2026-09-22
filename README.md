# ABIBridge

A native ABI bridge for Apple platforms, with Swift, C++, and Objective-C++ interfaces.

## Requirements

- iOS 18.4+, macOS 15.4+, visionOS 2.4+, watchOS 11.4+, or tvOS 18.4+
- Xcode on macOS with Swift 6.3+ and C++20 support

## Current capabilities

This initial package provides native declaration, image identity, ownership, and call-plan model types. Symbol lookup and invocation are planned and are not yet implemented.

| Product | Interface |
| --- | --- |
| `ABIBridge` | Swift model types |
| `ABIBridgeCore` | C++ model types in `abi_bridge` |
| `ABIBridgeObjCXX` | Objective-C++ bridge target |

These models describe caller-provided contracts. Constructing a model does not validate a native address, keep an image or object alive, or prove that an ABI is compatible.

## Validation

CI runs macOS tests and generic iOS, visionOS, watchOS, and tvOS builds using Xcode 26.6 on the `macos-26` runner for pull requests and pushes to `main`.

Run package tests on macOS:

```sh
xcodebuild test \
  -scheme ABIBridge-Package \
  -destination 'platform=macOS,arch=arm64'
```

Build for each Apple platform with the corresponding generic destination. A successful build establishes SDK compatibility; native invocation behavior will need its own runtime tests as those features are added.

## License

MIT License. Copyright (c) 2026 Kazuki Nakashima.
