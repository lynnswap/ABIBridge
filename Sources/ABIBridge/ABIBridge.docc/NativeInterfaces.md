# C, C++, and Objective-C++ interfaces

Use the ABIBridge product from native consumer code through its documented public headers.

## Overview

Start with <doc:NativeInspection> for linking, header selection, symbol lookup, and image ownership. The invocation and hook guides below describe the native interfaces. Shared behavior for image loading, memory reads, pointer discovery, and imported or virtual hooks is documented alongside the Swift interfaces.

## Choose a header

Link the `ABIBridge` product and include the interface for your source language:

| Source language | Header |
| --- | --- |
| C or Objective-C | `<ABIBridge/ABIBridge.h>` |
| C++20 or Objective-C++ | `<ABIBridge/ABIBridge.hpp>` |
| Objective-C captured implementations | `<ABIBridge/ObjectiveCInvocation.h>` |
| Typed Objective-C++ captured implementations | `<ABIBridge/ObjectiveCInvocation.hpp>` |

The C umbrella includes `Inspection.h`, `Memory.h`, `PointerSearch.h`, `ValueTypes.h`, `PointerAuthentication.h`, `HookEffects.h`, `ObjectiveCOwnership.h`, `ObjectiveCHooks.h`, `ImportedHooks.h`, `ImportedHookMonitoring.h`, `VirtualEntries.h`, and `VirtualHooks.h`. Each is also available individually under `ABIBridge/`.

The C++ umbrella includes the corresponding inspection, memory, pointer search, function invocation, and hook wrappers. `ValueTypes.h` supplies the C layouts needed to prepare hooks; `HookEffects.h` preserves installation and rollback evidence, including incomplete protection restoration.

## Topics

### Symbols and images

- <doc:NativeInspection>

### Function and method calls

- <doc:NativeFunctionInvocation>
- <doc:NativeObjectiveCInvocation>

### Objective-C hooks

- <doc:NativeObjectiveCHooks>

## See Also

- <doc:SymbolsAndImages>
- <doc:ValuesAndMemory>
- <doc:HooksAndReplacements>
