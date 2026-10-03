# ABIBridge

Resolve mangled Swift and C++ symbols by source-level name, and call supported native functions and methods with ordinary Swift types and values.

## Requirements

- iOS 18.4+, macOS 15.4+, visionOS 2.4+, watchOS 11.4+, or tvOS 18.4+
- Xcode on macOS with Swift 6.3+

## Quick start

### Resolve a C++ function without writing its mangled name

For an already-loaded library defining `int Example::Math::add(int, int)`, a direct `dlsym` lookup with its loader handle requires the mangled name:

```swift
import Darwin

let address = dlsym(libraryHandle, "_ZN7Example4Math3addEii")
```

With ABIBridge, use the function's declaration name instead. The runtime finds the corresponding mangled symbol in loaded images automatically:

```swift
import ABIBridge

let runtime = ABIRuntime.shared
let symbol = try await runtime.resolve(
    NativeDeclaration(name: "Example::Math::add(int, int)", language: .cxx)
)
```

### Call C++ by its declaration

To call that function, provide its signature as a Swift function type. Specifying a framework acquires it when needed:

```swift
let add = try await runtime.cxxFunction(
    named: "Example::Math::add(int, int)", as: ((Int32, Int32) -> Int32).self,
    in: .framework(named: "Example")
)
let sum = try unsafe add.unsafeInvoke(20, 22)
```

### Call Swift by its source-level name

For an already-loaded module defining `func decorate(_ value: String) -> String`:

```swift
let decorate = try await runtime.swiftFunction(
    named: "Example.decorate(_:)", as: ((String) -> String).self
)
let message = try unsafe decorate.unsafeInvoke("Hello")
```

Generic declarations use the same callable handles with explicit type arguments:

```swift
let echo = try await runtime.swiftFunction(
    named: "Example.echo<A>(A) -> A", as: ((String) -> String).self,
    genericArguments: [.type(String.self)]
)
let message = try unsafe echo.unsafeInvoke("Hello")
```

See [Swift generic calls](https://lynnswap.github.io/ABIBridge/documentation/abibridge/genericswiftvalues) for constraints, packs, generic types, and members. Ordinary tuples can combine runtime value handles and closures. Use `NativeSwiftInout` to replace a closure or tuple through a native call; see [Swift closure values](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftclosurevalues) and [argument conventions](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftargumentconventions).

### Call an existing Objective-C instance

For a `renderer` exposing `setImage:animated:`, pass ordinary Swift values:

```swift
import UIKit

let setImage = try runtime.object(renderer).method(
    selector: "setImage:animated:",
    as: ((UIImage?, Bool) -> Void).self
)
try unsafe setImage.unsafeInvoke(image, true)
try unsafe setImage.unsafeInvoke(nil, false)
```

### Display a native SwiftUI view

For a nongeneric factory returning `some View`, add the optional `ABIBridgeSwiftUI` product and use its owned wrapper on `MainActor`:

```swift
import ABIBridgeSwiftUI

let makePanel = try await runtime.swiftFunction(
    named: "Example.makePanel(_:)", as: ((String) -> NativeSwiftValue).self
)
let panel = try NativeSwiftView(unsafe makePanel.unsafeInvoke("Hello"))
```

Place `panel` in your SwiftUI hierarchy or a standard hosting controller. It retains the hidden view and its implementation images; the provider module does not need to be importable. The core `ABIBridge` product remains independent of SwiftUI.

## Documentation

More examples and API contracts are available in [DocC](https://lynnswap.github.io/ABIBridge/documentation/abibridge/):

- [C and C++ functions](https://lynnswap.github.io/ABIBridge/documentation/abibridge/cfunctioninvocation) and [C++ object methods](https://lynnswap.github.io/ABIBridge/documentation/abibridge/cxxobjectinvocation)
- [Swift types and members](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftmemberinvocation) and [custom value adapters](https://lynnswap.github.io/ABIBridge/documentation/abibridge/nativevalueadapters)
- [SwiftUI hosting, concrete values, and opaque views](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftuiinteroperability)
- [Symbol lookup](https://lynnswap.github.io/ABIBridge/documentation/abibridge/symbollookup) and [C/C++/Objective-C++ interfaces](https://lynnswap.github.io/ABIBridge/documentation/abibridge/nativeinspection)
- [Memory reads](https://lynnswap.github.io/ABIBridge/documentation/abibridge/nativememory) and [pointer discovery](https://lynnswap.github.io/ABIBridge/documentation/abibridge/pointerdiscovery)

For build and test instructions, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Acknowledgements

ABIBridge's symbol resolution relies on [MachOKit](https://github.com/p-x9/MachOKit) for reading Mach-O images and dyld shared caches. Its parsing support provides the foundation for this package. Objective-C type decoding uses [ObjCTypeDecodeKit](https://github.com/p-x9/swift-objc-dump).

Thank you to [p-x9](https://github.com/p-x9) and the contributors to [MachOKit](https://github.com/p-x9/MachOKit/graphs/contributors) and [swift-objc-dump](https://github.com/p-x9/swift-objc-dump/graphs/contributors) for building and sharing these libraries.

The internal C ABI call backend uses [libffi](https://github.com/libffi/libffi), packaged for SwiftPM by [ZDLibffi](https://github.com/faimin/ZDLibffi). ABIBridge uses [a fork](https://github.com/lynnswap/ZDLibffi) with arm64e authentication fixes. Thank you to the original authors and contributors.

## License

MIT License. Copyright (c) 2026 Kazuki Nakashima.
