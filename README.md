# ABIBridge

Resolve native symbols by source-level name and call C, C++, Objective-C, and concrete Swift functions with Swift types and values.

## Requirements

- iOS 18.4+, macOS 15.4+, visionOS 2.4+, watchOS 11.4+, or tvOS 18.4+
- Xcode on macOS with Swift 6.3+

## Installation

Add this Swift package dependency and the `ABIBridge` product to your target:

```swift
.package(url: "https://github.com/lynnswap/ABIBridge.git", branch: "main")
```

## Quick start

### Call a method on an existing Objective-C instance

For an existing `renderer` that exposes `setImage:animated:`, pass ordinary Swift values:

```swift
import ABIBridge
import UIKit

let runtime = ABIRuntime.shared
let object = runtime.object(renderer)
let setImage = try await object.method(
    selector: "setImage:animated:",
    as: ((UIImage?, Bool) -> Void).self
)

try unsafe setImage.unsafeInvoke(image, true)
try unsafe setImage.unsafeInvoke(nil, false)
```

Reuse the receiver handle for another selector, such as `refreshAnimated:` returning a Boolean:

```swift
let refresh = try await object.method(
    selector: "refreshAnimated:",
    as: ((Bool) -> Bool).self
)
let didRefresh = try unsafe refresh.unsafeInvoke(true)
```

### Call C and C++ functions with Swift types

```swift
let processID = try await runtime.cFunction(
    named: "getpid",
    as: (() -> Int32).self
)
let pid = try unsafe processID.unsafeInvoke()
```

For an already-loaded framework defining a C-compatible C++ function:

```swift
let add = try await runtime.cxxFunction(
    named: "Example::Math::add(int, int)",
    as: ((Int32, Int32) -> Int32).self,
    in: .framework(named: "Example")
)
let sum = try unsafe add.unsafeInvoke(20, 22)
```

### Call a concrete Swift function

For an already-loaded module defining `func decorate(_ value: String) -> String`:

```swift
let decorate = try await runtime.swiftFunction(
    named: "Example.decorate(_:)",
    as: ((String) -> String).self
)
let message = try unsafe decorate.unsafeInvoke("Hello")
```

### Call methods on a C++ object

Given native `storage` for a live C++ receiver:

```swift
let counter = runtime.cxxObject(storage, typeNamed: "Example::Counter")
let add = try await counter.method(
    named: "add(int)",
    as: ((Int32) -> Int32).self
)
let value = try unsafe add.unsafeInvoke(5)
```

### Use your own native value type

For a `Pair` wrapper conforming to `ABIBridgeValue` and a loaded C-compatible declaration:

```swift
let translate = try await runtime.cxxFunction(
    named: "Example::translate(Example::Pair)",
    as: ((Pair) -> Pair).self
)
let translated = try unsafe translate.unsafeInvoke(Pair(left: 2, right: 3))
```

Convert an existing `NativeValue` with `try nativeValue.cast(to: Pair.self)`. See the [native value adapter guide](https://lynnswap.github.io/ABIBridge/documentation/abibridge/nativevalueadapters) for layout and ownership declarations.

### Call a Swift method on an existing instance

For an existing `renderer` with a Swift `setImage(_:animated:)` method, bind the receiver once and pass ordinary Swift values:

```swift
import UIKit

let object = runtime.object(renderer)
let setImage = try await object.method(
    named: "setImage(_:animated:)",
    as: ((UIImage?, Bool) -> Void).self
)

try unsafe setImage.unsafeInvoke(image, true)
try unsafe setImage.unsafeInvoke(nil, false)
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

try unsafe start.unsafeInvoke(on: renderer)
try unsafe stop.unsafeInvoke(on: renderer)
```

### Initialize a Swift type and access its properties

For an already-loaded type defining `init(text:)` and a `text` property:

```swift
let initialize = try await rendererType.initializer(
    named: "init(text:)", as: ((String) -> AnyObject).self
)
let renderer = try unsafe initialize.unsafeInvoke("Hello")
let text = try await rendererType.getter(named: "text", as: String.self)
let value = try unsafe text.unsafeInvoke(on: renderer)
```

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

Use `.path(executableURL)` instead of `.framework(named:)` to select a particular loaded binary. Lookups do not load missing frameworks.

### Copy a bounded native memory region

Read current-process bytes and inspect incomplete reads without directly dereferencing the source:

```swift
let region = try NativeMemoryRegion(
    address: address, byteCount: allocationSize, retaining: owner
)
let result = try region.read(at: 0, byteCount: 16)
print(result.isComplete, result.bytes)
```

### Find references to a native object

Search a known region for references matching a target vtable address point:

```swift
let result = try region.pointers(toVTable: addressPoint)
if let candidate = result.uniqueCandidate {
    print(candidate.offset, candidate.addressForInspection)
}
```

### Inspect symbols from C++ or Objective-C++

For an already-loaded framework defining `Example::Renderer`:

```cpp
#include <ABIBridge/Inspection.hpp>

auto runtime = abi_bridge::Runtime::current();
auto table = runtime.resolve(
    {"vtable for Example::Renderer",
     abi_bridge::language::cxx, abi_bridge::symbol_kind::vtable},
    abi_bridge::image_selector::framework("Example")
);
auto image = table.image();
```

The C++20 handles manage native ownership automatically and share the Swift resolver backend.

### Inspect symbols from C

Use the same `ABIBridge` product and the public inspection header:

```c
#include <ABIBridge/Inspection.h>
#include <stdio.h>

ABISymbolRuntime *runtime = ABICopySharedSymbolRuntime();
ABIResolutionFailure *error = NULL;
ABIResolvedSymbol *symbol = ABIResolveSymbol(
    runtime, "getpid", ABILanguageC, ABISymbolFunction,
    ABIImageAutomatic, NULL, &error
);
if (symbol) {
    ABIImageInfo image;
    ABIResolvedSymbolImage(symbol, &image);
    printf("%s\n", image.path);
    ABIReleaseResolvedSymbol(symbol);
} else {
    fprintf(stderr, "%s\n", ABIResolutionFailureMessage(error));
    ABIReleaseResolutionFailure(error);
}
ABIReleaseSymbolRuntime(runtime);
```

See the [native inspection guide](https://lynnswap.github.io/ABIBridge/documentation/abibridge/nativeinspection) for ownership and search scopes.

See the [documentation](https://lynnswap.github.io/ABIBridge/documentation/abibridge/) for API contracts and [CONTRIBUTING.md](CONTRIBUTING.md) for build and test instructions.

## Acknowledgements

ABIBridge's symbol resolution relies on [MachOKit](https://github.com/p-x9/MachOKit) for reading Mach-O images and dyld shared caches. Its parsing support provides the foundation for this package. Objective-C type decoding uses [ObjCTypeDecodeKit](https://github.com/p-x9/swift-objc-dump).

Thank you to [p-x9](https://github.com/p-x9) and the contributors to [MachOKit](https://github.com/p-x9/MachOKit/graphs/contributors) and [swift-objc-dump](https://github.com/p-x9/swift-objc-dump/graphs/contributors) for building and sharing these libraries.

The internal C ABI call backend uses [libffi](https://github.com/libffi/libffi), packaged for SwiftPM by [ZDLibffi](https://github.com/faimin/ZDLibffi). Thank you to their authors and contributors.

## License

MIT License. Copyright (c) 2026 Kazuki Nakashima.
