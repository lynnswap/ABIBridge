#include "ArchitectureFixtures.h"
#include <ABIBridge/Inspection.hpp>
#include <ABIBridge/NativeInvocation.hpp>
#include <ABIBridge/NativeDispatch.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <cstring>
#include <cstdlib>

namespace ABIArchitecture {
struct Large { long words[8]; };
__attribute__((noinline,used)) Large large(long value) {
    Large result{};
    for (long i = 0; i < 8; ++i) result.words[i] = value + i;
    return result;
}
struct Counter {
    int value = 40;
    __attribute__((noinline)) int add(int delta);
    virtual int current() const;
};
int Counter::add(int delta) { return value += delta; }
__attribute__((noinline)) int Counter::current() const { return value; }
__attribute__((noinline)) int virtualOracle(const Counter *value) { return value->current(); }
}

static const mach_header *ownHeader() {
    Dl_info info{};
    auto address = reinterpret_cast<const void *>(&ABIValidationCPUType);
#if __has_feature(ptrauth_calls)
    address = ptrauth_strip(address, ptrauth_key_function_pointer);
#endif
    dladdr(address, &info);
    return static_cast<const mach_header *>(info.dli_fbase);
}
uint32_t ABIValidationCPUType() { return ownHeader()->cputype; }
uint32_t ABIValidationCPUSubtype() { return ownHeader()->cpusubtype; }
bool ABIValidationPACCompiled() { return __has_feature(ptrauth_calls); }
__attribute__((noinline,used)) int32_t ABIValidationAdd(int32_t a, int32_t b) { return a + b; }
__attribute__((noinline,used)) ABIValidationLarge ABIValidationShiftLarge(ABIValidationLarge value) {
    return {value.a + 1, value.b + 2, value.c + 3, value.d + 4,
            value.e + 5, value.f + 6, value.g + 7, value.h + 8};
}
void *ABIValidationCreateCounter() { return new ABIArchitecture::Counter; }
void ABIValidationDeleteCounter(void *counter) { delete static_cast<ABIArchitecture::Counter *>(counter); }
uintptr_t ABIValidationCounterSize() { return sizeof(ABIArchitecture::Counter); }
uintptr_t ABIValidationCounterAlignment() { return alignof(ABIArchitecture::Counter); }
uintptr_t ABIValidationTableDiscriminator() {
#if __has_feature(ptrauth_calls)
    return ptrauth_string_discriminator("_ZTVN15ABIArchitecture7CounterE");
#else
    return 0;
#endif
}
uintptr_t ABIValidationSlotDiscriminator() {
#if __has_feature(ptrauth_calls)
    return ptrauth_string_discriminator("_ZNK15ABIArchitecture7Counter7currentEv");
#else
    return 0;
#endif
}
int32_t ABIValidationCounterOracle(const void *counter) {
    return ABIArchitecture::virtualOracle(static_cast<const ABIArchitecture::Counter *>(counter));
}
__attribute__((noinline,used)) int32_t ABIValidationCounterAdapter(void (*target)(void), void *counter, int32_t delta) {
    auto call = reinterpret_cast<int (*)(ABIArchitecture::Counter *, int)>(target);
    return call(static_cast<ABIArchitecture::Counter *>(counter), delta);
}
__attribute__((noinline)) void *ABIValidationAdvance(char *pointer, long offset) { return pointer + offset; }
__attribute__((noinline)) uintptr_t ABIValidationAdvanceInteger(uintptr_t pointer, uintptr_t offset) { return pointer + offset; }
void *ABIValidationAllocate() { return std::malloc(256); }
void ABIValidationDeallocate(void *pointer) { std::free(pointer); }

const char *ABIValidateNativeCalls() {
    using namespace abi_bridge;
    static thread_local std::string failure;
    try {
        if (ABIUsesPointerAuthentication() != ABIValidationPACCompiled()) return "Mixed authentication compilation settings";
        Runtime runtime;
        function<int32_t(int32_t,int32_t)> add(runtime.resolve({"ABIValidationAdd", language::c}));
        if (add.unsafe_invoke(20,22) != ABIValidationAdd(20,22)) return "C function mismatch";
        function<ABIArchitecture::Large(long)> large(runtime.resolve({"ABIArchitecture::large(long)"}));
        const auto actual = large.unsafe_invoke(35);
        const auto expected = ABIArchitecture::large(35);
        for (int i = 0; i < 8; ++i) {
            if (actual.words[i] != expected.words[i]) return "C++ indirect result mismatch";
        }
        auto owner = std::make_shared<ABIArchitecture::Counter>();
        std::weak_ptr<ABIArchitecture::Counter> weak = owner;
        method<int(int)> direct(runtime.resolve({"ABIArchitecture::Counter::add(int)"}));
        {
            auto bound = direct.bind(owner);
            owner.reset();
            if (weak.expired() || bound.unsafe_invoke(2) != 42) return "Bound receiver lifetime mismatch";
        }
        if (!weak.expired()) return "Bound receiver leak";

        ABIArchitecture::Counter receiver;
        auto* table = static_cast<const void *const *>(ABIUnsafeReadAuthenticatedPointer(
            &receiver, ABIAuthenticationDataA, ABIValidationTableDiscriminator(), true));
        ABIResolutionFailure *error = nullptr;
        std::unique_ptr<ABIVirtualCallTarget, decltype(&ABIReleaseVirtualCallTarget)> target(
            ABICopyVirtualCallTarget(table, ABIAuthenticationInstructionA, ABIValidationSlotDiscriminator(), true, &error),
            ABIReleaseVirtualCallTarget);
        if (!target) {
            failure = ABIResolutionFailureMessage(error);
            ABIReleaseResolutionFailure(error);
            return failure.c_str();
        }
        auto call = reinterpret_cast<int (*)(const ABIArchitecture::Counter*)>(ABIVirtualCallTargetFunction(target.get()));
        if (call(&receiver) != ABIArchitecture::virtualOracle(&receiver)) return "Authenticated virtual call mismatch";
        return nullptr;
    } catch (const std::exception& error) { failure = error.what(); return failure.c_str(); }
}

static void tamperTarget() {}
bool ABIValidateTamperedFunction() {
#if __has_feature(ptrauth_calls)
    auto function = &tamperTarget;
    uintptr_t bits = 0;
    std::memcpy(&bits, &function, sizeof(bits));
    const auto raw = reinterpret_cast<uintptr_t>(ptrauth_strip(function, ptrauth_key_function_pointer));
    const auto signedBits = bits ^ raw;
    if (!signedBits) return false;
    bits ^= signedBits & (~signedBits + 1);
    ABIResolutionFailure *error = nullptr;
    auto *target = ABICopyVirtualCallTarget(&bits, ABIAuthenticationInstructionA, 0, false, &error);
    if (!target) { ABIReleaseResolutionFailure(error); return false; }
    ABIVirtualCallTargetFunction(target)();
    ABIReleaseVirtualCallTarget(target);
    return true;
#else
    return false;
#endif
}
