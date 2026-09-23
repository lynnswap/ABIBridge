#include <ABIBridge/PointerSearch.h>
#include <algorithm>
#include <memory>
#include <new>
#include <stdexcept>
#include <unordered_set>
#include <vector>
#if defined(__arm64__) && defined(__LP64__)
#include <sys/sysctl.h>
#endif

struct ABIPointerSearchResult {
    std::vector<ABIPointerCandidate> candidates;
    std::vector<ABIPointerSearchFailure> failures;
    size_t distinctCount = 0;
    size_t visitedCount = 0;
    bool complete = false;
};

namespace {
#if defined(__arm64__) && defined(__LP64__)
bool hasDataPAC() {
    static const bool available = [] {
        int supported = 0;
        size_t size = sizeof(supported);
        return sysctlbyname("hw.optional.arm.FEAT_PAuth", &supported, &size, nullptr, 0) == 0 && supported;
    }();
    return available;
}

// ptrauth_strip is a no-op when compiling plain arm64, even when the data
// being inspected came from arm64e. Gate the instruction on CPU capability.
__attribute__((target("pauth")))
uintptr_t stripDataSignature(uintptr_t bits) {
    __asm__("xpacd %0" : "+r"(bits));
    return bits;
}
#else
bool hasDataPAC() { return false; }
uintptr_t stripDataSignature(uintptr_t bits) { return bits; }
#endif

uintptr_t normalize(uintptr_t bits, int32_t mode) {
    return mode == ABIPointerNormalizationNone ? bits : stripDataSignature(bits);
}

bool valid(const ABIPointerSearchOptions& o) {
    return o.byteCount <= UINTPTR_MAX - o.address &&
        o.firstOffset <= o.byteCount && o.stride > 0 && o.alignment > 0 &&
        (o.alignment & (o.alignment - 1)) == 0 &&
        (o.address + o.firstOffset) % o.alignment == 0 &&
        o.stride % o.alignment == 0 && o.vtableAddressPoint != 0 &&
        (o.normalization == ABIPointerNormalizationNone ||
         o.normalization == ABIPointerNormalizationStripDataSignature) &&
        (o.policy == ABIPointerSearchAll || o.policy == ABIPointerSearchFirst);
}

std::unique_ptr<ABIPointerSearchResult> search(const ABIPointerSearchOptions& o) {
    auto result = std::make_unique<ABIPointerSearchResult>();
    std::unordered_set<uintptr_t> distinct;
    const auto expected = normalize(o.vtableAddressPoint, o.normalization);
    const auto visit = [&](size_t offset) {
        ++result->visitedCount;
        const auto slot = o.address + offset;
        uintptr_t bits = 0;
        const auto slotRead = ABIReadMemory(slot, sizeof(bits), &bits);
        if (slotRead.status != ABIMemoryReadComplete) {
            result->failures.push_back({offset, ABIPointerSearchSlotRead, slot, slotRead});
            return false;
        }
        const auto target = normalize(bits, o.normalization);
        if (target == 0) return false;
        if (o.vptrOffset > UINTPTR_MAX - target) {
            result->failures.push_back({offset, ABIPointerSearchVPtrRead, target,
                                       {ABIMemoryReadInvalidRange, 0, 0}});
            return false;
        }
        const auto vptrAddress = target + o.vptrOffset;
        uintptr_t vptr = 0;
        const auto vptrRead = ABIReadMemory(vptrAddress, sizeof(vptr), &vptr);
        if (vptrRead.status != ABIMemoryReadComplete) {
            result->failures.push_back({offset, ABIPointerSearchVPtrRead, vptrAddress, vptrRead});
            return false;
        }
        if (normalize(vptr, o.normalization) != expected) return false;
        result->candidates.push_back({offset, slot, bits, target, vptrAddress, vptr});
        distinct.insert(target);
        return true;
    };

    const auto slotFits = [&](size_t offset) {
        return offset >= o.firstOffset && offset <= o.byteCount &&
            sizeof(uintptr_t) <= o.byteCount - offset &&
            (offset - o.firstOffset) % o.stride == 0;
    };
    const bool hintFits = o.hintOffset != SIZE_MAX && slotFits(o.hintOffset);
    bool stopped = false;
    if (hintFits && visit(o.hintOffset) && o.policy == ABIPointerSearchFirst) {
        stopped = true;
    }
    if (!stopped && slotFits(o.firstOffset)) {
        const auto last = o.byteCount - sizeof(uintptr_t);
        for (size_t offset = o.firstOffset;;) {
            if ((!hintFits || offset != o.hintOffset) && visit(offset) && o.policy == ABIPointerSearchFirst) {
                stopped = true;
                break;
            }
            if (o.stride > last - offset) break;
            offset += o.stride;
        }
    }
    const auto byOffset = [](const auto& a, const auto& b) { return a.offset < b.offset; };
    std::sort(result->candidates.begin(), result->candidates.end(), byOffset);
    std::sort(result->failures.begin(), result->failures.end(), byOffset);
    result->distinctCount = distinct.size();
    result->complete = !stopped && result->failures.empty();
    return result;
}
} // namespace

ABIPointerSearchOptions ABIDefaultPointerSearchOptions() {
    return {0, 0, 0, sizeof(uintptr_t), alignof(uintptr_t), 0, 0,
            ABIPointerNormalizationNone, ABIPointerSearchAll, SIZE_MAX};
}

ABIPointerSearchResult* ABICopyPointerSearch(const ABIPointerSearchOptions* options, int32_t* error) {
    const auto fail = [error](int32_t code) -> ABIPointerSearchResult* {
        if (error) *error = code;
        return nullptr;
    };
    if (!valid(*options)) return fail(ABIPointerSearchInvalidOptions);
    if (options->normalization != ABIPointerNormalizationNone && !hasDataPAC()) {
        return fail(ABIPointerSearchNormalizationUnavailable);
    }
    if (normalize(options->vtableAddressPoint, options->normalization) == 0) {
        return fail(ABIPointerSearchInvalidOptions);
    }
    try {
        auto result = search(*options);
        if (error) *error = ABIPointerSearchSuccess;
        return result.release();
    } catch (const std::bad_alloc&) {
        return fail(ABIPointerSearchAllocationFailed);
    } catch (const std::length_error&) {
        return fail(ABIPointerSearchAllocationFailed);
    }
}

void ABIFreePointerSearch(ABIPointerSearchResult* result) { delete result; }
size_t ABIPointerSearchCandidateCount(const ABIPointerSearchResult* result) { return result->candidates.size(); }
ABIPointerCandidate ABIPointerSearchCandidateAt(const ABIPointerSearchResult* result, size_t index) {
    return result->candidates[index];
}
size_t ABIPointerSearchFailureCount(const ABIPointerSearchResult* result) { return result->failures.size(); }
ABIPointerSearchFailure ABIPointerSearchFailureAt(const ABIPointerSearchResult* result, size_t index) {
    return result->failures[index];
}
size_t ABIPointerSearchDistinctCount(const ABIPointerSearchResult* result) { return result->distinctCount; }
size_t ABIPointerSearchVisitedCount(const ABIPointerSearchResult* result) { return result->visitedCount; }
int ABIPointerSearchIsComplete(const ABIPointerSearchResult* result) { return result->complete; }
