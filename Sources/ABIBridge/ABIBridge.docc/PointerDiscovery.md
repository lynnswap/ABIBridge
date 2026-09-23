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

The default layout visits native-width absolute pointer slots at pointer-sized intervals. Use ``NativePointerSearchOptions/firstOffset``, ``NativePointerSearchOptions/stride``, and ``NativePointerSearchOptions/alignment`` for another layout, including packed slots with alignment 1. The first slot address must satisfy the declared alignment and stride must be a multiple of it. Trailing bytes shorter than a complete slot are not visited.

The pointee's absolute vptr may be at a nonzero ``NativePointerSearchOptions/vptrOffset``. A match identifies the referenced address, without adjusting it to a base subobject or proving its construction state.

## Interpret the evidence

``NativePointerSearchResult/candidates`` retains every matching slot, ordered by source offset. Two slots pointing to the same normalized address are aliases, counted as one target in ``NativePointerSearchResult/distinctCount``. Two different addresses count as two targets.

Every slot and vptr read uses the recoverable memory reader. Null references are skipped. Other unreadable references are recorded in ``NativePointerSearchResult/failures``, and scanning continues. A range-overflow failure has no OS error; when adding the vptr offset overflows, its recorded address is the candidate base.

An exhaustive scan with no read failures is complete. With zero distinct candidates, it observed no matches. With one, ``NativePointerSearchResult/uniqueCandidate`` returns the first alias. With multiple candidates, it returns nil. An incomplete scan also returns nil, even if the readable portion contained just one target. Callers can inspect the evidence and apply a different explicit selection policy.

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

With the default exhaustive policy, a hint does not avoid scanning other slots or hide ambiguity. Hints are caller-owned values, with no global cache. Scope them to a live enclosing region, slot layout, and target image/vtable identity; discard them when those change, including allocation replacement or image reload. A still-matching hint cannot detect a new competing target when first-match policy is used.

## Keep normalization separate from authentication

``NativePointerNormalization/stripDataSignature`` removes data-address signatures for recoverable inspection and comparison. It also works in a plain arm64 caller inspecting arm64e data, using a CPU capability check rather than relying on intrinsics that become no-ops outside the authenticated ABI. Unsupported CPUs report ``NativePointerSearchError/normalizationUnavailable``.

This operation does not verify a signature. Both valid and invalid signatures can produce matching evidence. It does not remove arbitrary pointer tags, authenticate a vptr, or turn a stripped address into an authenticated function pointer. See [Clang's pointer-authentication model](https://clang.llvm.org/docs/PointerAuthentication.html#basic-concepts).

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
let refresh = try await object.method(named: "refresh()", as: (() -> Void).self)
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

Synthetic C++ objects verify shifted fields, stale hints, aliases, competing targets, unreadable memory, packed slots, nonzero vptr offsets, and retained owners. Swift tests pass discovered receivers into existing invocation APIs. Plain arm64 macOS tests exercise PAC-bearing data generated with native signing instructions, including comparison of altered signatures. SDK builds cover other supported Apple platforms and arm64e compilation; authenticated dispatch on physical devices remains separately unverified.
