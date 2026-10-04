#include <ABIBridge/PointerSearch.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
#include <new>
#include <stdexcept>
#include <unordered_set>
#include <vector>
#if defined(__arm64__) && defined(__LP64__)
#include <arm_neon.h>
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

bool validNormalization(int32_t mode) {
    return mode == ABIPointerNormalizationNone || mode == ABIPointerNormalizationStripDataSignature ||
        mode == ABIPointerNormalizationAutomatic;
}

int32_t resolvedNormalization(int32_t mode) {
    if (mode == ABIPointerNormalizationAutomatic)
        return hasDataPAC() ? ABIPointerNormalizationStripDataSignature : ABIPointerNormalizationNone;
    return mode;
}

bool valid(const ABIPointerSearchOptions& o) {
    return o.byteCount <= UINTPTR_MAX - o.address &&
        o.firstOffset <= o.byteCount && o.stride > 0 && o.alignment > 0 &&
        (o.alignment & (o.alignment - 1)) == 0 &&
        (o.address + o.firstOffset) % o.alignment == 0 &&
        o.stride % o.alignment == 0 && o.vtableAddressPoint != 0 &&
        validNormalization(o.normalization) &&
        (o.policy == ABIPointerSearchAll || o.policy == ABIPointerSearchFirst);
}

ABIPointerInspectionResult inspectPointer(
    uintptr_t address, size_t offset, size_t vptrOffset, uintptr_t expected,
    int32_t normalization, uintptr_t bits) {
    ABIPointerInspectionResult result{};
    const auto slot = address + offset;
    const auto target = normalize(bits, normalization);
    if (target == 0) return result;
    if (vptrOffset > UINTPTR_MAX - target) {
        result.status = ABIPointerInspectionReadFailed;
        result.failure = {offset, ABIPointerSearchVPtrRead, target, {ABIMemoryReadInvalidRange, 0, 0}};
        return result;
    }
    const auto vptrAddress = target + vptrOffset;
    uintptr_t vptr = 0;
    const auto vptrRead = ABIReadMemory(vptrAddress, sizeof(vptr), &vptr);
    if (vptrRead.status != ABIMemoryReadComplete) {
        result.status = ABIPointerInspectionReadFailed;
        result.failure = {offset, ABIPointerSearchVPtrRead, vptrAddress, vptrRead};
        return result;
    }
    if (normalize(vptr, normalization) != expected) return result;
    result.status = ABIPointerInspectionMatch;
    result.candidate = {offset, slot, bits, target, vptrAddress, vptr};
    return result;
}

ABIPointerInspectionResult inspectSlot(
    uintptr_t address, size_t offset, size_t vptrOffset, uintptr_t expected,
    int32_t normalization) {
    uintptr_t bits = 0;
    const auto slotRead = ABIReadMemory(address + offset, sizeof(bits), &bits);
    if (slotRead.status != ABIMemoryReadComplete) {
        ABIPointerInspectionResult result{};
        result.status = ABIPointerInspectionReadFailed;
        result.failure = {offset, ABIPointerSearchSlotRead, address + offset, slotRead};
        return result;
    }
    return inspectPointer(address, offset, vptrOffset, expected, normalization, bits);
}

std::unique_ptr<ABIPointerSearchResult> search(const ABIPointerSearchOptions& o) {
    auto result = std::make_unique<ABIPointerSearchResult>();
    std::unordered_set<uintptr_t> distinct;
    const auto expected = normalize(o.vtableAddressPoint, o.normalization);
    std::array<unsigned char, 4096> source;
    size_t sourceOffset = 0, sourceCount = 0;
    bool sourceComplete = false;
    const auto readSource = [&](size_t offset) {
        if (offset < sourceOffset || offset - sourceOffset > sourceCount ||
            sizeof(uintptr_t) > sourceCount - (offset - sourceOffset)) {
            sourceOffset = offset;
            sourceCount = std::min(source.size(), o.byteCount - offset);
            const auto read = ABIReadMemory(o.address + offset, sourceCount, source.data());
            sourceComplete = read.status == ABIMemoryReadComplete;
        }
        return sourceComplete;
    };
    const auto visit = [&](size_t offset, bool individual = false) {
        ++result->visitedCount;
        ABIPointerInspectionResult inspection;
        if (!individual && readSource(offset)) {
            uintptr_t bits;
            std::memcpy(&bits, source.data() + offset - sourceOffset, sizeof(bits));
            inspection = inspectPointer(o.address, offset, o.vptrOffset, expected, o.normalization, bits);
        } else {
            // Failed bulk reads cannot describe a particular slot's readable
            // prefix. Re-read that slot to preserve its exact failure evidence.
            inspection = inspectSlot(o.address, offset, o.vptrOffset, expected, o.normalization);
        }
        if (inspection.status == ABIPointerInspectionReadFailed) {
            result->failures.push_back(inspection.failure);
            return false;
        }
        if (inspection.status != ABIPointerInspectionMatch) return false;
        result->candidates.push_back(inspection.candidate);
        distinct.insert(inspection.candidate.addressForInspection);
        return true;
    };

    const auto slotFits = [&](size_t offset) {
        return offset >= o.firstOffset && offset <= o.byteCount &&
            sizeof(uintptr_t) <= o.byteCount - offset &&
            (offset - o.firstOffset) % o.stride == 0;
    };
    const bool hintFits = o.hintOffset != SIZE_MAX && slotFits(o.hintOffset);
    bool stopped = false;
    if (hintFits && visit(o.hintOffset, true) && o.policy == ABIPointerSearchFirst) {
        stopped = true;
    }
    if (!stopped && slotFits(o.firstOffset)) {
        const auto last = o.byteCount - sizeof(uintptr_t);
        for (size_t offset = o.firstOffset;;) {
#if defined(__arm64__) && defined(__LP64__)
            // Four null slots require no pointee reads or PAC normalization.
            // Load only copied bytes, and leave hinted slots' visit counts alone.
            constexpr size_t width = 4 * sizeof(uintptr_t);
            if (o.stride == sizeof(uintptr_t) && (offset - o.firstOffset) % width == 0 &&
                last - offset >= width - sizeof(uintptr_t) &&
                (!hintFits || o.hintOffset < offset || o.hintOffset - offset >= width) &&
                readSource(offset) && sourceCount - (offset - sourceOffset) >= width) {
                const auto *bytes = source.data() + offset - sourceOffset;
                if (vmaxvq_u8(vorrq_u8(vld1q_u8(bytes), vld1q_u8(bytes + 16))) == 0) {
                    result->visitedCount += 4;
                    if (width > last - offset) break;
                    offset += width;
                    continue;
                }
            }
#endif
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
            ABIPointerNormalizationAutomatic, ABIPointerSearchAll, SIZE_MAX};
}

ABIPointerSearchResult* ABICopyPointerSearch(const ABIPointerSearchOptions* options, int32_t* error) {
    const auto fail = [error](int32_t code) -> ABIPointerSearchResult* {
        if (error) *error = code;
        return nullptr;
    };
    if (!valid(*options)) return fail(ABIPointerSearchInvalidOptions);
    auto effective = *options;
    effective.normalization = resolvedNormalization(effective.normalization);
    if (effective.normalization == ABIPointerNormalizationStripDataSignature && !hasDataPAC()) {
        return fail(ABIPointerSearchNormalizationUnavailable);
    }
    if (normalize(effective.vtableAddressPoint, effective.normalization) == 0) {
        return fail(ABIPointerSearchInvalidOptions);
    }
    try {
        auto result = search(effective);
        if (error) *error = ABIPointerSearchSuccess;
        return result.release();
    } catch (const std::bad_alloc&) {
        return fail(ABIPointerSearchAllocationFailed);
    } catch (const std::length_error&) {
        return fail(ABIPointerSearchAllocationFailed);
    }
}

ABIPointerInspectionResult ABIInspectPointer(
    uintptr_t address, size_t byteCount, size_t offset,
    uintptr_t vtableAddressPoint, size_t vptrOffset, int32_t normalization) {
    ABIPointerInspectionResult result{};
    if (byteCount > UINTPTR_MAX - address || offset > byteCount ||
        sizeof(uintptr_t) > byteCount - offset || vtableAddressPoint == 0 ||
        !validNormalization(normalization)) {
        result.status = ABIPointerInspectionInvalidOptions;
        return result;
    }
    normalization = resolvedNormalization(normalization);
    if (normalization == ABIPointerNormalizationStripDataSignature && !hasDataPAC()) {
        result.status = ABIPointerInspectionNormalizationUnavailable;
        return result;
    }
    const auto expected = normalize(vtableAddressPoint, normalization);
    if (expected == 0) {
        result.status = ABIPointerInspectionInvalidOptions;
        return result;
    }
    return inspectSlot(address, offset, vptrOffset, expected, normalization);
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
