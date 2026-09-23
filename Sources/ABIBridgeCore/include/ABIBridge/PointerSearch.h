#ifndef ABIBRIDGE_POINTER_SEARCH_H
#define ABIBRIDGE_POINTER_SEARCH_H
#include <ABIBridge/Memory.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABIPointerSearchResult ABIPointerSearchResult;

enum {
    ABIPointerNormalizationNone = 0,
    /// Strip data-address signatures for inspection only; never authenticate.
    ABIPointerNormalizationStripDataSignature = 1
};
enum {
    ABIPointerSearchAll = 0,
    /// May stop at a matching hint. Makes no uniqueness claim.
    ABIPointerSearchFirst = 1
};
enum {
    ABIPointerSearchSuccess = 0,
    ABIPointerSearchInvalidOptions = 1,
    ABIPointerSearchNormalizationUnavailable = 2,
    ABIPointerSearchAllocationFailed = 3
};
enum {
    ABIPointerSearchSlotRead = 0,
    ABIPointerSearchVPtrRead = 1
};

/// Explicit interpretation of native-width absolute pointer slots.
/// Initialize every field, or use ABIDefaultPointerSearchOptions().
typedef struct ABIPointerSearchOptions {
    uintptr_t address;
    size_t byteCount;
    /// First slot's offset within the enclosing region.
    size_t firstOffset;
    /// Positive step in bytes; may be smaller than a pointer.
    size_t stride;
    /// Positive power-of-two alignment of slot storage addresses, not pointees.
    /// The first slot must satisfy it; stride must be a multiple of it.
    size_t alignment;
    /// The actual address point, not a vtable symbol plus an inferred header.
    uintptr_t vtableAddressPoint;
    /// Nonnegative byte offset of the absolute vptr within each pointee.
    size_t vptrOffset;
    /// Applied to slot values and vptr values, including the expected address point.
    int32_t normalization;
    int32_t policy;
    /// SIZE_MAX means no hint. Out-of-range/off-grid hints are ignored.
    /// Callers scope hints to the region lifetime, layout, and target identity.
    size_t hintOffset;
} ABIPointerSearchOptions;

/// Defaults: pointer-sized stride/alignment, vptr at zero, no normalization,
/// exhaustive search, no hint. Fill in address, byteCount, and address point.
ABIPointerSearchOptions ABIDefaultPointerSearchOptions(void);

/// Evidence for one matching source slot. Several slots may alias one target.
/// Original bits and storage addresses are preserved for caller-supplied
/// authentication. None of these numeric values is an authenticated call target.
typedef struct ABIPointerCandidate {
    size_t offset;
    uintptr_t slotAddress;
    uintptr_t pointerBits;
    uintptr_t addressForInspection;
    uintptr_t vptrAddress;
    uintptr_t vptrBits;
} ABIPointerCandidate;

/// One unreadable slot or pointee. Searches continue past these failures.
typedef struct ABIPointerSearchFailure {
    size_t offset;
    /// ABIPointerSearchSlotRead or ABIPointerSearchVPtrRead.
    int32_t stage;
    uintptr_t address;
    ABIMemoryReadResult read;
} ABIPointerSearchFailure;

/// Searches current-process storage, returning owned copied evidence.
///
/// The options pointer must be valid. No source owner is retained by this C
/// result; callers keep region and pointee owners alive for the operation and
/// any later use of candidates. Reads are non-atomic; callers synchronize.
///
/// Returns NULL for invalid options, unavailable requested normalization, or
/// allocation failure, optionally setting error. Clears error on success.
/// Recoverable read failures are stored in a non-NULL result, not in error.
/// A null slot is not a candidate and is not a read failure. Only full-width
/// slots within the region are visited. Trailing bytes are not pointer slots.
ABIPointerSearchResult *ABICopyPointerSearch(const ABIPointerSearchOptions *options, int32_t *error);
/// Accepts NULL.
void ABIFreePointerSearch(ABIPointerSearchResult *result);
/// The remaining accessors require a live non-NULL result; indexed access
/// additionally requires an index below the corresponding count.
size_t ABIPointerSearchCandidateCount(const ABIPointerSearchResult *result);
ABIPointerCandidate ABIPointerSearchCandidateAt(const ABIPointerSearchResult *result, size_t index);
size_t ABIPointerSearchFailureCount(const ABIPointerSearchResult *result);
ABIPointerSearchFailure ABIPointerSearchFailureAt(const ABIPointerSearchResult *result, size_t index);
/// Number of different addressForInspection values among observed matches.
size_t ABIPointerSearchDistinctCount(const ABIPointerSearchResult *result);
/// Number of visited slots, including failures and a visited hint.
size_t ABIPointerSearchVisitedCount(const ABIPointerSearchResult *result);
/// Nonzero only after an exhaustive scan with no read failures. A first-match
/// search that stopped at a match is never complete, even on its final slot.
/// Only a complete scan with distinct count 1 establishes observed uniqueness.
int ABIPointerSearchIsComplete(const ABIPointerSearchResult *result);

#ifdef __cplusplus
}
#endif
#endif
