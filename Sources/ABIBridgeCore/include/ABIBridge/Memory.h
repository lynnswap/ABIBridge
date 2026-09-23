#ifndef ABIBRIDGE_MEMORY_H
#define ABIBRIDGE_MEMORY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Outcome of a bounded current-process read.
enum {
    ABIMemoryReadComplete = 0,
    ABIMemoryReadInvalidRange = 1,
    ABIMemoryReadFailed = 2,
    ABIMemoryReadPartial = 3
};

/// A copied prefix and the reason reading stopped.
typedef struct ABIMemoryReadResult {
    /// One of the ABIMemoryRead constants.
    int32_t status;
    /// Bytes successfully copied from the beginning of the requested range.
    size_t byteCount;
    /// Original kern_return_t, or zero when no OS error occurred.
    int32_t systemError;
} ABIMemoryReadResult;

/// Copies current-process bytes without directly dereferencing the source.
///
/// The destination must be writable for byteCount bytes and must not overlap
/// the source. Only the returned prefix is valid; the rest is unspecified.
/// A zero-length read succeeds without accessing either address (destination
/// may be NULL). Nonempty wrapping ranges or NULL destinations are invalid.
///
/// Reads stop at the first failed page and preserve previously copied pages.
/// This is not an atomic snapshot: callers provide synchronization if needed.
/// Neither a successful read nor a copied pointer proves object validity,
/// ownership, or continued readability. No other process can be selected.
ABIMemoryReadResult ABIReadMemory(uintptr_t address, size_t byteCount, void *destination);

#ifdef __cplusplus
}
#endif

#endif
