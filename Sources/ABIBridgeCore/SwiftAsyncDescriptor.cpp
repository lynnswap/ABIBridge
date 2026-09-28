#include <ABIBridge/SwiftInvocation.h>
#include <ABIBridge/NativeDispatch.h>
#include <ABIBridge/Memory.h>
#include "ImageOwner.hpp"
#include <ptrauth.h>
#include <limits>
#include <memory>

struct ABISwiftAsyncDescriptor {
    std::unique_ptr<ABIImageLease, decltype(&ABIReleaseImage)> image{nullptr, ABIReleaseImage};
    std::unique_ptr<ABIVirtualCallTarget, decltype(&ABIReleaseVirtualCallTarget)> entry{nullptr, ABIReleaseVirtualCallTarget};
    uint32_t contextSize = 0;
};

const void *ABIAuthenticateSwiftAsyncClosureDescriptor(const void *descriptor, uint16_t discriminator) {
    if (!descriptor) return nullptr;
#if __has_feature(ptrauth_calls)
    descriptor = ptrauth_auth_data(descriptor, ptrauth_key_process_independent_data, discriminator);
#endif
    return descriptor;
}
const void *ABISignSwiftAsyncClosureDescriptor(const void *descriptor, uint16_t discriminator) {
    if (!descriptor) return nullptr;
#if __has_feature(ptrauth_calls)
    descriptor = ptrauth_sign_unauthenticated(descriptor, ptrauth_key_process_independent_data, discriminator);
#endif
    return descriptor;
}

ABISwiftAsyncDescriptor *ABICopySwiftAsyncDescriptor(const void *descriptor, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    auto result = std::make_unique<ABISwiftAsyncDescriptor>();
    ABIResolutionFailure *failure = nullptr;
    result->image.reset(abibridge::copyContainingImage(descriptor, &failure));
    if (failure) {
        if (error) *error = failure; else ABIReleaseResolutionFailure(failure);
        return nullptr;
    }
    struct { int32_t entry; uint32_t contextSize; } fields;
    const auto base = reinterpret_cast<uintptr_t>(descriptor);
    const auto read = ABIReadMemory(base, sizeof(fields), &fields);
    if (read.status != ABIMemoryReadComplete) {
        if (error) *error = ABICreateResolutionFailure(ABIFailureInvalidAddress, "The Swift async descriptor could not be read.");
        return nullptr;
    }
    if (fields.contextSize < 2 * sizeof(void *)) {
        if (error) *error = ABICreateResolutionFailure(ABIFailureInvalidRequest, "The Swift async context cannot hold its parent and continuation.");
        return nullptr;
    }
    const auto magnitude = fields.entry < 0 ? uintptr_t(-int64_t(fields.entry)) : uintptr_t(fields.entry);
    if ((fields.entry < 0 && base < magnitude) ||
        (fields.entry >= 0 && magnitude > std::numeric_limits<uintptr_t>::max() - base)) {
        if (error) *error = ABICreateResolutionFailure(ABIFailureInvalidAddress, "The Swift async entry address overflows.");
        return nullptr;
    }
    const auto address = fields.entry < 0 ? base - magnitude : base + magnitude;
    result->entry.reset(ABICopyFunctionTarget(ABIUnsafeFunctionAtAddress(reinterpret_cast<const void *>(address)), error));
    if (!result->entry) return nullptr;
    result->contextSize = fields.contextSize;
    return result.release();
}
ABIUnmanagedFunction ABISwiftAsyncDescriptorFunction(const ABISwiftAsyncDescriptor *descriptor) {
    return ABIVirtualCallTargetFunction(descriptor->entry.get());
}
uint32_t ABISwiftAsyncDescriptorContextSize(const ABISwiftAsyncDescriptor *descriptor) { return descriptor->contextSize; }
void ABIReleaseSwiftAsyncDescriptor(ABISwiftAsyncDescriptor *descriptor) { delete descriptor; }
