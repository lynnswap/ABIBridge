# Hooks and replacements

Intercept imported functions and method dispatch, inspect calls, and manage hook lifetime.

## Overview

Choose the dispatch path you need to intercept: imported function references, Objective-C method tables, or shared virtual entries. Start with the corresponding guide for installation, continuation, failure handling, and invalidation; use <doc:HookArguments> when editing or inspecting a callback's arguments.

## Topics

### Call arguments

- <doc:HookArguments>

### Imported C and C++ functions

- <doc:ImportedFunctionHooks>
- ``NativeImportedFunctionHook``
- ``NativeImportedFunctionMonitor``
- ``NativeImportedImageUpdate``
- ``NativeImportedFunctionInvocation``
- ``NativeImportedHookInstallationError``
- ``NativeImportedInvocationError``

### Imported Swift functions

- <doc:SwiftFunctionHooks>
- ``NativeSwiftImportedFunctionHook``
- ``NativeSwiftFunctionInvocation``
- ``NativeSwiftHookInstallationError``
- ``NativeSwiftHookInvocationError``

### Objective-C methods and initializers

- <doc:ObjectiveCMethodHooks>
- <doc:ObjectiveCInitializerHooks>
- <doc:CoordinatedObjectiveCHooks>
- ``NativeObjCHookRequest``
- ``NativeObjCHookInstallationError``
- ``NativeObjCMethodHook``
- ``NativeObjCMethodInvocation``
- ``NativeObjCMethodHookError``

### Swift methods

- <doc:SwiftMethodHooks>
- ``NativeSwiftMethodInvocation``
- ``NativeSwiftVirtualHook``
- ``NativeSwiftVirtualHookInstallationError``

### C++ virtual methods

- <doc:CXXVirtualHooks>
- ``NativeVirtualHook``
- ``NativeVirtualInvocation``
- ``NativeVirtualHookInstallationError``
- ``NativeVirtualInvocationError``

### Compiled Swift replacements

- <doc:SwiftImportedReplacements>
- <doc:SwiftVirtualReplacements>
- ``NativeSwiftImportedReplacement``
- ``NativeSwiftVirtualReplacement``
- ``NativeSwiftFunctionImplementation``
- ``NativeSwiftMethodImplementation``
- ``NativeSwiftReplacementMutation``
- ``NativeSwiftReplacementError``

## See Also

- <doc:NativeInterfaces>
