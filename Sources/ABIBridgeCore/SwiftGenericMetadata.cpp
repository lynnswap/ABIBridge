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
extern "C" const void *swift_getExistentialTypeMetadata(bool, const void *, size_t, const uintptr_t *);
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
#if __has_feature(ptrauth_calls) && __has_attribute(ptrauth_struct)
struct __attribute__((ptrauth_struct(ptrauth_key_process_dependent_data,
                                    ptrauth_string_discriminator("TypeContextDescriptor"))))
    RuntimeTypeContextDescriptor;
#else
struct RuntimeTypeContextDescriptor;
#endif
extern "C" const RuntimeTypeContextDescriptor *swift_getTypeContextDescriptor(const void *);

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

const void *ABISwiftProtocolTypeMetadata(const void *protocol) {
    // ProtocolDescriptorRef stores an unsigned integer, not a signed descriptor
    // pointer. The runtime authenticates pointers in the resulting metadata.
    uintptr_t reference = reinterpret_cast<uintptr_t>(protocol);
    return swift_getExistentialTypeMetadata(bool(read<uint32_t>(protocol) & 0x10000),
                                           nullptr, 1, &reference);
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
    struct Requirement {
        std::string subject;
        const void *protocol;
    };
    const void *value;
    std::vector<const void *> arguments;
    std::vector<const void *> conformances;
    std::vector<std::string> parameters;
    std::vector<bool> keyParameters;
    std::vector<Requirement> requirements;
};

namespace {
const char *typeContextDescriptor(const void *metadata) {
    // The runtime's C++ return type uses ptrauth_struct, distinct from a
    // descriptor pointer stored in Swift metadata or a symbolic reference.
    return static_cast<const char *>(static_cast<const void *>(swift_getTypeContextDescriptor(metadata)));
}

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
            if (metadata) nominal = typeContextDescriptor(metadata);
        }
        return nominal && genericTypeLevels(nominal, environment, arguments, counts);
    }
    // A private declaration's anonymous context repeats its generic signature;
    // it does not introduce an additional nominal type argument group.
    if (kind == 2)
        return genericTypeLevels(parentContext(descriptor), environment, arguments, counts);
    if (kind < 16 || kind > 18) return false;
    if (!genericTypeLevels(parentContext(descriptor), environment, arguments, counts)) return false;
    const char *header = nominalGenericHeader(descriptor);
    counts.push_back(header ? read<uint16_t>(header) : 0);
    return true;
}

const void *const *genericArguments(const void *metadata, const char *descriptor) {
    ptrdiff_t offset = 2 * sizeof(void *);
    auto flags = read<uint32_t>(descriptor);
    if ((flags & 0x1f) == 16) {
        if (flags & 0x20000000) offset = read<ptrdiff_t>(relative(descriptor + 24));
        else if (flags & 0x10000000) offset = -ptrdiff_t(read<uint32_t>(descriptor + 24)) * sizeof(void *);
        else offset = ptrdiff_t(read<uint32_t>(descriptor + 28) - read<uint32_t>(descriptor + 32)) * sizeof(void *);
    }
    return reinterpret_cast<const void *const *>(static_cast<const char *>(metadata) + offset);
}

const char *genericRequirements(const char *header) {
    auto afterParameters = reinterpret_cast<uintptr_t>(header + 8 + read<uint16_t>(header));
    return reinterpret_cast<const char *>((afterParameters + 3) & ~uintptr_t(3));
}

size_t shapeCount(const char *header) {
    if (!(read<uint16_t>(header + 6) & 1)) return 0;
    return read<uint16_t>(genericRequirements(header) + read<uint16_t>(header + 2) * 12 + 2);
}

std::vector<uintptr_t> genericEnvironment(const std::vector<uint16_t> &counts) {
    const size_t parameters = counts.empty() ? 0 : counts.back();
    std::vector<uintptr_t> result((4 + 2 * counts.size() + parameters + sizeof(uintptr_t) - 1) / sizeof(uintptr_t));
    const uint32_t levels = static_cast<uint32_t>(counts.size());
    std::memcpy(result.data(), &levels, 4);
    auto bytes = reinterpret_cast<char *>(result.data());
    if (!counts.empty()) std::memcpy(bytes + 4, counts.data(), 2 * counts.size());
    std::memset(bytes + 4 + 2 * counts.size(), 0x80, parameters);
    return result;
}

std::string parameterReference(size_t depth, size_t index) {
    auto encoded = [](size_t value) { return value == 0 ? std::string("_") : std::to_string(value - 1) + "_"; };
    if (depth) return "qd" + encoded(depth - 1) + encoded(index);
    if (!index) return "x";
    return "q" + encoded(index - 1);
}

bool collectWrittenArguments(ABISwiftTypeMetadata &result, const char *descriptor) {
    const char *header = nominalGenericHeader(descriptor);
    if (!header) return true;
    const size_t count = read<uint16_t>(header);
    const auto stored = genericArguments(result.value, descriptor);
    size_t index = shapeCount(header);
    for (size_t parameter = 0; parameter < count; ++parameter)
        result.arguments.push_back((header[8 + parameter] & 0x80) ? stored[index++] : nullptr);
    if (std::all_of(result.arguments.begin(), result.arguments.end(), [](auto value) { return value != nullptr; }))
        return true;

    // Non-key parameters were removed by same-type requirements. Reconstruct
    // their source-written positions using the descriptor's own type references.
    auto flat = genericEnvironment({static_cast<uint16_t>(count)});
    std::vector<uint16_t> levels;
    if (!genericTypeLevels(descriptor, flat.data(), result.arguments.data(), levels)) return false;
    std::vector<uint16_t> counts;
    for (auto level : levels)
        if (level && (counts.empty() || level > counts.back())) counts.push_back(level);
    auto environment = genericEnvironment(counts);
    std::vector<std::string> references;
    size_t start = 0;
    for (size_t depth = 0; depth < counts.size(); ++depth) {
        for (size_t parameter = start; parameter < counts[depth]; ++parameter)
            references.push_back(parameterReference(depth, parameter - start));
        start = counts[depth];
    }
    auto ordinal = [&](const char *name) -> size_t {
        auto found = std::find(references.begin(), references.end(), std::string(name, symbolicNameLength(name)));
        return static_cast<size_t>(found - references.begin());
    };
    const auto requirements = genericRequirements(header);
    bool changed;
    do {
        changed = false;
        for (size_t requirement = 0; requirement < read<uint16_t>(header + 2); ++requirement) {
            const char *entry = requirements + requirement * 12;
            if ((read<uint32_t>(entry) & 0x1f) != 1) continue; // SameType.
            const char *left = relative(entry + 4), *right = relative(entry + 8);
            if (!left || !right) continue;
            const size_t lhs = ordinal(left), rhs = ordinal(right);
            if (lhs < count && !result.arguments[lhs]) {
                const void *value = rhs < count ? result.arguments[rhs]
                    : swift_getTypeByMangledNameInEnvironment(
                        right, symbolicNameLength(right), environment.data(), result.arguments.data());
                if (value) { result.arguments[lhs] = value; changed = true; }
            }
            if (rhs < count && !result.arguments[rhs] && lhs < count && result.arguments[lhs]) {
                result.arguments[rhs] = result.arguments[lhs]; changed = true;
            }
        }
    } while (changed);
    return std::all_of(result.arguments.begin(), result.arguments.end(), [](auto value) { return value != nullptr; });
}

std::string requirementSubject(const char *subject) {
    std::string result = "$s";
    const size_t length = symbolicNameLength(subject);
    for (size_t index = 0; index < length; ++index) {
        const uint8_t byte = subject[index];
        if (byte == 1 || byte == 2) {
            const char *target = subject + index + 1 + read<int32_t>(subject + index + 1);
            auto protocol = byte == 2 ? contextPointer(target) : target;
            if ((read<uint32_t>(protocol) & 0x1f) != 3) return {};
            // A dependent member's first identifier is already substitution 0.
            // This synthetic protocol adds exactly one substitution, as does
            // the original symbolic protocol reference (Demangler.cpp). Keeping
            // that count preserves later substitutions in recursive paths.
            result += "SoAAP";
            index += 4;
        } else if (byte >= 1 && byte <= 0x1f) {
            return {};
        } else {
            result += subject[index];
        }
    }
    return result;
}

bool collectContext(ABISwiftTypeMetadata &result) {
    result.parameters.clear();
    result.keyParameters.clear();
    result.requirements.clear();
    const char *descriptor = typeContextDescriptor(result.value);
    const char *header = descriptor ? nominalGenericHeader(descriptor) : nullptr;
    if (!header) return true;
    auto flat = genericEnvironment({static_cast<uint16_t>(result.arguments.size())});
    std::vector<uint16_t> levels;
    if (!genericTypeLevels(descriptor, flat.data(), result.arguments.data(), levels)) return false;
    size_t start = 0, depth = 0;
    for (auto count : levels) {
        if (count <= start) continue;
        for (size_t index = start; index < count; ++index) {
            result.parameters.push_back("$s" + parameterReference(depth, index - start));
            result.keyParameters.push_back(header[8 + index] & 0x80);
        }
        start = count;
        ++depth;
    }
    auto requirements = genericRequirements(header);
    for (size_t index = 0; index < read<uint16_t>(header + 2); ++index) {
        auto entry = requirements + index * 12;
        if ((read<uint32_t>(entry) & 0x1f) != 0) continue;
        auto subject = requirementSubject(relative(entry + 4));
        if (subject.empty()) return false;
        result.requirements.push_back({std::move(subject), ABISwiftProtocolRequirementDescriptor(entry + 8)});
    }
    return true;
}

void collectConformances(ABISwiftTypeMetadata &result, const char *descriptor) {
    const char *header = nominalGenericHeader(descriptor);
    if (!header) return;
    const size_t parameters = read<uint16_t>(header);
    const size_t keys = read<uint16_t>(header + 4);
    const char *parameterFlags = header + 8;
    size_t firstWitness = 0;
    for (size_t index = 0; index < parameters; ++index)
        firstWitness += bool(parameterFlags[index] & 0x80);
    firstWitness += shapeCount(header);
    auto arguments = genericArguments(result.value, descriptor);
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
    auto environment = genericEnvironment({static_cast<uint16_t>(count)});
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
    if (count) result->arguments.assign(arguments, arguments + count);
    collectConformances(*result, descriptor);
    return result.release();
}

ABISwiftTypeMetadata *ABICopySwiftTypeMetadata(const void *metadata, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    auto result = std::make_unique<ABISwiftTypeMetadata>();
    result->value = metadata;
    auto descriptor = typeContextDescriptor(metadata);
    if (descriptor) {
        if (!collectWrittenArguments(*result, descriptor)) {
            if (error) *error = ABICreateResolutionFailure(ABIFailureMetadataUnavailable,
                "The generic arguments could not be recovered from the complete Swift metadata.");
            return nullptr;
        }
        collectConformances(*result, descriptor);
    }
    return result.release();
}

const void *ABISwiftTypeDescriptor(const void *metadata) { return typeContextDescriptor(metadata); }

namespace {
const char *valueFields(const void *metadata) {
    const char *descriptor = typeContextDescriptor(metadata);
    if (!descriptor) return nullptr;
    const auto kind = read<uint32_t>(descriptor) & 0x1f;
    return kind == 17 || kind == 18 ? relative(descriptor + 16) : nullptr;
}
}

size_t ABISwiftTypeFieldCount(const void *metadata) {
    const char *fields = valueFields(metadata);
    return fields ? read<uint32_t>(fields + 12) : 0;
}

char *ABICopySwiftTypeFieldReference(const void *metadata, size_t index) {
    const char *fields = valueFields(metadata);
    if (!fields || index >= read<uint32_t>(fields + 12)) return nullptr;
    const char *field = fields + 16 + index * read<uint16_t>(fields + 10);
    if (read<uint32_t>(field) & 1) return nullptr; // An indirect case stores a box.
    const char *reference = relative(field + 4);
    if (!reference) return nullptr; // A case without a payload.
    auto subject = requirementSubject(reference);
    return subject.empty() ? nullptr : strdup(subject.c_str());
}

size_t ABISwiftTypeMetadataArgumentCount(const ABISwiftTypeMetadata *result) { return result->arguments.size(); }
bool ABISwiftTypeMetadataArgumentIsPack(const ABISwiftTypeMetadata *result, size_t index) {
    return reinterpret_cast<uintptr_t>(result->arguments[index]) & 1;
}
size_t ABISwiftTypeMetadataArgumentElementCount(const ABISwiftTypeMetadata *result, size_t index) {
    if (!ABISwiftTypeMetadataArgumentIsPack(result, index)) return 1;
    auto pack = reinterpret_cast<const void *const *>(reinterpret_cast<uintptr_t>(result->arguments[index]) & ~uintptr_t(1));
    return read<size_t>(pack - 1);
}
const void *ABISwiftTypeMetadataArgumentElement(const ABISwiftTypeMetadata *result, size_t index, size_t element) {
    if (!ABISwiftTypeMetadataArgumentIsPack(result, index)) return result->arguments[index];
    auto pack = reinterpret_cast<const void *const *>(reinterpret_cast<uintptr_t>(result->arguments[index]) & ~uintptr_t(1));
    return pack[element];
}

char *ABICopySwiftGenericRequirementSubject(const void *requirement) {
    auto name = requirementSubject(relative(static_cast<const char *>(requirement) + 4));
    return name.empty() ? nullptr : strdup(name.c_str());
}

bool ABIPrepareSwiftTypeMetadataContext(ABISwiftTypeMetadata *result, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (collectContext(*result)) return true;
    if (error) *error = ABICreateResolutionFailure(ABIFailureMetadataUnavailable,
        "The nominal declaration's generic requirements could not be decoded.");
    return false;
}
const char *ABISwiftTypeMetadataParameterReference(const ABISwiftTypeMetadata *result, size_t index) {
    return result->parameters[index].c_str();
}
bool ABISwiftTypeMetadataArgumentIsKey(const ABISwiftTypeMetadata *result, size_t index) {
    return result->keyParameters[index];
}
size_t ABISwiftTypeMetadataRequirementCount(const ABISwiftTypeMetadata *result) { return result->requirements.size(); }
const char *ABISwiftTypeMetadataRequirementSubject(const ABISwiftTypeMetadata *result, size_t index) {
    return result->requirements[index].subject.c_str();
}
const void *ABISwiftTypeMetadataRequirementProtocol(const ABISwiftTypeMetadata *result, size_t index) {
    return result->requirements[index].protocol;
}
const void *ABISwiftTypeMetadataValue(const ABISwiftTypeMetadata *result) { return result->value; }
size_t ABISwiftTypeMetadataConformanceCount(const ABISwiftTypeMetadata *result) { return result->conformances.size(); }
const void *ABISwiftTypeMetadataConformance(const ABISwiftTypeMetadata *result, size_t index) { return result->conformances[index]; }
void ABIReleaseSwiftTypeMetadata(ABISwiftTypeMetadata *result) { delete result; }
