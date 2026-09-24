#include <ABIBridge/PointerSearch.hpp>
#include <cassert>
#include <cerrno>
#include <cstring>
#include <sys/sysctl.h>

static const char *capability;

// Only the separately compiled scanner redirects sysctlbyname here. Exercise
// real pointer reads while controlling the capability result on any test host.
extern "C" int ABIPointerTestSysctl(const char *name, void *value, size_t *size, void *newValue, size_t newSize) {
    assert(std::strcmp(name, "hw.optional.arm.FEAT_PAuth") == 0);
    if (std::strcmp(capability, "host") == 0)
        return sysctlbyname(name, value, size, newValue, newSize);
    if (std::strcmp(capability, "unavailable") == 0) {
        errno = ENOENT;
        return -1;
    }
    assert(*size == sizeof(int));
    *static_cast<int *>(value) = 0;
    return 0;
}

#if defined(__arm64__) && defined(__LP64__)
__attribute__((target("pauth")))
static uintptr_t signPointer(uintptr_t bits, uintptr_t modifier) {
    __asm__("pacda %0, %1" : "+r"(bits) : "r"(modifier));
    return bits;
}
#endif

static void check(uintptr_t *slots, uintptr_t expected, uintptr_t object, uintptr_t vptr, int32_t mode) {
    auto options = ABIDefaultPointerSearchOptions();
    options.address = reinterpret_cast<uintptr_t>(slots);
    options.byteCount = sizeof(uintptr_t) * 2;
    options.vtableAddressPoint = expected;
    options.normalization = mode;
    int32_t error = -1;
    auto *result = ABICopyPointerSearch(&options, &error);
    assert(result && error == ABIPointerSearchSuccess);
    assert(ABIPointerSearchIsComplete(result) && ABIPointerSearchDistinctCount(result) == 1);
    assert(ABIPointerSearchCandidateCount(result) == 1);
    const auto found = ABIPointerSearchCandidateAt(result, 0);
    assert(found.offset == sizeof(uintptr_t) && found.pointerBits == slots[1]);
    assert(found.addressForInspection == object && found.vptrBits == vptr);
    ABIFreePointerSearch(result);
    const auto single = ABIInspectPointer(options.address, options.byteCount, sizeof(uintptr_t), expected, 0, mode);
    assert(single.status == ABIPointerInspectionMatch);
    assert(single.candidate.pointerBits == slots[1] && single.candidate.vptrBits == vptr);
    assert(single.candidate.addressForInspection == object);

    const abi_bridge::memory_region region(options.address, options.byteCount);
    if (mode == ABIPointerNormalizationAutomatic) {
        // Leave both C++ defaults omitted, including single-slot normalization.
        assert(abi_bridge::find_pointers(region, expected).unique_candidate()->evidence.addressForInspection == object);
        assert(abi_bridge::inspect_pointer(region, sizeof(uintptr_t), expected)->evidence.addressForInspection == object);
    }
}

int main(int argc, char **argv) {
    assert(argc == 2);
    capability = argv[1];
    uintptr_t table = 73;
    const auto tableAddress = reinterpret_cast<uintptr_t>(&table);
    uintptr_t object = tableAddress;
    const auto address = reinterpret_cast<uintptr_t>(&object);
    uintptr_t slots[] = {0, address};
    assert(ABIDefaultPointerSearchOptions().normalization == ABIPointerNormalizationAutomatic);
    check(slots, tableAddress, address, object, ABIPointerNormalizationAutomatic);
    check(slots, tableAddress, address, object, ABIPointerNormalizationNone);
    bool supported = false;
#if defined(__arm64__) && defined(__LP64__)
    int value = 0;
    size_t size = sizeof(value);
    supported = std::strcmp(capability, "host") == 0 &&
        sysctlbyname("hw.optional.arm.FEAT_PAuth", &value, &size, nullptr, 0) == 0 && value;
    if (supported) {
        slots[1] = signPointer(address, reinterpret_cast<uintptr_t>(&slots[1]));
        object = signPointer(tableAddress, address);
        const auto expected = signPointer(tableAddress, 17);
        check(slots, expected, address, object, ABIPointerNormalizationAutomatic);
        check(slots, expected, address, object, ABIPointerNormalizationStripDataSignature);
        // Explicit none compares raw vptr bits, even when stripping would merge them.
        slots[1] = address;
        // Test exact comparison independently of which signature bits were produced.
        object = tableAddress ^ (uintptr_t(1) << 63);
        const abi_bridge::memory_region region(reinterpret_cast<uintptr_t>(slots), sizeof(slots));
        assert(!abi_bridge::inspect_pointer(region, sizeof(uintptr_t), tableAddress, 0, abi_bridge::pointer_normalization::none));
        assert(abi_bridge::inspect_pointer(region, sizeof(uintptr_t), object, 0, abi_bridge::pointer_normalization::none));
    }
#endif
    if (!supported) {
        auto options = ABIDefaultPointerSearchOptions();
        options.address = reinterpret_cast<uintptr_t>(slots);
        options.byteCount = sizeof(slots);
        options.vtableAddressPoint = tableAddress;
        options.normalization = ABIPointerNormalizationStripDataSignature;
        int32_t error = -1;
        assert(!ABICopyPointerSearch(&options, &error));
        assert(error == ABIPointerSearchNormalizationUnavailable);
        assert(ABIInspectPointer(options.address, options.byteCount, sizeof(uintptr_t), tableAddress, 0,
                                 options.normalization).status == ABIPointerInspectionNormalizationUnavailable);
    }
    // Unknown modes remain setup errors for both entry points.
    auto invalid = ABIDefaultPointerSearchOptions();
    invalid.vtableAddressPoint = tableAddress;
    invalid.normalization = 99;
    int32_t error = -1;
    assert(!ABICopyPointerSearch(&invalid, &error) && error == ABIPointerSearchInvalidOptions);
    assert(ABIInspectPointer(reinterpret_cast<uintptr_t>(slots), sizeof(slots), 0, tableAddress, 0, 99).status ==
           ABIPointerInspectionInvalidOptions);
}
