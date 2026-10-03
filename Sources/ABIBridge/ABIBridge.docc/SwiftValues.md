# Swift values and callbacks

Choose Swift value representations, parameter ownership, and closure conventions.

## Overview

Use the native declaration's calling convention to select a representation. Built-in values are described in <doc:SwiftFunctionInvocation>; the guides below cover explicit layouts, compiled adapters, generic substitutions, and values whose concrete type is unavailable to the consumer.

## Topics

### Parameter conventions

- <doc:SwiftArgumentConventions>
- ``NativeSwiftInout``
- ``NativeSwiftBorrowing``
- ``NativeSwiftConsuming``

### Closures

- <doc:SwiftClosureValues>
- ``NativeSwiftClosure``

### Custom and generic values

- <doc:ExplicitSwiftValues>
- ``ABIBridgeSwiftValue``
- <doc:ManagedSwiftValues>
- <doc:GenericSwiftValues>

### Existentials and opaque results

- <doc:SwiftExistentialValues>
- <doc:SwiftOpaqueResults>
- ``NativeSwiftValue``

### Borrowed runtime values

- <doc:BorrowedSwiftValues>
- ``NativeSwiftBorrowedValue``
- ``NativeSwiftBorrowingClosure``
- ``NativeSwiftBorrowError``

## See Also

- <doc:ValuesAndMemory>
