# Values and memory

Describe native storage, adapt values, read memory, and discover referenced objects.

## Overview

Use <doc:NativeValueAdapters> when a call needs a custom foreign representation or a runtime-defined signature. Use <doc:NativeMemory> to read accessible bytes and <doc:PointerDiscovery> to find ARM64 code references or candidate object pointers in bounded storage. Swift-specific representations and ownership conventions are covered in <doc:SwiftValues>.

## Topics

### Value representations and storage

- <doc:NativeValueAdapters>
- ``ABIBridgeValue``
- ``NativeType``
- ``NativeValue``
- ``NativeSignature``
- ``DynamicNativeFunction``
- ``NativeValueError``

### Memory reads

- <doc:NativeMemory>
- ``NativeMemoryRegion``
- ``NativeMemoryReadResult``
- ``NativeMemoryReadStatus``
- ``NativeMemoryError``

### Pointer discovery

- <doc:PointerDiscovery>
- ``NativePointerSearchOptions``
- ``NativePointerSearchPolicy``
- ``NativePointerSearchResult``
- ``NativePointerCandidate``
- ``NativePointerSearchFailure``
- ``NativePointerSearchError``
- ``NativePointerNormalization``

### ARM64 code references

- ``NativeARM64Instruction``
- ``NativeARM64Reference``
- ``NativeARM64ReferenceResult``
- ``NativeARM64ReferenceError``

### Call contracts and errors

- ``ABIInvocationError``
