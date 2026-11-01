#include "ArchitectureFixtures.h"
#include <ABIBridge/Backend/PointerSlot.h>
#include <ABIBridge/Memory.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <unistd.h>
#include <cstring>
#include <mutex>
#include <string>

namespace {
using Function = int32_t (*)();
std::mutex probeMutex;
Function predecessor = nullptr;
thread_local std::string diagnostic;
__attribute__((noinline)) int32_t replacement() { return predecessor() + 1; }
__attribute__((noinline)) int32_t controlOriginal() { return 41; }

void *raw(Function value) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(reinterpret_cast<void *>(value), ptrauth_key_function_pointer);
#else
    return reinterpret_cast<void *>(value);
#endif
}

uintptr_t discriminator(void *slot, uintptr_t extra, bool addressDiversity) {
    return addressDiversity ? ptrauth_blend_discriminator(slot, extra) : extra;
}

void *encode(Function value, void *slot, int32_t key, uintptr_t extra, bool addressDiversity) {
    auto *address = raw(value);
#if __has_feature(ptrauth_calls)
    const auto salt = discriminator(slot, extra, addressDiversity);
    switch (key) {
        case 0: return ptrauth_sign_unauthenticated(address, ptrauth_key_asia, salt);
        case 1: return ptrauth_sign_unauthenticated(address, ptrauth_key_asib, salt);
        case 2: return ptrauth_sign_unauthenticated(address, ptrauth_key_asda, salt);
        case 3: return ptrauth_sign_unauthenticated(address, ptrauth_key_asdb, salt);
    }
#endif
    return address;
}

Function decode(void *value, void *slot, int32_t key, uintptr_t extra, bool addressDiversity) {
#if __has_feature(ptrauth_calls)
    const auto salt = discriminator(slot, extra, addressDiversity);
    constexpr auto callSalt = ptrauth_function_pointer_type_discriminator(int32_t(void));
    switch (key) {
        case 0: value = ptrauth_auth_and_resign(value, ptrauth_key_asia, salt, ptrauth_key_function_pointer, callSalt); break;
        case 1: value = ptrauth_auth_and_resign(value, ptrauth_key_asib, salt, ptrauth_key_function_pointer, callSalt); break;
        case 2: value = ptrauth_auth_and_resign(value, ptrauth_key_asda, salt, ptrauth_key_function_pointer, callSalt); break;
        case 3: value = ptrauth_auth_and_resign(value, ptrauth_key_asdb, salt, ptrauth_key_function_pointer, callSalt); break;
        default: value = ptrauth_sign_unauthenticated(value, ptrauth_key_function_pointer, callSalt); break;
    }
#endif
    return reinterpret_cast<Function>(value);
}

kern_return_t protection(void *slot, vm_region_submap_short_info_data_64_t& info) {
    auto address = reinterpret_cast<vm_address_t>(slot);
    vm_size_t size = 0;
    natural_t depth = 0;
    while (true) {
        mach_msg_type_number_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
        const auto code = vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
            reinterpret_cast<vm_region_recurse_info_t>(&info), &count);
        if (code != KERN_SUCCESS || !info.is_submap) return code;
        ++depth;
    }
}

// This fixture changes one pointer in a known in-process data page. It does
// not provide synchronization with unrelated interposers or production callers.
std::string exercise(void *slot, int32_t key, uintptr_t extra, bool diverse,
    Function oracle, ABIImportProbeResult& result, bool nested = false) {
    result = {};
    const auto baseline = oracle(); // Bind a lazy import before capturing it.
    const auto unrelated = getpid();
    void *original = nullptr;
    std::memcpy(&original, slot, sizeof(original));
    predecessor = decode(original, slot, key, extra, diverse);
    if (predecessor() != baseline) return "Captured predecessor differs from the compiler-generated call";
    vm_region_submap_short_info_data_64_t before{};
    auto code = protection(slot, before);
    if (code != KERN_SUCCESS) return "Read protection failed: " + std::to_string(code);
    result.protectionBefore = before.protection;
    result.maximumBefore = before.max_protection;
    result.regionFlags = before.flags;
    uintptr_t replacementBits = 0;
    if (!ABIEncodePointerSlotFunction(reinterpret_cast<ABIUnmanagedFunction>(replacement), slot, key, extra, diverse, &replacementBits))
        return "Replacement signing schema was rejected";
#if defined(__arm64__) && defined(__LP64__)
    uint64_t states[2]{}, savedState = 0;
    const bool checkThreadState = (before.flags & VM_REGION_FLAG_TPRO_ENABLED)
        && ABIReadMemory(UINT64_C(0x0000000fffffc0d0), sizeof(states), states).status == ABIMemoryReadComplete
        && states[0] && states[1] && (states[0] ^ states[1]) == (UINT64_C(1) << 36);
    if (checkThreadState) __asm__ volatile("mrs %0, S3_6_C15_C1_5" : "=r"(savedState) :: "memory");
#endif
    const auto changed = ABICompareExchangePointerSlot(slot, reinterpret_cast<uintptr_t>(original), replacementBits);
#if defined(__arm64__) && defined(__LP64__)
    uint64_t publishedState = savedState;
    if (checkThreadState) __asm__ volatile("mrs %0, S3_6_C15_C1_5" : "=r"(publishedState) :: "memory");
#endif
    result.protectionResult = changed.systemErrorCode;
    std::string failure;
    if (changed.didWrite) {
        result.changed = oracle() == baseline + 1;
        const auto conflict = ABICompareExchangePointerSlot(slot, reinterpret_cast<uintptr_t>(original), replacementBits);
        if (conflict.status != ABIPointerSlotDisplaced || conflict.didWrite || conflict.observed != replacementBits)
            failure += "A competing pointer representation was not preserved; ";
        const auto restored = ABICompareExchangePointerSlot(slot, replacementBits, reinterpret_cast<uintptr_t>(original));
        if (!result.changed) failure += "Compiler-generated call did not use the replacement; ";
        if (changed.status != ABIPointerSlotComplete || restored.status != ABIPointerSlotComplete) {
            failure += "Mutation/recovery failed: " + std::to_string(changed.status) + "/" + std::to_string(restored.status)
                + " restore current=" + std::to_string(changed.restoreProtectionError) + "/" + std::to_string(restored.restoreProtectionError)
                + " restore maximum=" + std::to_string(changed.restoreMaximumError) + "/" + std::to_string(restored.restoreMaximumError) + "; ";
        }
    } else if (changed.status != ABIPointerSlotProtectFailed || changed.systemErrorCode != KERN_NOT_SUPPORTED
        || !(before.flags & VM_REGION_FLAG_TPRO_ENABLED)) {
        failure += "Slot mutation failed unexpectedly: " + std::to_string(changed.status) + "/" + std::to_string(changed.systemErrorCode) + "; ";
    }
    // Unavailable controls are a distinct outcome, not a successful rebind.
    // Both outcomes must leave the original representation and protections intact.
    vm_region_submap_short_info_data_64_t after{};
    const auto readAfter = protection(slot, after);
    result.protectionAfter = after.protection;
    result.maximumAfter = after.max_protection;
    if (getpid() != unrelated) failure += "Unrelated import changed; ";
    if (oracle() != baseline) failure += "Original call was not restored; ";
    void *restored = nullptr;
    std::memcpy(&restored, slot, sizeof(restored));
    if (restored != original) failure += "Original slot representation was not restored; ";
    if (readAfter != KERN_SUCCESS) failure += "Read final protection failed: " + std::to_string(readAfter) + "; ";
    else if (after.protection != before.protection || after.max_protection != before.max_protection
        || after.flags != before.flags) failure += "Final page protection differs; ";
#if defined(__arm64__) && defined(__LP64__)
    if (checkThreadState) {
        uint64_t restoredState;
        __asm__ volatile("mrs %0, S3_6_C15_C1_5" : "=r"(restoredState) :: "memory");
        if (publishedState != savedState || restoredState != savedState)
            failure += "Pointer mutation changed the caller's full TPRO register state; ";
        if (!result.changed) failure += "Supported TPRO storage was not replaced; ";
        if (!nested && failure.empty()) {
            struct RestoreState {
                uint64_t value;
                ~RestoreState() { __asm__ volatile("msr S3_6_C15_C1_5, %0\n\tisb" :: "r"(value) : "memory"); }
            } restore{savedState};
            const auto mask = states[0] ^ states[1];
            const auto writable = (savedState & ~mask) | (states[0] & mask);
            __asm__ volatile("msr S3_6_C15_C1_5, %0\n\tisb" :: "r"(writable) : "memory");
            ABIImportProbeResult nestedResult{};
            failure += exercise(slot, key, extra, diverse, oracle, nestedResult, true);
        }
        uint64_t finalState;
        __asm__ volatile("mrs %0, S3_6_C15_C1_5" : "=r"(finalState) :: "memory");
        if (finalState != savedState) failure += "Nested validation changed the caller's TPRO state; ";
        result.threadStateVerified = failure.empty();
    }
#endif
    return failure;
}

void *controlSlot = nullptr;
int32_t controlKey = 0;
__attribute__((noinline)) int32_t controlOracle() {
    void *value = nullptr;
    std::memcpy(&value, controlSlot, sizeof(value));
    return decode(value, controlSlot, controlKey, 0x1234, true)();
}
}

__attribute__((noinline)) int32_t ABIImportProbeCall() { return getppid(); }
const void *ABIImportProbeImage() {
    Dl_info info{};
    return dladdr(raw(ABIImportProbeCall), &info) ? info.dli_fbase : nullptr;
}
const char *ABIValidateImportSlot(void *slot, int32_t key, uintptr_t extra, bool diverse,
    ABIImportProbeResult *result) {
    std::lock_guard lock(probeMutex);
    diagnostic = exercise(slot, key, extra, diverse, ABIImportProbeCall, *result);
    return diagnostic.empty() ? nullptr : diagnostic.c_str();
}
const char *ABIValidateReadOnlySignedSlot(ABIImportProbeResult *result) {
    std::lock_guard lock(probeMutex);
    vm_address_t page = 0;
    auto code = vm_allocate(mach_task_self(), &page, vm_page_size, VM_FLAGS_ANYWHERE);
    if (code != KERN_SUCCESS) {
        diagnostic = "Allocate control page failed: " + std::to_string(code);
        return diagnostic.c_str();
    }
    controlSlot = reinterpret_cast<void *>(page + 64);
    diagnostic.clear();
    for (controlKey = ABIAuthenticationUnsigned; controlKey <= ABIAuthenticationDataB; ++controlKey) {
        code = vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE);
        if (code != KERN_SUCCESS) { diagnostic = "Unprotect control page failed: " + std::to_string(code); break; }
        auto *initial = encode(controlOriginal, controlSlot, controlKey, 0x1234, true);
        std::memcpy(controlSlot, &initial, sizeof(initial));
        code = vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ);
        diagnostic = code == KERN_SUCCESS ? exercise(controlSlot, controlKey, 0x1234, true, controlOracle, *result)
            : "Protect control page failed: " + std::to_string(code);
        if (!diagnostic.empty()) break;
    }
    const auto cleanup = vm_deallocate(mach_task_self(), page, vm_page_size);
    if (cleanup != KERN_SUCCESS) diagnostic += " Deallocate control page failed: " + std::to_string(cleanup);
    controlSlot = nullptr;
    return diagnostic.empty() ? nullptr : diagnostic.c_str();
}
