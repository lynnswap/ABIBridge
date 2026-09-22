#include <ABIBridge/NativeDispatch.h>
#include <ptrauth.h>
#include <dlfcn.h>
#include <cstring>
#include <memory>

struct ABIVirtualCallTarget {
    ABIUnmanagedFunction function = nullptr;
    std::unique_ptr<ABIImageLease, decltype(&ABIReleaseImage)> image{nullptr, ABIReleaseImage};
};

namespace {
void fail(ABIResolutionFailure **error, int32_t code, const char *message) {
    if (error) *error = ABICreateResolutionFailure(code, message);
}

bool validKey(int32_t key) {
    return key >= ABIAuthenticationUnsigned && key <= ABIAuthenticationDataB;
}

#if __has_feature(ptrauth_calls)
uintptr_t modifier(const void *storage, uintptr_t discriminator, bool addressDiversity) {
    return addressDiversity ? ptrauth_blend_discriminator(storage, discriminator) : discriminator;
}
#endif

ABIUnmanagedFunction authenticateFunction(
    uintptr_t bits, const void *storage, int32_t key, uintptr_t discriminator, bool addressDiversity)
{
    if (key == ABIAuthenticationUnsigned) {
        return ABIUnsafeFunctionAtAddress(reinterpret_cast<const void *>(bits));
    }
    ABIUnmanagedFunction function;
    static_assert(sizeof(function) == sizeof(bits));
    std::memcpy(&function, &bits, sizeof(function));
#if __has_feature(ptrauth_calls)
    const auto extra = modifier(storage, discriminator, addressDiversity);
#define AUTHENTICATE_FUNCTION(KEY) \
    return ptrauth_auth_and_resign(function, KEY, extra, ptrauth_key_function_pointer, \
        ptrauth_function_pointer_type_discriminator(void(void)))
    switch (key) {
        case ABIAuthenticationInstructionA: AUTHENTICATE_FUNCTION(ptrauth_key_asia);
        case ABIAuthenticationInstructionB: AUTHENTICATE_FUNCTION(ptrauth_key_asib);
        case ABIAuthenticationDataA: AUTHENTICATE_FUNCTION(ptrauth_key_asda);
        case ABIAuthenticationDataB: AUTHENTICATE_FUNCTION(ptrauth_key_asdb);
    }
#undef AUTHENTICATE_FUNCTION
#endif
    return function;
}
}

bool ABIUsesPointerAuthentication() {
#if __has_feature(ptrauth_calls)
    return true;
#else
    return false;
#endif
}

const void *ABIUnsafeReadAuthenticatedPointer(
    const void *storage, int32_t key, uintptr_t discriminator, bool addressDiversity)
{
    if (!storage || !validKey(key)) return nullptr;
    const void *pointer;
    std::memcpy(&pointer, storage, sizeof(pointer));
    if (!pointer || key == ABIAuthenticationUnsigned) return pointer;
#if __has_feature(ptrauth_calls)
    const auto extra = modifier(storage, discriminator, addressDiversity);
    switch (key) {
        case ABIAuthenticationInstructionA: return ptrauth_auth_data(pointer, ptrauth_key_asia, extra);
        case ABIAuthenticationInstructionB: return ptrauth_auth_data(pointer, ptrauth_key_asib, extra);
        case ABIAuthenticationDataA: return ptrauth_auth_data(pointer, ptrauth_key_asda, extra);
        case ABIAuthenticationDataB: return ptrauth_auth_data(pointer, ptrauth_key_asdb, extra);
    }
#endif
    return pointer;
}

ABIVirtualCallTarget *ABICopyVirtualCallTarget(
    const void *storage, int32_t key, uintptr_t discriminator, bool addressDiversity,
    ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (!storage || !validKey(key)) {
        fail(error, ABIFailureInvalidRequest, "A readable function slot and authentication schema are required.");
        return nullptr;
    }
    uintptr_t bits = 0;
    std::memcpy(&bits, storage, sizeof(bits));
    if (!bits) {
        fail(error, ABIFailureInvalidAddress, "The virtual table entry is null.");
        return nullptr;
    }
    auto target = std::make_unique<ABIVirtualCallTarget>();
    target->function = authenticateFunction(bits, storage, key, discriminator, addressDiversity);

    // Strip only for loader lookup. Calls use the authenticated/resigned value,
    // preserving authentication failure instead of turning it into a valid signature.
    const void *address = ABIFunctionPointerBits(target->function);
#if __has_feature(ptrauth_calls)
    address = ptrauth_strip(address, ptrauth_key_function_pointer);
#endif
    Dl_info info{};
    if (dladdr(address, &info) && info.dli_fbase) {
        std::unique_ptr<ABIImageList, decltype(&ABIFreeImageList)> images(ABICopyLoadedImages(), ABIFreeImageList);
        if (!images) {
            fail(error, ABIFailureImageUnavailable, "The loaded image catalog is unavailable.");
            return nullptr;
        }
        for (size_t index = 0; index < ABIImageListCount(images.get()); ++index) {
            const auto image = ABIImageListGet(images.get(), index);
            if (image.header != reinterpret_cast<uintptr_t>(info.dli_fbase)) continue;
            target->image.reset(ABIRetainLoadedImage(image.generation));
            break;
        }
        if (!target->image) {
            fail(error, ABIFailureImageChanged, "The virtual implementation image could not be retained.");
            return nullptr;
        }
    }
    return target.release();
}

void ABIReleaseVirtualCallTarget(ABIVirtualCallTarget *target) { delete target; }
ABIUnmanagedFunction ABIVirtualCallTargetFunction(const ABIVirtualCallTarget *target) { return target->function; }
const void *ABIFunctionPointerBits(ABIUnmanagedFunction function) {
    const void *bits;
    static_assert(sizeof(bits) == sizeof(function));
    std::memcpy(&bits, &function, sizeof(bits));
    return bits;
}
