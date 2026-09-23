#pragma once
#include <ABIBridge/PointerSearch.h>
#include <ABIBridge/Memory.hpp>
#include <optional>

namespace abi_bridge {

/// How to interpret data-address bits for inspection, never authentication.
enum class pointer_normalization : std::int32_t {
    none = ABIPointerNormalizationNone,
    strip_data_signature = ABIPointerNormalizationStripDataSignature
};
/// Exhaustive searches can establish observed uniqueness; first-match searches cannot.
enum class pointer_search_policy : std::int32_t {
    all = ABIPointerSearchAll, first = ABIPointerSearchFirst
};

/// Caller-supplied layout and search policy for native-width absolute pointers.
struct pointer_search_options final {
    std::size_t first_offset = 0;
    std::size_t stride = sizeof(std::uintptr_t);
    std::size_t alignment = alignof(std::uintptr_t);
    std::size_t vptr_offset = 0;
    pointer_normalization normalization = pointer_normalization::none;
    pointer_search_policy policy = pointer_search_policy::all;
    /// Revalidated on every search. Scope it to the same live region, layout,
    /// and vtable identity. Invalid/off-grid hints are ignored.
    std::optional<std::size_t> hint_offset;
};

/// Invalid configuration, unavailable normalization, or result allocation failure.
class pointer_search_error final : public std::runtime_error {
public:
    explicit pointer_search_error(std::int32_t code)
        : std::runtime_error("Native pointer search could not be performed."), code_(code) {}
    std::int32_t code() const noexcept { return code_; }
private:
    std::int32_t code_;
};

/// Matching slot evidence retaining the source region's optional owner.
/// The owner must also keep the pointee alive if this candidate will be used
/// as a receiver. A vtable match alone establishes neither validity nor lifetime.
struct pointer_candidate final {
    ABIPointerCandidate evidence;
    memory_region source_region;
};

/// An owned copy of a slot or pointee read failure from single-slot inspection.
class pointer_read_error final : public std::runtime_error {
public:
    explicit pointer_read_error(ABIPointerSearchFailure failure)
        : std::runtime_error("Native pointer storage could not be read."), failure_(failure) {}
    const ABIPointerSearchFailure& failure() const noexcept { return failure_; }
private:
    ABIPointerSearchFailure failure_;
};

/// Revalidates one full-width slot without inspecting other source slots.
/// Packed slots are accepted; out-of-range slots throw pointer_search_error.
/// Returns nullopt for null references or readable unequal vptrs. Read failures
/// throw pointer_read_error with the original stage, address, and Mach result.
/// The candidate retains the region's owner and makes no uniqueness claim.
inline std::optional<pointer_candidate> inspect_pointer(
    const memory_region& region, std::size_t offset, std::uintptr_t vtable_address_point,
    std::size_t vptr_offset = 0, pointer_normalization normalization = pointer_normalization::none) {
    const auto result = ABIInspectPointer(
        region.address(), region.byte_count(), offset, vtable_address_point, vptr_offset,
        static_cast<std::int32_t>(normalization));
    switch (result.status) {
    case ABIPointerInspectionMatch: return pointer_candidate{result.candidate, region};
    case ABIPointerInspectionNoMatch: return std::nullopt;
    case ABIPointerInspectionReadFailed: throw pointer_read_error(result.failure);
    case ABIPointerInspectionNormalizationUnavailable:
        throw pointer_search_error(ABIPointerSearchNormalizationUnavailable);
    default: throw pointer_search_error(ABIPointerSearchInvalidOptions);
    }
}

/// Copied evidence. Candidate copies retain the source owner independently.
struct pointer_search_result final {
    std::vector<pointer_candidate> candidates;
    std::vector<ABIPointerSearchFailure> failures;
    std::size_t distinct_count;
    std::size_t visited_count;
    bool is_complete;

    /// A candidate only after a complete scan observed one distinct target.
    /// Aliases are retained in candidates; this returns its first source slot.
    std::optional<pointer_candidate> unique_candidate() const {
        if (is_complete && distinct_count == 1) return candidates.front();
        return std::nullopt;
    }
};

/// Searches explicit storage for references matching an actual vtable address
/// point. No ABI header length is inferred. Normalization strips data signatures
/// for inspection only; raw bits and storage addresses remain in each candidate.
/// First-match policy may return a matching hint without scanning other slots.
/// All policy scans every eligible slot, even with a valid hint. Failed reads
/// make the result incomplete; candidate/alias evidence is still returned.
/// Throws pointer_search_error for C-level setup failures, or standard
/// allocation exceptions while copying results.
inline pointer_search_result find_pointers(
    const memory_region& region, std::uintptr_t vtable_address_point,
    const pointer_search_options& options = {}) {
    ABIPointerSearchOptions query{
        region.address(), region.byte_count(), options.first_offset, options.stride,
        options.alignment, vtable_address_point, options.vptr_offset,
        static_cast<std::int32_t>(options.normalization),
        static_cast<std::int32_t>(options.policy), options.hint_offset.value_or(SIZE_MAX)
    };
    std::int32_t error = 0;
    std::unique_ptr<ABIPointerSearchResult, decltype(&ABIFreePointerSearch)>
        native(ABICopyPointerSearch(&query, &error), ABIFreePointerSearch);
    if (!native) throw pointer_search_error(error);
    pointer_search_result result{
        {}, {}, ABIPointerSearchDistinctCount(native.get()),
        ABIPointerSearchVisitedCount(native.get()), bool(ABIPointerSearchIsComplete(native.get()))
    };
    for (std::size_t i = 0; i < ABIPointerSearchCandidateCount(native.get()); ++i) {
        result.candidates.push_back({ABIPointerSearchCandidateAt(native.get(), i), region});
    }
    for (std::size_t i = 0; i < ABIPointerSearchFailureCount(native.get()); ++i) {
        result.failures.push_back(ABIPointerSearchFailureAt(native.get(), i));
    }
    return result;
}

} // namespace abi_bridge
