# ABIBridge

Resolve mangled Swift and C++ symbols by source-level name, and call supported native functions and methods with ordinary Swift types and values.

## Requirements

- iOS 18.4+, macOS 15.4+, visionOS 2.4+, watchOS 11.4+, or tvOS 18.4+
- Xcode on macOS with Swift 6.3+

In Xcode, add `https://github.com/lynnswap/ABIBridge` as a package dependency and select the `ABIBridge` product. Add `ABIBridgeSwiftUI` if you need to display native SwiftUI views.

## Quick start

### Resolve a C++ function without writing its mangled name

For an already-loaded library defining `int Example::Math::add(int, int)`, a direct `dlsym` lookup with its loader handle requires the mangled name:

```swift
import Darwin

let address = dlsym(libraryHandle, "_ZN7Example4Math3addEii")
```

ABIBridge finds the mangled symbol from its declaration name:

```swift
import ABIBridge

let runtime = ABIRuntime.shared
let symbol = try runtime.resolveAndWait(
    NativeDeclaration(name: "Example::Math::add(int, int)", language: .cxx)
)
```

Lookup prepares the required indexes automatically. `resolveAndWait` can block its caller, including `MainActor`; use `try await runtime.resolve(...)` to perform lookup on a worker queue. Both forms work without `prepare`. See [symbol lookup](https://lynnswap.github.io/ABIBridge/documentation/abibridge/symbollookup) for scopes and optional preparation.

### Call C++ by its declaration

To call that function, provide its signature as a Swift function type. Specifying a framework acquires it when needed:

```swift
let add = try runtime.resolveCXXFunctionAndWait(
    named: "Example::Math::add(int, int)", as: ((Int32, Int32) -> Int32).self,
    in: .framework(named: "Example")
)
let sum = try unsafe add.unsafeInvoke(20, 22)
```

Retain the handle for repeated calls, and invoke it on the thread required by the native function. For lookup from `MainActor`, await `resolveCXXFunction`:

```swift
@MainActor
func calculate() async throws -> Int32 {
    let add = try await ABIRuntime.shared.resolveCXXFunction(
        named: "Example::Math::add(int, int)", as: ((Int32, Int32) -> Int32).self,
        in: .framework(named: "Example")
    )
    return try unsafe add.unsafeInvoke(20, 22)
}
```

Search, image acquisition, and call preparation run on a worker while the caller suspends. `resolveCFunction` provides the same async lookup for C declarations. Optional earlier `prepare` shares its work with either lookup form; callers join only the preparation they need.

### Call Swift by its source-level name

For an already-loaded module defining `func decorate(_ value: String) -> String`:

```swift
let decorate = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.decorate(_:)", as: ((String) -> String).self
)
let message = try unsafe decorate.unsafeInvoke("Hello")
```

Use `resolveSwiftFunction` for lookup on a worker queue while the caller suspends:

```swift
@MainActor
func makeMessage() async throws -> String {
    let decorate = try await ABIRuntime.shared.resolveSwiftFunction(
        named: "Example.decorate(_:)", as: ((String) -> String).self
    )
    return try unsafe decorate.unsafeInvoke("Hello")
}
```

The `AndWait` variant selects synchronous lookup. Invocation needs `await` only when the native signature is async; see [Swift function calls](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftfunctioninvocation).

Generic declarations use the same callable handles with explicit type arguments:

```swift
let echo = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.echo(_:)", as: ((String) -> String).self,
    genericArguments: [.type(String.self)]
)
let message = try unsafe echo.unsafeInvoke("Hello")
```

See [Swift generic calls](https://lynnswap.github.io/ABIBridge/documentation/abibridge/genericswiftvalues) for constraints, packs, and generic members. [Swift closure values](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftclosurevalues) covers closures in tuples; [argument conventions](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftargumentconventions) covers replacing values through `NativeSwiftInout`.

### Resolve a Swift type and its members without blocking MainActor

Swift type and member lookup follows the same async/`AndWait` naming. For a native renderer with `func title() -> String`:

```swift
@MainActor
func readTitle(from renderer: AnyObject) async throws -> String {
    let type = try await ABIRuntime.shared.resolveSwiftType(named: "Example.Renderer")
    let title = try await type.resolveMethod(named: "title()", as: (() -> String).self)
    return try unsafe title.unsafeInvoke(on: renderer)
}
```

Bound object lookup keeps the receiver in the caller's isolation domain. See [Swift types and members](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftmemberinvocation) for initializers, static methods, and properties.

### Call an existing Objective-C instance

For a `renderer` exposing `setImage:animated:`, pass ordinary Swift values:

```swift
import UIKit

let setImage = try runtime.object(renderer).resolveMethodAndWait(
    selector: "setImage:animated:",
    as: ((UIImage?, Bool) -> Void).self
)
try unsafe setImage.unsafeInvoke(image, true)
try unsafe setImage.unsafeInvoke(nil, false)
```

Await `resolveMethod(selector:as:)` to prepare the image and call signature on a worker. Receiver-specific dynamic resolution and forwarding-signature callbacks remain in the caller's isolation domain. Invoke the returned handle on the thread required by the receiver.

### Display a native SwiftUI view

For a native factory returning `some View`, add the optional `ABIBridgeSwiftUI` product and use its owned wrapper on `MainActor`:

```swift
import ABIBridgeSwiftUI

let makePanel = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.makePanel(_:)", as: ((String) -> NativeSwiftValue).self
)
let panel = try NativeSwiftView(unsafe makePanel.unsafeInvoke("Hello"))
```

Place `panel` in your SwiftUI hierarchy or a standard hosting controller. It retains the hidden view and its implementation images, even when the provider module is not importable.

## Documentation

More examples and API contracts are available in [DocC](https://lynnswap.github.io/ABIBridge/documentation/abibridge/):

- [C and C++ functions](https://lynnswap.github.io/ABIBridge/documentation/abibridge/cfunctioninvocation) and [C++ object methods](https://lynnswap.github.io/ABIBridge/documentation/abibridge/cxxobjectinvocation)
- [Swift types and members](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftmemberinvocation) and [custom value adapters](https://lynnswap.github.io/ABIBridge/documentation/abibridge/nativevalueadapters)
- [SwiftUI hosting, concrete values, and opaque views](https://lynnswap.github.io/ABIBridge/documentation/abibridge/swiftuiinteroperability)
- [Symbol lookup](https://lynnswap.github.io/ABIBridge/documentation/abibridge/symbollookup) and [C/C++/Objective-C++ interfaces](https://lynnswap.github.io/ABIBridge/documentation/abibridge/nativeinspection)
- [Memory reads](https://lynnswap.github.io/ABIBridge/documentation/abibridge/nativememory) and [pointer discovery](https://lynnswap.github.io/ABIBridge/documentation/abibridge/pointerdiscovery)

For build and test instructions, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Acknowledgements

Symbol resolution uses [MachOKit](https://github.com/p-x9/MachOKit) to read Mach-O images and dyld shared caches. Objective-C type decoding uses [ObjCTypeDecodeKit](https://github.com/p-x9/swift-objc-dump). Thank you to [p-x9](https://github.com/p-x9) and the contributors to [MachOKit](https://github.com/p-x9/MachOKit/graphs/contributors) and [swift-objc-dump](https://github.com/p-x9/swift-objc-dump/graphs/contributors).

The C ABI backend uses [libffi](https://github.com/libffi/libffi), packaged for SwiftPM by [ZDLibffi](https://github.com/faimin/ZDLibffi). ABIBridge uses [a fork](https://github.com/lynnswap/ZDLibffi) with arm64e authentication fixes. Thank you to their authors and contributors.

## License

MIT License. Copyright (c) 2026 Kazuki Nakashima.
