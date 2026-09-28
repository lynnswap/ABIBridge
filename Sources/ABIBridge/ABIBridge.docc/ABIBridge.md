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

### Editing and inspecting hook calls

- <doc:HookArguments>

### Hooking imported functions

- <doc:ImportedFunctionHooks>
- <doc:SwiftFunctionHooks>
- <doc:SwiftImportedReplacements>
- ``NativeSwiftImportedFunctionHook``
- ``NativeSwiftFunctionInvocation``
- ``NativeSwiftHookInstallationError``
- ``NativeSwiftHookInvocationError``
- ``NativeImportedFunctionHook``
- ``NativeImportedFunctionMonitor``
- ``NativeImportedImageUpdate``
- ``NativeImportedFunctionInvocation``
- ``NativeImportedHookInstallationError``
- ``NativeImportedInvocationError``

### Hooking Swift methods

- <doc:SwiftMethodHooks>
- ``NativeSwiftMethodInvocation``
- ``NativeSwiftVirtualHook``
- ``NativeSwiftVirtualHookInstallationError``

### Replacing compiled Swift virtual methods

- <doc:SwiftVirtualReplacements>
- ``NativeSwiftVirtualReplacement``

### Native inspection from C, C++, and Objective-C++

- <doc:NativeInspection>

### Resolving symbols

- <doc:SymbolLookup>
- ``ABIRuntime``
- ``ImageSelector``
- ``NativeDeclaration``
- ``NativeSymbolRequest``
- ``NativeSymbolNameForm``
- ``NativeLanguage``
- ``NativeSymbolKind``
- ``ResolvedSymbol``

### Calling C and C++ functions

- <doc:CFunctionInvocation>
- <doc:NativeFunctionInvocation>
- ``NativeFunction``

### Calling Objective-C methods and reading ivars

- <doc:ObjectiveCInvocation>
- <doc:NativeObjectiveCInvocation>
- ``NativeObject``
- ``NativeMethod``
- ``NativeObjCImplementation``
- ``NativeMethodOptions``
- ``ABIInvocationError``

### Hooking Objective-C methods

- <doc:ObjectiveCMethodHooks>
- <doc:ObjectiveCInitializerHooks>
- <doc:NativeObjectiveCHooks>
- <doc:CoordinatedObjectiveCHooks>
- ``NativeObjCHookRequest``
- ``NativeObjCHookInstallationError``
- ``NativeObjCMethodHook``
- ``NativeObjCMethodInvocation``
- ``NativeObjCMethodHookError``

### Calling C++ object methods

- <doc:CXXObjectInvocation>
- ``NativeCXXObject``
- ``NativeCXXMethod``
- ``NativeVTable``
- ``NativeVTable/Entry``
- ``NativePointerAuthentication``
- ``NativeDispatchError``

### Hooking shared C++ virtual entries

- <doc:CXXVirtualHooks>
- ``NativeVirtualHook``
- ``NativeVirtualInvocation``
- ``NativeVirtualHookInstallationError``
- ``NativeVirtualInvocationError``

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

- <doc:ImageLoading>
- ``ImageLoadingPolicy``
- ``NativeImage``
- ``NativeImageIdentity``

### Lazy-load diagnostics

- <doc:LazyLibraries>
- ``NativeLazyLibrary``
- ``NativeLazySymbol``

### Describing call contracts

- <doc:Architectures>
- ``NativeCallPlan``
- ``NativeOwnership``

### Handling failures

- ``ABIResolutionError``

### Swift function invocation

- <doc:SwiftFunctionInvocation>
- <doc:SwiftErrorABI>
- <doc:SwiftAsyncABI>
- <doc:ManagedSwiftValues>
- <doc:ExplicitSwiftValues>
- ``ABIBridgeSwiftValue``
- <doc:GenericSwiftValues>
- <doc:SwiftClosureValues>
- ``NativeSwiftClosure``
- ``NativeSwiftFunction``
- ``NativeSwiftAsyncFunction``
- ``NativeSwiftError``

### Swift types and members

- <doc:SwiftMemberInvocation>
- ``NativeSwiftType``
- ``NativeSwiftMethod``
- ``NativeSwiftAsyncMethod``
- ``NativeBoundSwiftAsyncMethod``
- ``NativeBoundSwiftMethod``
- ``NativeSwiftWritebackError``
