#include <ABIBridge/SwiftInvocation.h>
#include <cstdint>
#include <cstring>
#include <ptrauth.h>
#include <string_view>
#include <unordered_set>
#include <vector>
#include <string>
#include <memory>
#include <algorithm>

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
extern "C" const void *__attribute__((swiftcall))
swift_getTypeByMangledNameInEnvironment(const char *, size_t, const void *, const void *const *);
extern "C" const void *__attribute__((swiftcall))
swift_allocateMetadataPack(const void *const *, size_t);
extern "C" const void *swift_getTypeContextDescriptor(const void *);

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

const void *ABISwiftMetadataPack(const void *const *elements, size_t count) {
    return swift_allocateMetadataPack(elements, count);
}

struct ABISwiftTypeMetadata {
    const void *value;
    std::vector<const void *> conformances;
};

namespace {
const char *contextPointer(const void *slot) {
    const void *pointer = read<const void *>(slot);
#if __has_feature(ptrauth_calls)
    pointer = ptrauth_auth_data(pointer, ptrauth_key_process_independent_data,
                               ptrauth_blend_discriminator(slot, 0xae86));
#endif
    return static_cast<const char *>(pointer);
}

const char *parentContext(const char *descriptor) {
    const char *field = descriptor + 4;
    auto offset = read<int32_t>(field);
    if (!offset) return nullptr;
    const char *target = field + (offset & ~1);
    return (offset & 1) ? contextPointer(target) : target;
}

const char *nominalGenericHeader(const char *descriptor) {
    auto flags = read<uint32_t>(descriptor);
    if (!(flags & 0x80)) return nullptr;
    auto kind = flags & 0x1f;
    // A type generic context starts with its cache/pattern relative pointers.
    return descriptor + (kind == 16 ? 44 : 28) + 8;
}

size_t symbolicNameLength(const char *name) {
    size_t length = 0;
    while (uint8_t byte = name[length]) {
        ++length;
        if (byte >= 1 && byte <= 0x17) length += 4;
        else if (byte >= 0x18 && byte <= 0x1f) length += sizeof(void *);
    }
    return length;
}

bool genericTypeLevels(const char *descriptor, const void *environment,
                       const void *const *arguments, std::vector<uint16_t> &counts) {
    if (!descriptor) return true;
    auto kind = read<uint32_t>(descriptor) & 0x1f;
    if (kind == 0) return true;
    if (kind == 1) {
        const char *extended = relative(descriptor + 8);
        if (!extended) return false;
        const char *nominal = nullptr;
        // Compiler-emitted symbolic references identify the original nominal
        // context without instantiating its still-unbound generic parameters.
        if (extended[0] == 1 || extended[0] == 2) {
            const char *target = extended + 1 + read<int32_t>(extended + 1);
            nominal = extended[0] == 2 ? contextPointer(target) : target;
        } else {
            const void *metadata = swift_getTypeByMangledNameInEnvironment(
                extended, symbolicNameLength(extended), environment, arguments);
            if (metadata) nominal = static_cast<const char *>(swift_getTypeContextDescriptor(metadata));
        }
        return nominal && genericTypeLevels(nominal, environment, arguments, counts);
    }
    if (kind == 2 && !(read<uint32_t>(descriptor) & 0x80))
        return genericTypeLevels(parentContext(descriptor), environment, arguments, counts);
    if (kind < 16 || kind > 18) return false;
    if (!genericTypeLevels(parentContext(descriptor), environment, arguments, counts)) return false;
    const char *header = nominalGenericHeader(descriptor);
    counts.push_back(header ? read<uint16_t>(header) : 0);
    return true;
}

void collectConformances(ABISwiftTypeMetadata &result, const char *descriptor) {
    const char *header = nominalGenericHeader(descriptor);
    if (!header) return;
    const size_t parameters = read<uint16_t>(header);
    const size_t requirements = read<uint16_t>(header + 2);
    const size_t keys = read<uint16_t>(header + 4);
    const auto flags = read<uint16_t>(header + 6);
    const char *parameterFlags = header + 8;
    size_t firstWitness = 0;
    for (size_t index = 0; index < parameters; ++index)
        firstWitness += bool(parameterFlags[index] & 0x80);
    if (flags & 1) {
        auto alignedParameters = (reinterpret_cast<uintptr_t>(parameterFlags + parameters) + 3) & ~uintptr_t(3);
        const char *shape = reinterpret_cast<const char *>(alignedParameters) + requirements * 12;
        firstWitness += read<uint16_t>(shape + 2);
    }
    ptrdiff_t offset = 2 * sizeof(void *);
    auto descriptorFlags = read<uint32_t>(descriptor);
    if ((descriptorFlags & 0x1f) == 16) {
        if (descriptorFlags & 0x20000000) offset = read<ptrdiff_t>(relative(descriptor + 24));
        else if (descriptorFlags & 0x10000000) offset = -ptrdiff_t(read<uint32_t>(descriptor + 24)) * sizeof(void *);
        else offset = ptrdiff_t(read<uint32_t>(descriptor + 28) - read<uint32_t>(descriptor + 32)) * sizeof(void *);
    }
    auto arguments = reinterpret_cast<const void *const *>(static_cast<const char *>(result.value) + offset);
    for (size_t index = firstWitness; index < keys; ++index) {
        auto argument = reinterpret_cast<uintptr_t>(arguments[index]);
        if (argument & 1) {
            auto pack = reinterpret_cast<const void *const *>(argument & ~uintptr_t(1));
            auto count = read<size_t>(pack - 1);
            for (size_t element = 0; element < count; ++element)
                result.conformances.push_back(ABISwiftConformanceDescriptor(pack[element]));
        } else {
            result.conformances.push_back(ABISwiftConformanceDescriptor(arguments[index]));
        }
    }
}
}

ABISwiftTypeMetadata *ABICreateSwiftTypeMetadata(const void *rawDescriptor,
    const void *const *arguments, size_t count, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    auto fail = [&](int code, const char *message) -> ABISwiftTypeMetadata * {
        if (error) *error = ABICreateResolutionFailure(code, message);
        return nullptr;
    };
    if (!rawDescriptor || (count && !arguments))
        return fail(ABIFailureInvalidRequest, "Type construction requires a nominal descriptor and its generic arguments.");
    auto descriptor = static_cast<const char *>(rawDescriptor);
    const auto kind = read<uint32_t>(descriptor) & 0x1f;
    if (kind < 16 || kind > 18)
        return fail(ABIFailureInvalidRequest, "Expected a Swift class, struct, or enum descriptor.");
    const char *header = nominalGenericHeader(descriptor);
    const size_t expected = header ? read<uint16_t>(header) : 0;
    if (count != expected)
        return fail(ABIFailureInvalidRequest, "The argument count must match the type's complete generic context.");
    for (size_t index = 0; index < count; ++index) {
        const auto parameterKind = uint8_t(header[8 + index]) & 0x3f;
        if (parameterKind > 1)
            return fail(ABIFailureUnsupportedDeclaration, "The type has a non-type generic parameter.");
        const bool isPack = reinterpret_cast<uintptr_t>(arguments[index]) & 1;
        if (!arguments[index] || isPack != (parameterKind == 1))
            return fail(ABIFailureInvalidRequest, "Each generic argument must match its scalar or pack parameter.");
    }

    // A flat, unconstrained environment supplies already existing metadata.
    // The target descriptor, not this environment, owns the real constraints;
    // the runtime's bound-type resolver checks those and constructs witnesses.
    std::vector<uintptr_t> environment((6 + count + sizeof(uintptr_t) - 1) / sizeof(uintptr_t));
    const uint32_t levels = 1;
    const uint16_t parameters = static_cast<uint16_t>(count);
    std::memcpy(environment.data(), &levels, 4);
    std::memcpy(reinterpret_cast<char *>(environment.data()) + 4, &parameters, 2);
    std::memset(reinterpret_cast<char *>(environment.data()) + 6, 0x80, count);
    std::vector<uint16_t> counts;
    if (!genericTypeLevels(descriptor, environment.data(), arguments, counts))
        return fail(ABIFailureUnsupportedDeclaration, "The nominal type's enclosing generic contexts could not be resolved.");
    std::string suffix;
    if (count) {
        suffix = "y";
        size_t start = 0;
        for (size_t level = 0; level < counts.size(); ++level) {
            if (level) suffix += "_";
            for (size_t index = start; index < counts[level]; ++index)
                suffix += index == 0 ? "x" : index == 1 ? "q_" : "q" + std::to_string(index - 2) + "_";
            start = counts[level];
        }
        suffix += "G";
    }
    std::vector<uint8_t> nameStorage(sizeof(void *) + 5 + suffix.size());
    const void *symbolicDescriptor = descriptor;
#if __has_feature(ptrauth_calls)
    symbolicDescriptor = ptrauth_sign_unauthenticated(descriptor, ptrauth_key_process_independent_data,
        ptrauth_blend_discriminator(nameStorage.data(), 0xae86));
#endif
    std::memcpy(nameStorage.data(), &symbolicDescriptor, sizeof(void *));
    char *name = reinterpret_cast<char *>(nameStorage.data() + sizeof(void *));
    name[0] = 2;
    const int32_t slotOffset = -int32_t(sizeof(void *) + 1);
    std::memcpy(name + 1, &slotOffset, 4);
    std::memcpy(name + 5, suffix.data(), suffix.size());
    const void *metadata = swift_getTypeByMangledNameInEnvironment(name, 5 + suffix.size(), environment.data(), arguments);
    if (!metadata)
        return fail(ABIFailureUnsupportedDeclaration,
            "Swift could not instantiate this type with the supplied arguments; check generic constraints and available metadata/conformances.");
    auto result = std::make_unique<ABISwiftTypeMetadata>();
    result->value = metadata;
    collectConformances(*result, descriptor);
    return result.release();
}

const void *ABISwiftTypeMetadataValue(const ABISwiftTypeMetadata *result) { return result->value; }
size_t ABISwiftTypeMetadataConformanceCount(const ABISwiftTypeMetadata *result) { return result->conformances.size(); }
const void *ABISwiftTypeMetadataConformance(const ABISwiftTypeMetadata *result, size_t index) { return result->conformances[index]; }
void ABIReleaseSwiftTypeMetadata(ABISwiftTypeMetadata *result) { delete result; }
