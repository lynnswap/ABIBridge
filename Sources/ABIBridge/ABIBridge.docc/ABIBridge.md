# ``ABIBridge``

Resolve source-level native declarations in loaded Apple-platform images.

## Overview

Use ``ABIRuntime`` to locate C, C++, or Swift symbols without writing mangled names. A ``ResolvedSymbol`` keeps its containing image alive and provides scoped access to the raw address. Use ``NativeSwiftFunction`` for concrete Swift calls, ``NativeFunction`` for typed C and C-compatible C++ calls, or bind an existing Objective-C receiver with ``NativeObject`` to invoke selectors using ordinary Swift function types and values.

The Swift API requires Swift 6.3 or later and supports iOS 18.4, macOS 15.4, visionOS 2.4, watchOS 11.4, and tvOS 18.4 or later.

```swift
import ABIBridge

let symbol = try await ABIRuntime.shared.resolve(
    NativeDeclaration(name: "getpid", language: .c)
)
print(symbol.image.path)
```

## Topics

### Native inspection from C, C++, and Objective-C++

- <doc:NativeInspection>

### Resolving symbols

- <doc:SymbolLookup>
- ``ABIRuntime``
- ``ImageSelector``
- ``NativeDeclaration``
- ``NativeSymbolRequest``
- ``NativeLanguage``
- ``NativeSymbolKind``
- ``ResolvedSymbol``

### Calling C and C++ functions

- <doc:CFunctionInvocation>
- ``NativeFunction``

### Calling Objective-C methods

- <doc:ObjectiveCInvocation>
- ``NativeObject``
- ``NativeMethod``
- ``NativeMethodOptions``
- ``ABIInvocationError``

### Calling C++ object methods

- <doc:CXXObjectInvocation>
- ``NativeCXXObject``
- ``NativeCXXMethod``
- ``NativeVTable``
- ``NativePointerAuthentication``
- ``NativeDispatchError``

### Discovering referenced objects

- <doc:PointerDiscovery>
- ``NativePointerSearchOptions``
- ``NativePointerSearchPolicy``
- ``NativePointerSearchResult``
- ``NativePointerCandidate``
- ``NativePointerSearchFailure``
- ``NativePointerSearchError``
- ``NativePointerNormalization``

### Reading native memory

- <doc:NativeMemory>
- ``NativeMemoryRegion``
- ``NativeMemoryReadResult``
- ``NativeMemoryReadStatus``
- ``NativeMemoryError``

### Adapting native values

- <doc:NativeValueAdapters>
- ``ABIBridgeValue``
- ``NativeType``
- ``NativeValue``
- ``NativeSignature``
- ``DynamicNativeFunction``
- ``NativeValueError``

### Image lifetime

- ``NativeImage``
- ``NativeImageIdentity``

### Describing call contracts

- ``NativeCallPlan``
- ``NativeOwnership``

### Handling failures

- ``ABIResolutionError``

### Swift function invocation

- <doc:SwiftFunctionInvocation>
- ``NativeSwiftFunction``

### Swift types and members

- <doc:SwiftMemberInvocation>
- ``NativeSwiftType``
- ``NativeSwiftMethod``
- ``NativeBoundSwiftMethod``
- ``NativeSwiftWritebackError``
