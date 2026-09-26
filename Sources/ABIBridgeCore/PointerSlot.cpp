#include "PointerSlotMutation.hpp"
#include <mutex>
#include <ptrauth.h>
#include <cstring>

namespace {
std::mutex slotWriter;
struct Memory {
    kern_return_t query(uintptr_t slot, abibridge::SlotRegion& region) {
        vm_address_t address = slot;
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_short_info_data_64_t info{};
        while (true) {
            address = slot;
            mach_msg_type_number_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
            auto code = vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                reinterpret_cast<vm_region_recurse_info_t>(&info), &count);
            if (code != KERN_SUCCESS) return code;
            if (address > slot || slot - address >= size || sizeof(uintptr_t) > size - (slot - address)) return KERN_INVALID_ADDRESS;
            if (info.is_submap) { ++depth; continue; }
            region = {info.protection, info.max_protection, info.flags};
            return KERN_SUCCESS;
        }
    }
    kern_return_t read(uintptr_t address, uintptr_t& value) {
        vm_size_t size = 0;
        const auto code = vm_read_overwrite(mach_task_self(), address, sizeof(value), reinterpret_cast<vm_address_t>(&value), &size);
        return code != KERN_SUCCESS ? code : size == sizeof(value) ? KERN_SUCCESS : KERN_INVALID_ADDRESS;
    }
    kern_return_t protect(uintptr_t address, bool maximum, vm_prot_t protection) {
        return vm_protect(mach_task_self(), address - address % vm_page_size, vm_page_size, maximum, protection);
    }
    bool exchange(uintptr_t address, uintptr_t& expected, uintptr_t replacement) {
        return __atomic_compare_exchange_n(reinterpret_cast<uintptr_t *>(address), &expected, replacement,
            false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    }
};
}

ABIPointerSlotResult ABICompareExchangePointerSlot(void *storage, uintptr_t expected, uintptr_t replacement) {
    std::lock_guard lock(slotWriter);
    Memory memory;
    return abibridge::exchangePointerSlot(memory, reinterpret_cast<uintptr_t>(storage), expected, replacement);
}

bool ABIEncodePointerSlotFunction(ABIUnmanagedFunction function, const void *storage,
    int32_t key, uintptr_t discriminator, bool addressDiversity, uintptr_t *bits) {
    if (!storage || !bits || key < ABIAuthenticationUnsigned || key > ABIAuthenticationDataB) return false;
    if (!function) { *bits = 0; return true; }
    auto *pointer = const_cast<void *>(ABIFunctionPointerBits(function));
#if __has_feature(ptrauth_calls)
    constexpr auto source = ptrauth_function_pointer_type_discriminator(void(void));
    const auto target = addressDiversity ? ptrauth_blend_discriminator(storage, discriminator) : discriminator;
#define SIGN_SLOT(KEY) pointer = ptrauth_auth_and_resign(pointer, ptrauth_key_function_pointer, source, KEY, target); break
    switch (key) {
        case ABIAuthenticationInstructionA: SIGN_SLOT(ptrauth_key_asia);
        case ABIAuthenticationInstructionB: SIGN_SLOT(ptrauth_key_asib);
        case ABIAuthenticationDataA: SIGN_SLOT(ptrauth_key_asda);
        case ABIAuthenticationDataB: SIGN_SLOT(ptrauth_key_asdb);
        case ABIAuthenticationUnsigned: pointer = ptrauth_auth_data(pointer, ptrauth_key_function_pointer, source); break;
    }
#undef SIGN_SLOT
#endif
    std::memcpy(bits, &pointer, sizeof(pointer));
    return true;
}
