#include <ABIBridge/SwiftInvocation.h>
#include <cstdint>
#include <cstring>
#include <ptrauth.h>
#include <string_view>
#include <unordered_set>

// The runtime entry points and descriptor layouts are part of Swift's ABI.
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/Runtime/RuntimeFunctions.def
namespace {
struct MetadataResponse { const void *value; uintptr_t state; };
}
extern "C" const void *swift_conformsToProtocol(const void *, const void *);
extern "C" MetadataResponse __attribute__((swiftcall))
swift_getAssociatedTypeWitness(uintptr_t, const void *, const void *, const void *, const void *);
extern "C" MetadataResponse __attribute__((swiftcall))
swift_getGenericMetadata(uintptr_t, const void *const *, const void *);
extern "C" const void *__attribute__((swiftcall))
swift_getTypeByMangledNameInContext(const char *, size_t, const void *, const void *const *);

namespace {
template<class T> T read(const void *address) {
    T result;
    std::memcpy(&result, address, sizeof(result));
    return result;
}
const char *relative(const void *field) {
    auto offset = read<int32_t>(field);
    return offset ? static_cast<const char *>(field) + offset : nullptr;
}

const void *associatedType(const void *metadata, const void *protocol,
                           std::string_view name, std::unordered_set<const void *> &visited) {
    if (!visited.insert(protocol).second) return nullptr;
    auto descriptor = static_cast<const char *>(protocol);
    const uint32_t signatureCount = read<uint32_t>(descriptor + 12);
    const uint32_t requirementCount = read<uint32_t>(descriptor + 16);
    const char *requirements = descriptor + 24 + signatureCount * 12;
    if (const char *names = relative(descriptor + 20)) {
        std::string_view remaining(names);
        uint32_t associatedIndex = 0;
        while (!remaining.empty()) {
            const auto separator = remaining.find(' ');
            if (remaining.substr(0, separator) == name) {
                uint32_t current = 0;
                for (uint32_t index = 0; index < requirementCount; ++index) {
                    const char *requirement = requirements + index * 8;
                    if ((read<uint32_t>(requirement) & 0x0f) != 7) continue;
                    if (current++ != associatedIndex) continue;
                    auto witness = swift_conformsToProtocol(metadata, protocol);
                    if (!witness) return nullptr;
                    // Requirement-base descriptors include the conformance slot.
                    auto response = swift_getAssociatedTypeWitness(
                        0, witness, metadata, requirements - 8, requirement);
                    return response.state == 0 ? response.value : nullptr;
                }
                return nullptr;
            }
            ++associatedIndex;
            if (separator == std::string_view::npos) break;
            remaining.remove_prefix(separator + 1);
        }
    }
    // An inherited associated type belongs to the base protocol's witness table.
    for (uint32_t index = 0; index < signatureCount; ++index) {
        const char *requirement = descriptor + 24 + index * 12;
        if ((read<uint32_t>(requirement) & 0x1f) != 0) continue;
        const char *subject = relative(requirement + 4);
        if (!subject || subject[0] != 'x' || subject[1] != '\0') continue;
        if (const void *base = ABISwiftProtocolRequirementDescriptor(requirement + 8)) {
            if (const void *value = associatedType(metadata, base, name, visited)) return value;
        }
    }
    return nullptr;
}
}

const void *ABISwiftConformance(const void *metadata, const void *protocol) {
    return swift_conformsToProtocol(metadata, protocol);
}

const void *ABISwiftConformanceDescriptor(const void *witnessTable) {
    const void *descriptor = read<const void *>(witnessTable);
#if __has_feature(ptrauth_calls)
    descriptor = ptrauth_auth_data(descriptor, ptrauth_key_process_independent_data,
                                  ptrauth_blend_discriminator(witnessTable, 0xc6eb));
#endif
    return descriptor;
}

const void *ABISwiftAssociatedType(const void *metadata, const void *protocol, const char *name) {
    std::unordered_set<const void *> visited;
    return associatedType(metadata, protocol, name, visited);
}

const void *ABISwiftGenericTypeMetadata(const void *descriptor, const void *const *arguments) {
#if __has_feature(ptrauth_calls)
    descriptor = ptrauth_sign_unauthenticated(descriptor, ptrauth_key_process_independent_data, 0xae86);
#endif
    auto response = swift_getGenericMetadata(0, arguments, descriptor);
    return response.state == 0 ? response.value : nullptr;
}

const void *ABISwiftTypeForMangledName(const char *name, size_t length,
                                    const void *context, const void *const *arguments) {
    return swift_getTypeByMangledNameInContext(name, length, context, arguments);
}
