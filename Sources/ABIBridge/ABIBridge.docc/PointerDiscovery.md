# Discovering referenced objects

Find pointer slots in a bounded region whose pointees have a matching vtable address point.

## Describe the storage and target

Start with an address, a known allocation extent, and an owner supplied by the caller. Pass the actual vtable address point expected in the object's vptr. A vtable symbol's start is not necessarily its address point; ABIBridge does not infer a universal header size.

```swift
let region = try NativeMemoryRegion(
    address: enclosingAddress, byteCount: allocationSize, retaining: owner
)
let result = try region.pointers(
    toVTable: addressPoint,
    options: .init(vptrOffset: 0)
)
if let candidate = result.uniqueCandidate {
    print(candidate.offset, candidate.addressForInspection)
}
```

By default, the search visits native-width absolute pointers at pointer-sized intervals. Adjust ``NativePointerSearchOptions/firstOffset``, ``NativePointerSearchOptions/stride``, and ``NativePointerSearchOptions/alignment`` for other layouts, including packed slots with alignment 1. Align the first slot and make stride a multiple of alignment. Trailing incomplete slots are skipped.

The pointee's absolute vptr may be at a nonzero ``NativePointerSearchOptions/vptrOffset``. A match identifies the referenced address, without adjusting it to a base subobject or proving its construction state.

## Interpret the evidence

``NativePointerSearchResult/candidates`` retains every matching slot, ordered by source offset. Two slots pointing to the same normalized address are aliases, counted as one target in ``NativePointerSearchResult/distinctCount``. Two different addresses count as two targets.

Every slot and vptr read uses the recoverable memory reader. Null references are skipped. Other unreadable references are recorded in ``NativePointerSearchResult/failures``, and scanning continues. A range-overflow failure has no OS error; when adding the vptr offset overflows, its recorded address is the candidate base.

``NativePointerSearchResult/uniqueCandidate`` returns the first alias only after a complete scan finds exactly one distinct target. No match, multiple targets, or any read failure yields nil. Inspect `candidates` and `failures` if your selection policy accepts incomplete evidence.

Completeness covers the eligible slots under the supplied layout. Reads are not atomic and do not establish a stable object graph. Callers supply synchronization and keep both the enclosing allocation and pointees alive.

## Reuse an offset hint

For a caller that accepts any observed match, first-match policy can try a previously found offset before scanning the rest:

```swift
let result = try region.pointers(
    toVTable: addressPoint,
    options: .init(policy: .first, hintOffset: previousOffset)
)
if let candidate = result.candidates.first {
    previousOffset = candidate.offset
}
```

Every search re-reads the hinted slot and its pointee. A stale nonmatching hint falls back to the remaining eligible slots; an unreadable hint is retained as a failure. Off-grid or out-of-range hints are ignored. A matching hint short-circuits only the first-match policy, which always reports an incomplete result after finding a match and never claims uniqueness.

The default exhaustive policy still scans other slots to detect ambiguity. Keep hints scoped to the live region, slot layout, and target image/vtable identity; discard them after allocation replacement or image reload. Under first-match policy, a matching hint cannot reveal a new competing target.

## Revalidate only the cached slot

Use `region.pointer(at:toVTable:vptrOffset:normalization:)` when the first operation should inspect only a known offset. It never searches other source slots:

```swift
var candidate = try region.pointer(at: previousOffset, toVTable: addressPoint)
if candidate == nil {
    candidate = try region.pointers(toVTable: addressPoint).uniqueCandidate
}
```

The single-slot operation returns nil for a null reference or a readable unequal vptr. It throws ``NativePointerSearchFailure`` if the slot or its pointee cannot be read, preserving the stage, attempted address, copied byte count, and system error. Handle that failure explicitly if the consumer's policy permits falling back to a full search.

The offset may be unaligned, but the full-width slot must fit. Invalid bounds or unavailable normalization throw ``NativePointerSearchError``. A match retains the region owner without establishing uniqueness. Scope cached offsets as you would search hints.

C++ uses `inspect_pointer(region, offset, addressPoint, vptrOffset, normalization)`, returning `std::optional<pointer_candidate>`. A readable nonmatch returns `std::nullopt`; a read failure throws `pointer_read_error`, whose `failure()` preserves the C evidence. Setup failures throw `pointer_search_error`.

C uses `ABIInspectPointer` and checks the returned status before reading the candidate or failure field. The result is a copied value that needs no release. As with C searches, it retains no source or pointee owner.

## Keep normalization separate from authentication

Pointer searches and single-slot inspection default to ``NativePointerNormalization/automatic``. ABIBridge strips data signatures on a PAC-capable 64-bit ARM CPU and leaves address bits unchanged on other CPUs, including when capability detection is unavailable. The same interpretation applies to slot values, vptr values, and the expected address point. Callers do not need their own CPU feature checks.

Use `normalization: .none` when the operation requires unchanged pointer bits. C++ uses `pointer_normalization::none`; C uses `ABIPointerNormalizationNone`. `ABIDefaultPointerSearchOptions()` selects automatic normalization, while a zero-initialized C normalization field means none.

``NativePointerNormalization/stripDataSignature`` removes data-address signatures for recoverable inspection and comparison. It also works in a plain arm64 caller inspecting arm64e data, using a CPU capability check rather than relying on intrinsics that become no-ops outside the authenticated ABI. Unsupported CPUs report ``NativePointerSearchError/normalizationUnavailable``.

Normalization and stripping can match both valid and invalid signatures. They provide comparison evidence without authentication or removal of arbitrary tags. Dispatch still needs the original storage and schema, as described in [Clang's pointer-authentication model](https://clang.llvm.org/docs/PointerAuthentication.html#basic-concepts).

Each candidate preserves ``NativePointerCandidate/pointerBits``, ``NativePointerCandidate/slotAddress``, ``NativePointerCandidate/vptrBits``, and ``NativePointerCandidate/vptrAddress``. Use the original storage and a caller-supplied authentication schema for authenticated dispatch. Do not copy address-diversified signed bits to new storage and authenticate them using that new address.

## Reuse known-receiver calls

A candidate retains the enclosing region's owner. That owner must also retain the pointee if the candidate is used later; discovering a pointer does not acquire ownership of its object.

After establishing the selected object's layout, lifetime, and any required authentication, bind it using the existing ``NativeValue`` and ``ABIRuntime`` APIs:

```swift
let storage = unsafe NativeValue(
    borrowing: receiverAddress,
    as: receiverLayout,
    retaining: candidate
)
let object = runtime.cxxObject(storage, typeNamed: "Example::Renderer")
let refresh = try object.method(named: "refresh()", as: (() -> Void).self)
try unsafe refresh.unsafeInvoke()
```

Here, `receiverAddress` is the caller-established live receiver address and `receiverLayout` is its known ``NativeType``. A comparison-only normalized address is insufficient proof for this unsafe operation. Virtual calls continue to use ``NativeVTable`` with explicit bounds and ``NativePointerAuthentication`` schemas.

## Use the shared native API

C++ and Objective-C++ use the public inspection header and the same backend:

```cpp
#include <ABIBridge/Inspection.hpp>

abi_bridge::memory_region region(enclosingAddress, allocationSize, owner);
auto result = abi_bridge::find_pointers(region, addressPoint);
if (auto candidate = result.unique_candidate()) {
    auto evidence = candidate->evidence;
}
```

Candidate copies retain `source_region` and its optional `std::shared_ptr<void>` owner. `pointer_search_options` provides the same layout, policy, normalization, and hint fields as Swift. Setup failures throw `pointer_search_error`; read failures remain in the result.

C callers initialize `ABIPointerSearchOptions` with `ABIDefaultPointerSearchOptions()`, fill in the region and address point, then call `ABICopyPointerSearch`. Results own copied evidence and must be released with `ABIFreePointerSearch`. C callers keep their own region and pointee owners alive.

## Validation scope

Synthetic tests cover layouts, hint reuse, ambiguity, unreadable memory, and ownership, then pass discovered receivers to invocation APIs. macOS arm64 tests compare PAC-bearing data, including altered signatures. Device fixtures cover bounded discovery in tagged allocations; see <doc:Architectures> for authenticated-call evidence and its limits.
