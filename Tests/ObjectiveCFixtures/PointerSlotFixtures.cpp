#include "include/PointerSlotFixtures.h"
#include "../../Sources/ABIBridgeCore/PointerSlotMutation.hpp"
#include <vector>
#include <utility>

namespace {
struct Memory {
    abibridge::SlotRegion region{VM_PROT_READ, VM_PROT_READ | VM_PROT_WRITE, 0};
    uintptr_t value = 41;
    kern_return_t queryError = 0, readError = 0;
    std::vector<kern_return_t> protectionResults;
    std::vector<std::pair<bool, vm_prot_t>> requests;
    bool displaced = false;
    int exchanges = 0;
    kern_return_t query(uintptr_t, abibridge::SlotRegion& output) { output = region; return queryError; }
    kern_return_t read(uintptr_t, uintptr_t& output) { output = value; return readError; }
    kern_return_t protect(uintptr_t, bool maximum, vm_prot_t permissions) {
        const auto index = requests.size();
        requests.emplace_back(maximum, permissions);
        return index < protectionResults.size() ? protectionResults[index] : KERN_SUCCESS;
    }
    bool exchange(uintptr_t, uintptr_t& expected, uintptr_t replacement) {
        ++exchanges;
        if (displaced) value = 99;
        if (value != expected) { expected = value; return false; }
        value = replacement;
        return true;
    }
    ABIPointerSlotResult run() { return abibridge::exchangePointerSlot(*this, 0x4000, 41, 42); }
};
}

const char *ABITestPointerSlotRecovery() {
    {
        Memory m; m.queryError = KERN_INVALID_ADDRESS;
        const auto r = m.run();
        if (r.status != ABIPointerSlotQueryFailed || r.systemErrorCode != KERN_INVALID_ADDRESS || !m.requests.empty() || r.didWrite)
            return "Query failure must not mutate";
    }
    {
        Memory m; m.readError = KERN_PROTECTION_FAILURE;
        const auto r = m.run();
        if (r.status != ABIPointerSlotReadFailed || r.systemErrorCode != KERN_PROTECTION_FAILURE || !m.requests.empty() || r.didWrite)
            return "Read failure must not mutate";
    }
    {
        Memory m; m.value = 99;
        const auto r = m.run();
        if (r.status != ABIPointerSlotDisplaced || r.observed != 99 || r.didWrite || !m.requests.empty())
            return "Preexisting displacement must not change protection";
    }
    {
        Memory m; m.region.protection |= VM_PROT_WRITE;
        const auto r = m.run();
        if (r.status != ABIPointerSlotComplete || !r.didWrite || m.value != 42 || !m.requests.empty())
            return "Writable data needs no protection change";
    }
    {
        Memory m;
        const auto r = m.run();
        if (r.status != ABIPointerSlotComplete || !r.didWrite || m.requests != std::vector<std::pair<bool, vm_prot_t>>{{false, 3}, {false, 1}})
            return "Read-only mutation must restore its original protection";
    }
    {
        Memory m; m.region.flags = VM_REGION_FLAG_TPRO_ENABLED; m.protectionResults = {KERN_PROTECTION_FAILURE};
        const auto r = m.run();
        if (r.status != ABIPointerSlotProtectFailed || r.systemErrorCode != KERN_PROTECTION_FAILURE || r.didWrite || m.exchanges != 0 || m.requests.size() != 1)
            return "Rejected write permission must not publish a pointer";
    }
    {
        Memory m; m.region.maximum = VM_PROT_READ;
        const auto r = m.run();
        if (r.status != ABIPointerSlotComplete || !r.didWrite || m.requests != std::vector<std::pair<bool, vm_prot_t>>{{false, 3 | VM_PROT_COPY}, {false, 1}, {true, 1}})
            return "Copy-on-write must restore current and maximum protections";
    }
    for (bool displaced : {false, true}) {
        Memory m; m.region.maximum = VM_PROT_READ; m.displaced = displaced;
        m.protectionResults = {KERN_SUCCESS, KERN_INVALID_ADDRESS, KERN_PROTECTION_FAILURE};
        const auto r = m.run();
        if (r.status != (displaced ? ABIPointerSlotDisplaced : ABIPointerSlotRestoreFailed) || r.didWrite == displaced
            || r.restoreProtectionError != KERN_INVALID_ADDRESS || r.restoreMaximumError != KERN_PROTECTION_FAILURE
            || m.requests.size() != 3 || m.value != (displaced ? 99u : 42u))
            return "Publication/displacement and both restoration failures must survive together";
    }
    {
        Memory m; m.region = {3, 3, 0};
        auto r = abibridge::restorePointerSlotProtection(m, 0x4000, 41, 1, 1, true, true);
        if (r.status || r.didWrite || m.exchanges || m.requests != std::vector<std::pair<bool, vm_prot_t>>{{false, 1}, {true, 1}})
            return "Protection repair must leave the pointer alone and restore both requested protections";
    }
    {
        Memory m; m.value = 99;
        auto r = abibridge::restorePointerSlotProtection(m, 0x4000, 41, 1, 1, true, true);
        if (r.status != ABIPointerSlotDisplaced || !m.requests.empty())
            return "Protection repair must not overwrite a displaced slot's protections";
    }
    {
        Memory m; m.region = {3, 3, 0}; m.protectionResults = {KERN_INVALID_ADDRESS, KERN_PROTECTION_FAILURE};
        auto r = abibridge::restorePointerSlotProtection(m, 0x4000, 41, 1, 1, true, true);
        if (r.status != ABIPointerSlotRestoreFailed || r.restoreProtectionError != KERN_INVALID_ADDRESS
            || r.restoreMaximumError != KERN_PROTECTION_FAILURE || r.didWrite)
            return "Protection repair must preserve both failures";
    }
    return nullptr;
}
