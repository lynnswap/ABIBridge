# Reading native memory

Copy an explicitly bounded current-process range without directly dereferencing speculative addresses.

## Read a region

A ``NativeMemoryRegion`` describes an address, extent, and optional owner. Unlike ``NativeValue``, it does not assume the address is readable. The region keeps its owner alive; its read result owns only copied bytes.

```swift
let region = try NativeMemoryRegion(
    address: address, byteCount: allocationSize, retaining: owner
)
let result = try region.read(at: 0, byteCount: 16)
if result.isComplete {
    print(result.bytes)
} else {
    print(result.bytes.count, result.systemErrorCode)
}
```

The caller obtains the allocation bounds and supplies any synchronization. Retaining an owner does not prevent that owner from moving or explicitly releasing its storage. Memory can change between page reads, so even a complete result is not an atomic snapshot.

## Handle incomplete reads

Reads use the current process's Mach task and stop at the first unsuccessful page chunk. A complete read includes every requested byte. A partial read includes only the successfully copied prefix; a failed read has no copied bytes. The original Mach error is preserved in ``NativeMemoryReadResult/systemErrorCode``. Zero indicates no OS error, including a short successful OS read.

A zero-length range succeeds without accessing memory. Negative extents, address overflow, and subranges beyond the declared bounds throw ``NativeMemoryError`` before any access. The C API reports invalid ranges in its status instead.

A readable byte sequence is not evidence of a live object or correct native type. Copied pointer bits do not retain their pointees or authenticate a signed pointer. Converting them into borrowed receivers still requires the caller's layout, ownership, and dispatch guarantees.

## Read from C, C++, or Objective-C++

The public inspection headers include the memory APIs. The same implementation services every language.

```cpp
#include <ABIBridge/Inspection.hpp>

abi_bridge::memory_region region(address, allocationSize, owner);
auto result = region.read(0, 16);
if (!result.is_complete()) {
    // result.bytes contains only the copied prefix.
}
```

The optional C++ owner is a `std::shared_ptr<void>`. Region copies retain it; `memory_read_result` does not. Out-of-bounds requests throw `std::out_of_range`; an overflowing region throws `std::invalid_argument`. Memory allocation failures follow standard C++ exception behavior. These wrappers are also usable from Objective-C++ under ARC or manual reference counting.

```c
#include <ABIBridge/Inspection.h>

unsigned char bytes[16];
ABIMemoryReadResult result = ABIReadMemory(address, sizeof(bytes), bytes);
if (result.status == ABIMemoryReadComplete) {
    // All 16 bytes are available.
}
```

The C destination must be writable for the requested extent and must not overlap the source. Only its returned prefix is defined after an incomplete read. The caller retains source owners through the synchronous operation.

## Validation scope

Guarded-page, unaligned-read, overflow, empty-range, and lifetime tests execute on macOS. Other supported Apple platforms compile in CI; physical-device runtime behavior remains unverified.
