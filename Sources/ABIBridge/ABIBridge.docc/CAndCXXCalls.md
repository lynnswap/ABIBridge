# C and C++ calls

Invoke C functions and C-compatible C++ functions and object methods from Swift.

## Overview

Use a Swift function type to describe the native signature, then prepare a function or bind a C++ receiver. Start with <doc:CFunctionInvocation> for free functions and <doc:CXXObjectInvocation> for direct or virtual member calls.

## Topics

### Functions

- <doc:CFunctionInvocation>
- ``NativeFunction``

### Object methods

- <doc:CXXObjectInvocation>
- ``NativeCXXObject``
- ``NativeCXXMethod``
- ``NativeBoundCXXMethod``
- ``NativeVTable``
- ``NativeVTable/Entry``
- ``NativePointerAuthentication``
- ``NativeDispatchError``

## See Also

- <doc:ValuesAndMemory>
- <doc:HooksAndReplacements>
- <doc:NativeInterfaces>
