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
let symbol = try runtime.resolve(
    NativeDeclaration(name: "Example::Math::add(int, int)", language: .cxx)
)
```

Lookup is synchronous and prepares the required image and symbol indexes automatically. No preparation-completion flag is needed. Optional asynchronous `prepare(_:)` runs work on a worker queue; a lookup that arrives during preparation joins the work it needs. A synchronous lookup can block its caller, including `MainActor`, until that work finishes. See [symbol lookup](https://lynnswap.github.io/ABIBridge/documentation/abibridge/symbollookup) for examples.

### Call C++ by its declaration

To call that function, provide its signature as a Swift function type. Specifying a framework acquires it when needed:

```swift
let add = try runtime.cxxFunction(
    named: "Example::Math::add(int, int)", as: ((Int32, Int32) -> Int32).self,
    in: .framework(named: "Example")
)
let sum = try unsafe add.unsafeInvoke(20, 22)
```

Retain the returned handle for repeated calls. Creating the handle and calling a synchronous native function are both synchronous. Invocation follows the function's thread-affinity contract.

### Call Swift by its source-level name

For an already-loaded module defining `func decorate(_ value: String) -> String`:

```swift
let decorate = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.decorate(_:)", as: ((String) -> String).self
)
let message = try unsafe decorate.unsafeInvoke("Hello")
```

Use `resolveSwiftFunction` to search and prepare on a worker queue without blocking `MainActor`. No explicit `prepare` call is needed:

```swift
@MainActor
func makeMessage() async throws -> String {
    let decorate = try await ABIRuntime.shared.resolveSwiftFunction(
        named: "Example.decorate(_:)", as: ((String) -> String).self
    )
    return try unsafe decorate.unsafeInvoke("Hello")
}
```

Choose `resolveSwiftFunctionAndWait` for synchronous lookup, including inside an async function. The native signature determines whether invocation itself needs `await`. See [Swift function calls](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftfunctioninvocation) for both forms.

Generic declarations use the same callable handles with explicit type arguments:

```swift
let echo = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.echo(_:)", as: ((String) -> String).self,
    genericArguments: [.type(String.self)]
)
let message = try unsafe echo.unsafeInvoke("Hello")
```

See [Swift generic calls](https://lynnswap.github.io/ABIBridge/documentation/abibridge/genericswiftvalues) for constraints, packs, generic types, and members. Ordinary tuples can combine runtime value handles and closures. Use `NativeSwiftInout` to replace a closure or tuple through a native call; see [Swift closure values](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftclosurevalues) and [argument conventions](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftargumentconventions).

### Resolve a Swift type and its members without blocking MainActor

Swift types and members use async `resolve` factories, including initializers, instance and static methods, getters, and setters. Their `AndWait` variants select synchronous lookup explicitly. For a native renderer with `func title() -> String`:

```swift
@MainActor
func readTitle(from renderer: AnyObject) async throws -> String {
    let type = try await ABIRuntime.shared.resolveSwiftType(named: "Example.Renderer")
    let title = try await type.resolveMethod(named: "title()", as: (() -> String).self)
    return try unsafe title.unsafeInvoke(on: renderer)
}
```

Awaited lookup suspends while a worker performs the required search and preparation. Bound object lookup keeps the receiver in the caller's isolation domain. `ABIRuntime` and `NativeSwiftType` remain actors. See [Swift types and members](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftmemberinvocation) for construction, property access, and optional preparation started ahead of time.

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

For a native factory returning `some View`, add the optional `ABIBridgeSwiftUI` product and use its owned wrapper on `MainActor`:

```swift
import ABIBridgeSwiftUI

let makePanel = try runtime.resolveSwiftFunctionAndWait(
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
