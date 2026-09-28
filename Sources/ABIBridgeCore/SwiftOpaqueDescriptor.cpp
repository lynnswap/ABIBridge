#include <ABIBridge/SwiftInvocation.h>
#include <cstdint>
#include <cstring>
#include <ptrauth.h>

// RelativeTargetProtocolDescriptorPointer uses bit 0 for indirection and bit 1
// for ObjC. Indirect Swift descriptors use the address-diverse TypeDescriptor
// schema from Swift Runtime/Config.h and ABI/MetadataValues.h.
bool ABISwiftProtocolRequirementIsClassBound(const void *reference) {
    int32_t offset;
    std::memcpy(&offset, reference, sizeof(offset));
    if (offset & 2) return true;
    const void *descriptor = reinterpret_cast<const void *>(reinterpret_cast<uintptr_t>(reference) + intptr_t(offset & ~3));
    if (offset & 1) {
        const void *slot = descriptor;
        std::memcpy(&descriptor, slot, sizeof(descriptor));
#if __has_feature(ptrauth_calls)
        descriptor = ptrauth_auth_data(descriptor, ptrauth_key_process_independent_data,
                                      ptrauth_blend_discriminator(slot, 0xae86));
#endif
    }
    uint32_t flags;
    std::memcpy(&flags, descriptor, sizeof(flags));
    // ProtocolClassConstraint::Class is zero; the set bit means unrestricted.
    return (flags & 0x10000) == 0;
}
