# ``ABIBridge``

Resolve source-level native declarations in loaded Apple-platform images.

## Overview

Use ``ABIRuntime`` to locate C, C++, or Swift symbols without writing mangled names. A ``ResolvedSymbol`` keeps its containing image alive and provides scoped access to the raw address. Typed invocation is a separate capability and is not yet implemented.

The Swift API requires Swift 6.3 or later and supports iOS 18.4, macOS 15.4, visionOS 2.4, watchOS 11.4, and tvOS 18.4 or later.

```swift
import ABIBridge

let symbol = try await ABIRuntime.shared.resolve(
    NativeDeclaration(name: "getpid", language: .c)
)
print(symbol.image.path)
```

## Topics

### Resolving symbols

- <doc:SymbolLookup>
- ``ABIRuntime``
- ``ImageSelector``
- ``NativeDeclaration``
- ``NativeLanguage``
- ``NativeSymbolKind``
- ``ResolvedSymbol``

### Image lifetime

- ``NativeImage``
- ``NativeImageIdentity``

### Describing call contracts

- ``NativeCallPlan``
- ``NativeOwnership``

### Handling failures

- ``ABIResolutionError``
