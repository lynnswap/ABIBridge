# ABIBridge

A native ABI bridge for Apple platforms, with Swift, C++, and Objective-C++ interfaces.

## Requirements

- iOS 18.4+, macOS 15.4+, visionOS 2.4+, watchOS 11.4+, or tvOS 18.4+
- Xcode on macOS with Swift 6.3+ and C++20 support

## Current capabilities

Resolve C, C++, and Swift symbols in loaded images using source-level declarations. Lookups share image and declaration indexes, and returned handles retain their images. Typed native invocation is planned separately.

| Product | Interface |
| --- | --- |
| `ABIBridge` | Swift symbol lookup and model types |
| `ABIBridgeCore` | Native image catalog, loader leases, and C++ model types |
| `ABIBridgeObjCXX` | Objective-C++ bridge target |

These models describe caller-provided contracts. Constructing a model does not validate a native address, keep an image or object alive, or prove that an ABI is compatible.

## Symbol lookup

```swift
import ABIBridge

let symbol = try await ABIRuntime.shared.resolve(
    NativeDeclaration(name: "Example::Math::add(int, int)", language: .cxx)
)
```

Use `in: .framework(named: "Example")` or `in: .path(url)` to narrow a lookup, or reuse a `NativeImage` returned by `images(matching:)`. These operations inspect loaded images and do not load a missing framework.

Loaded-image definitions take precedence over shared-cache local symbols. Cache-file lookup is best effort and requires matching image/cache UUIDs; symbol metadata may be unavailable on a particular OS. Distinct definitions at the same lookup level report ambiguity. Executable/data storage is checked independently of the caller's ABI contract.

`ResolvedSymbol.withUnsafeAddress` borrows an address while retaining its image. The address must not escape that closure. Calling it or interpreting its contents requires the correct calling convention, object layout, and argument lifetimes. Function-pointer authentication is not performed by this raw-address API.

`removeCachedResults()` releases indexes; existing handles keep their images alive. The native catalog uses process-lifetime dyld observers and pins the image containing those observers so their callbacks remain valid.

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
