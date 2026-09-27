#include "include/ArchitectureFixtures.h"
#include "VirtualMutation.hpp"
#include <ABIBridge/PointerSlot.h>
#include <ABIBridge/NativeDispatch.h>
#include <mach/mach.h>
#include <ptrauth.h>
#include <array>
#include <cstring>
#include <memory>
#include <mutex>

namespace {
using namespace ABIVTable;
using Target = std::unique_ptr<ABIVirtualCallTarget, decltype(&ABIReleaseVirtualCallTarget)>;
struct Context {
    std::mutex mutex;
    std::array<Target,3> original{{{nullptr,ABIReleaseVirtualCallTarget},{nullptr,ABIReleaseVirtualCallTarget},{nullptr,ABIReleaseVirtualCallTarget}}};
    std::array<unsigned,3> entered{};
    bool unrecovered = false;
};
// Fixture execution is quiescent and serialized. Retain predecessor owners if
// physical restoration fails; a published static entry must remain callable.
Context& context() { static auto *value = new Context; return *value; }
int replacementPrimary(const Primary *object, int input) {
    ++context().entered[0];
    auto call = reinterpret_cast<int(*)(const Primary*,int)>(ABIVirtualCallTargetFunction(context().original[0].get()));
    return call(object,input)+1000;
}
int replacementSecondary(const Secondary *object, int input) {
    ++context().entered[1];
    auto call = reinterpret_cast<int(*)(const Secondary*,int)>(ABIVirtualCallTargetFunction(context().original[1].get()));
    return call(object,input)+1000;
}
Secondary *replacementCovariant(Secondary *object) {
    ++context().entered[2];
    auto call = reinterpret_cast<Secondary*(*)(Secondary*)>(ABIVirtualCallTargetFunction(context().original[2].get()));
    return call(object);
}
bool protections(const void *slot, int32_t& protection, int32_t& maximum) {
    vm_address_t address = reinterpret_cast<vm_address_t>(slot);
    vm_size_t size = 0;
    natural_t depth = 0;
    vm_region_submap_short_info_data_64_t info{};
    while (true) {
        mach_msg_type_number_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
            reinterpret_cast<vm_region_recurse_info_t>(&info), &count) != KERN_SUCCESS) return false;
        if (info.is_submap) { ++depth; continue; }
        protection = info.protection; maximum = info.max_protection; return true;
    }
}
}

const char *ABIValidateVirtualEntry(uint32_t kind, ABIVirtualMutationProbeResult *report) {
    if (kind > 2 || !report) return "Invalid virtual mutation fixture request";
    *report = {};
    auto& state = context(); std::lock_guard lock(state.mutex);
    if (state.unrecovered) return "A previous virtual-entry fixture failed restoration";
    Derived first(40), second(100);
    auto *primary = static_cast<Primary*>(&first);
    auto *secondary = static_cast<Secondary*>(&first);
    report->secondaryOffset = reinterpret_cast<char*>(secondary)-reinterpret_cast<char*>(&first);
    if (!report->secondaryOffset || primaryOracle(primary,2)!=42 || secondaryOracle(secondary,2)!=62 || covariantOracle(secondary)!=secondary)
        return "Compiler virtual dispatch baseline mismatch";
    const void *table = kind == 0 ? __builtin_get_vtable_pointer(primary) : __builtin_get_vtable_pointer(secondary);
    const void *receiver = kind == 0 ? static_cast<void*>(primary) : static_cast<void*>(secondary);
    uintptr_t tableDiscriminator = 0, slotDiscriminator = 0;
#if __has_feature(ptrauth_calls)
    tableDiscriminator = kind == 0 ? ptrauth_string_discriminator("_ZTVN9ABIVTable7PrimaryE") : ptrauth_string_discriminator("_ZTVN9ABIVTable9SecondaryE");
    switch (kind) {
        case 0: slotDiscriminator = ptrauth_string_discriminator("_ZNK9ABIVTable7Primary5valueEi"); break;
        case 1: slotDiscriminator = ptrauth_string_discriminator("_ZNK9ABIVTable9Secondary8adjustedEi"); break;
        case 2: slotDiscriminator = ptrauth_string_discriminator("_ZN9ABIVTable9Secondary8identityEv"); break;
    }
#endif
    report->tableDiscriminator = tableDiscriminator; report->slotDiscriminator = slotDiscriminator;
    if (ABIUnsafeReadAuthenticatedPointer(receiver,ABIAuthenticationDataA,tableDiscriminator,true) != table)
        return "Explicit vptr schema disagrees with the compiler builtin";
    auto *words = static_cast<const uintptr_t*>(table);
    const size_t index = kind == 2 ? 1 : 0;
    auto *slot = const_cast<uintptr_t*>(words+index);
    const auto original = *slot;
    const auto headerOffset = words[-2], headerType = words[-1];
    const auto neighbor = words[kind == 2 ? 0 : 1];
    if (static_cast<intptr_t>(headerOffset) != (kind == 0 ? 0 : -report->secondaryOffset) || !headerType)
        return "Secondary address point or RTTI header mismatch";
    ABIResolutionFailure *error = nullptr;
    Target predecessor(ABICopyVirtualCallTarget(slot,ABIAuthenticationInstructionA,slotDiscriminator,true,&error),ABIReleaseVirtualCallTarget);
    if (!predecessor) { ABIReleaseResolutionFailure(error); return "Could not capture virtual predecessor"; }
    state.original[kind] = std::move(predecessor);
    if (kind == 0 && reinterpret_cast<int(*)(const Primary*,int)>(ABIVirtualCallTargetFunction(state.original[kind].get()))(primary,2)!=42)
        return "Primary predecessor mismatch";
    if (kind == 1 && reinterpret_cast<int(*)(const Secondary*,int)>(ABIVirtualCallTargetFunction(state.original[kind].get()))(secondary,2)!=62)
        return "Receiver-adjustment thunk mismatch";
    if (kind == 2 && reinterpret_cast<Secondary*(*)(Secondary*)>(ABIVirtualCallTargetFunction(state.original[kind].get()))(secondary)!=secondary)
        return "Covariant return thunk mismatch";
    const ABIUnmanagedFunction replacement = kind == 0 ? reinterpret_cast<ABIUnmanagedFunction>(&replacementPrimary)
        : kind == 1 ? reinterpret_cast<ABIUnmanagedFunction>(&replacementSecondary) : reinterpret_cast<ABIUnmanagedFunction>(&replacementCovariant);
    uintptr_t encoded = 0;
    if (!ABIEncodePointerSlotFunction(replacement,slot,ABIAuthenticationInstructionA,slotDiscriminator,true,&encoded)) return "Could not encode virtual replacement";
    const auto entered = state.entered[kind];
    report->publication = ABICompareExchangePointerSlot(slot,original,encoded);
    const auto delta = report->publication.didWrite ? 1000 : 0;
    const bool callsMatch = primaryOracle(&first,2) == 42+(kind==0 ? delta : 0)
        && primaryOracle(&second,2) == 102+(kind==0 ? delta : 0)
        && secondaryOracle(&first,2) == 62+(kind==1 ? delta : 0)
        && secondaryOracle(&second,2) == 122+(kind==1 ? delta : 0)
        && covariantOracle(&first) == static_cast<Secondary*>(&first)
        && covariantOracle(&second) == static_cast<Secondary*>(&second)
        && directOracle(&first,2)==42 && first.Derived::value(2)==42;
    const bool headersMatch = words[-2]==headerOffset && words[-1]==headerType && words[kind == 2 ? 0 : 1]==neighbor
        && dynamic_cast<void*>(secondary)==&first;
    const bool callbackCount = state.entered[kind] == entered + (report->publication.didWrite ? 2 : 0);
    if (report->publication.didWrite) {
        report->restoration = ABICompareExchangePointerSlot(slot,encoded,original);
        if (report->restoration.status!=ABIPointerSlotComplete) { state.unrecovered=true; return "Virtual-entry physical restoration failed"; }
    } else if (report->publication.status!=ABIPointerSlotProtectFailed) return "Unexpected virtual-entry publication failure";
    if (!callsMatch || !headersMatch || !callbackCount) return "Virtual replacement changed dispatch, receiver, return or header behavior";
    if (*slot != original || primaryOracle(&first,2)!=42 || secondaryOracle(&first,2)!=62 || covariantOracle(&first)!=secondary)
        return "Virtual dispatch was not preserved after restoration/refusal";
    if (!protections(slot,report->protectionAfter,report->maximumAfter)
        || report->protectionAfter!=report->publication.protectionBefore || report->maximumAfter!=report->publication.maximumBefore)
        return "Virtual-entry protections were not restored";
    if (report->publication.didWrite && report->publication.status!=ABIPointerSlotComplete) return "Virtual publication had incomplete protection cleanup";
    return nullptr;
}
