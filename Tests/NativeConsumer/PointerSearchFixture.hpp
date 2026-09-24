#pragma once
#include <ABIBridge/Inspection.hpp>
#include <cassert>
#include <cstring>
#include <sys/mman.h>
#include <unistd.h>
#if defined(__arm64__) && defined(__LP64__)
#include <sys/sysctl.h>
__attribute__((target("pauth")))
inline std::uintptr_t signInspectionPointer(std::uintptr_t bits, std::uintptr_t modifier) {
    __asm__("pacda %0, %1" : "+r"(bits) : "r"(modifier));
    return bits;
}
#endif

struct DiscoveryObject {
    virtual int value() const { return 73; }
};
inline void checkPointerSearch() {
    using namespace abi_bridge;
    auto owner = std::make_shared<DiscoveryObject>();
    DiscoveryObject second;
    std::uintptr_t table = 0;
    std::memcpy(&table, static_cast<const void*>(owner.get()), sizeof(table));
    std::uintptr_t slots[5] = {0, reinterpret_cast<std::uintptr_t>(owner.get()), 0, 0, 0};
    memory_region region(reinterpret_cast<std::uintptr_t>(slots), sizeof(slots), owner);
    pointer_search_options options;
    options.hint_offset = sizeof(std::uintptr_t) * 4;
    auto result = find_pointers(region, table, options);
    assert(result.is_complete && result.distinct_count == 1 && result.visited_count == 5);
    assert(result.unique_candidate()->evidence.offset == sizeof(std::uintptr_t));
    assert(!inspect_pointer(region, 0, table));
    auto single = inspect_pointer(region, sizeof(std::uintptr_t), table);
    assert(single && single->evidence.addressForInspection == slots[1]);
    single.reset();
    slots[4] = slots[1];
    result = find_pointers(region, table, options);
    assert(result.is_complete && result.distinct_count == 1 && result.candidates.size() == 2);
    assert(result.candidates[0].evidence.slotAddress == reinterpret_cast<std::uintptr_t>(&slots[1]));
    slots[3] = reinterpret_cast<std::uintptr_t>(&second);
    assert(!find_pointers(region, table, options).unique_candidate());
    options.policy = pointer_search_policy::first;
    result = find_pointers(region, table, options);
    assert(!result.is_complete && result.visited_count == 1 && result.candidates[0].evidence.offset == sizeof(std::uintptr_t) * 4);
    slots[4] = 0;
    assert(!inspect_pointer(region, sizeof(std::uintptr_t) * 4, table));
    result = find_pointers(region, table, options);
    assert(result.visited_count == 3 && result.candidates[0].evidence.offset == sizeof(std::uintptr_t));
    options.policy = pointer_search_policy::all;
    slots[3] = 1;
    result = find_pointers(region, table, options);
    assert(!result.is_complete && result.failures.size() == 1 && result.distinct_count == 1);
    assert(result.failures[0].stage == ABIPointerSearchVPtrRead);
    try {
        inspect_pointer(region, sizeof(std::uintptr_t) * 3, table);
        assert(false);
    } catch (const pointer_read_error& error) {
        assert(error.failure().stage == ABIPointerSearchVPtrRead && error.failure().address == 1);
    }
    slots[3] = 0;

    // A copied candidate keeps a separately supplied pointee owner alive.
    std::weak_ptr<DiscoveryObject> weakOwner = owner;
    auto retained = inspect_pointer(region, sizeof(std::uintptr_t), table);
    owner.reset();
    region = memory_region(0, 0);
    result = {};
    assert(!weakOwner.expired());
    assert(reinterpret_cast<DiscoveryObject*>(retained->evidence.addressForInspection)->value() == 73);
    retained.reset();
    assert(weakOwner.expired());

    // A guarded source slot reports a source failure and does not stop later visits.
    const auto page = static_cast<std::size_t>(getpagesize());
    auto* pages = static_cast<std::byte*>(mmap(nullptr, page * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0));
    assert(pages != MAP_FAILED);
    assert(mprotect(pages + page, page, PROT_NONE) == 0);
    result = find_pointers(memory_region(reinterpret_cast<std::uintptr_t>(pages + page - sizeof(std::uintptr_t)), sizeof(std::uintptr_t) * 2), table);
    assert(!result.is_complete && result.visited_count == 2 && result.failures.size() == 1);
    assert(result.failures[0].stage == ABIPointerSearchSlotRead);
    const memory_region guarded(reinterpret_cast<std::uintptr_t>(pages), page * 2);
    assert(!inspect_pointer(guarded, 0, table)); // Does not read the protected page.
    try {
        inspect_pointer(guarded, page, table);
        assert(false);
    } catch (const pointer_read_error& error) {
        assert(error.failure().stage == ABIPointerSearchSlotRead);
        assert(error.failure().offset == page && error.failure().read.byteCount == 0);
    }
    assert(munmap(pages, page * 2) == 0);

    // Explicit vptr offset, packed slot alignment, and trailing bytes.
    struct Record { std::uintptr_t prefix; std::uintptr_t vptr; } record{0, table};
    const auto address = reinterpret_cast<std::uintptr_t>(&record);
    std::byte packed[sizeof(std::uintptr_t) + 2]{};
    std::memcpy(packed + 1, &address, sizeof(address));
    options = {};
    options.first_offset = 1;
    options.alignment = 1;
    options.vptr_offset = sizeof(std::uintptr_t);
    result = find_pointers(memory_region(reinterpret_cast<std::uintptr_t>(packed), sizeof(packed)), table, options);
    assert(result.unique_candidate()->evidence.vptrAddress == reinterpret_cast<std::uintptr_t>(&record.vptr));
    single = inspect_pointer(memory_region(reinterpret_cast<std::uintptr_t>(packed), sizeof(packed)),
                             1, table, sizeof(std::uintptr_t));
    assert(single && single->evidence.vptrAddress == reinterpret_cast<std::uintptr_t>(&record.vptr));
    try {
        inspect_pointer(memory_region(reinterpret_cast<std::uintptr_t>(packed), sizeof(packed)),
                        sizeof(packed), table);
        assert(false);
    } catch (const pointer_search_error& error) { assert(error.code() == ABIPointerSearchInvalidOptions); }
    options.stride = 0;
    try {
        find_pointers(memory_region(reinterpret_cast<std::uintptr_t>(packed), sizeof(packed)), table, options);
        assert(false);
    } catch (const pointer_search_error& error) { assert(error.code() == ABIPointerSearchInvalidOptions); }

    // PAC-bearing data is generated and stripped in a plain arm64 consumer.
    options = {};
    options.normalization = pointer_normalization::strip_data_signature;
    bool supported = false;
#if defined(__arm64__) && defined(__LP64__)
    int value = 0;
    size_t size = sizeof(value);
    supported = sysctlbyname("hw.optional.arm.FEAT_PAuth", &value, &size, nullptr, 0) == 0 && value;
    if (supported) {
        record.vptr = signInspectionPointer(table, reinterpret_cast<std::uintptr_t>(&record.vptr));
        const auto signedAddress = signInspectionPointer(address, reinterpret_cast<std::uintptr_t>(&slots[0]));
        slots[0] = signedAddress;
        options.vptr_offset = sizeof(std::uintptr_t);
        result = find_pointers(memory_region(reinterpret_cast<std::uintptr_t>(slots), sizeof(std::uintptr_t)), table, options);
        const auto evidence = result.unique_candidate()->evidence;
        assert(evidence.pointerBits == signedAddress && evidence.addressForInspection == address);
        assert(evidence.vptrBits == record.vptr && evidence.vptrAddress == reinterpret_cast<std::uintptr_t>(&record.vptr));
        single = inspect_pointer(memory_region(reinterpret_cast<std::uintptr_t>(slots), sizeof(std::uintptr_t)),
                                 0, table, sizeof(std::uintptr_t), pointer_normalization::strip_data_signature);
        assert(single && single->evidence.pointerBits == signedAddress && single->evidence.vptrBits == record.vptr);
        options.normalization = pointer_normalization::automatic;
        result = find_pointers(memory_region(reinterpret_cast<std::uintptr_t>(slots), sizeof(std::uintptr_t)), table, options);
        assert(result.unique_candidate()->evidence.pointerBits == signedAddress);
        single = inspect_pointer(memory_region(reinterpret_cast<std::uintptr_t>(slots), sizeof(std::uintptr_t)),
                                 0, table, sizeof(std::uintptr_t));
        assert(single && single->evidence.vptrBits == record.vptr);
        // Tampered signatures still strip: discovery is explicitly not authentication.
        const auto pointerSignature = signedAddress ^ address;
        const auto vptrSignature = record.vptr ^ table;
        slots[0] ^= pointerSignature & (~pointerSignature + 1);
        record.vptr ^= vptrSignature & (~vptrSignature + 1);
        assert(find_pointers(memory_region(reinterpret_cast<std::uintptr_t>(slots), sizeof(std::uintptr_t)), table, options).unique_candidate());
    }
#endif
    if (!supported) {
        try { find_pointers(memory_region(0, 0), table, options); assert(false); }
        catch (const pointer_search_error& error) { assert(error.code() == ABIPointerSearchNormalizationUnavailable); }
    }
}
