#include <ABIBridge/SwiftInvocation.h>
#include <cstdint>
#include <cstring>
#include <ptrauth.h>
#include <dlfcn.h>
#include <mach-o/getsect.h>
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
extern "C" const void *swift_getMetatypeMetadata(const void *);
extern "C" MetadataResponse __attribute__((swiftcall))
swift_getTupleTypeMetadata(uintptr_t, uintptr_t, const void *const *, const char *, const void *);
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

const void *ABISwiftMetatypeMetadata(const void *instance) {
    return swift_getMetatypeMetadata(instance);
}

const void *ABISwiftTupleTypeMetadata(const void *const *elements, size_t count) {
    // TupleTypeFlags reserves sixteen bits for the number of elements.
    if (count > 0xffff) return nullptr;
    if (count == 1) return elements[0];
    return swift_getTupleTypeMetadata(0, count, elements, nullptr, nullptr).value;
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
    const void *value;
    std::vector<const void *> arguments;
    std::vector<const void *> conformances;
    std::vector<std::string> parameters;
    std::vector<bool> keyParameters;
    std::vector<const char *> requirements;
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
        result.requirements.push_back(entry);
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

namespace {
const char *inlineFieldReference(const void *metadata, size_t index) {
    const char *fields = valueFields(metadata);
    if (!fields || index >= read<uint32_t>(fields + 12)) return nullptr;
    const char *field = fields + 16 + index * read<uint16_t>(fields + 10);
    if (read<uint32_t>(field) & 1) return nullptr; // An indirect case stores a box.
    return relative(field + 4);
}
}

ABISwiftSyntax *ABICopySwiftTypeFieldSyntax(const void *metadata, size_t index) {
    const char *reference = inlineFieldReference(metadata, index);
    return reference ? ABICopySwiftTypeSyntax(reference, symbolicNameLength(reference)) : nullptr;
}

namespace {
bool sameTypeSyntax(const ABISwiftSyntaxNode *lhs, const ABISwiftSyntaxNode *rhs) {
    if (std::strcmp(ABISwiftSyntaxNodeKind(lhs), ABISwiftSyntaxNodeKind(rhs))) return false;
    if (ABISwiftSyntaxNodeHasIndex(lhs) != ABISwiftSyntaxNodeHasIndex(rhs)) return false;
    if (ABISwiftSyntaxNodeHasIndex(lhs) && ABISwiftSyntaxNodeIndex(lhs) != ABISwiftSyntaxNodeIndex(rhs)) return false;
    size_t leftLength = 0, rightLength = 0;
    const char *left = ABISwiftSyntaxNodeText(lhs, &leftLength), *right = ABISwiftSyntaxNodeText(rhs, &rightLength);
    if (leftLength != rightLength || (leftLength && std::memcmp(left, right, leftLength))) return false;
    const size_t count = ABISwiftSyntaxNodeChildCount(lhs);
    if (count != ABISwiftSyntaxNodeChildCount(rhs)) return false;
    for (size_t index = 0; index < count; ++index)
        if (!sameTypeSyntax(ABISwiftSyntaxNodeChild(lhs, index), ABISwiftSyntaxNodeChild(rhs, index))) return false;
    return true;
}

bool matchesNominalReference(const char *reference, const char *descriptor) {
    using Syntax = std::unique_ptr<ABISwiftSyntax, decltype(&ABIReleaseSwiftSyntax)>;
    Syntax candidate(ABICopySwiftTypeSyntax(reference, symbolicNameLength(reference)), ABIReleaseSwiftSyntax);
    if (!candidate) return false;
    auto node = ABISwiftSyntaxRoot(candidate.get());
    while (!std::strcmp(ABISwiftSyntaxNodeKind(node), "Type")) node = ABISwiftSyntaxNodeChild(node, 0);
    if (!std::strcmp(ABISwiftSyntaxNodeKind(node), "TypeSymbolicReference"))
        return ABISwiftSyntaxNodeIndex(node) == reinterpret_cast<uintptr_t>(descriptor);
    const char *fields = relative(descriptor + 16);
    const char *nominal = fields ? relative(fields) : nullptr;
    if (!nominal) return false;
    Syntax expected(ABICopySwiftTypeSyntax(nominal, symbolicNameLength(nominal)), ABIReleaseSwiftSyntax);
    return expected && sameTypeSyntax(ABISwiftSyntaxRoot(candidate.get()), ABISwiftSyntaxRoot(expected.get()));
}
}

ABISwiftSyntax *ABICopySwiftAssociatedTypeSyntax(const void *metadata, const void *protocol, const char *name) {
    const void *witness = swift_conformsToProtocol(metadata, protocol);
    const char *descriptor = typeContextDescriptor(metadata);
    if (!witness || !descriptor) return nullptr;
    Dl_info image{};
    if (!dladdr(ABISwiftConformanceDescriptor(witness), &image)) return nullptr;
    unsigned long size = 0;
#if __LP64__
    auto header = static_cast<const mach_header_64 *>(image.dli_fbase);
#else
    auto header = static_cast<const mach_header *>(image.dli_fbase);
#endif
    auto section = reinterpret_cast<const char *>(getsectiondata(header, "__TEXT", "__swift5_assocty", &size));
    if (!section) return nullptr;
    const void *protocolType = ABISwiftProtocolTypeMetadata(protocol);
    // Reflection records preserve the formal witness even after a live witness
    // table caches concrete metadata. RemoteInspection/Records.h defines these
    // relative references and their versioned record stride.
    for (size_t offset = 0; offset + 16 <= size;) {
        const char *record = section + offset;
        const size_t count = read<uint32_t>(record + 8), stride = read<uint32_t>(record + 12);
        if (stride < 8 || count > (size - offset - 16) / stride) return nullptr;
        const char *protocolName = relative(record + 4);
        if (protocolName && protocolName[0] == '$' && protocolName[1] == 's') protocolName += 2;
        if (protocolName && swift_getTypeByMangledNameInContext(protocolName,
                symbolicNameLength(protocolName), nullptr, nullptr) == protocolType) {
            const char *conforming = relative(record);
            if (conforming && matchesNominalReference(conforming, descriptor)) {
                for (size_t index = 0; index < count; ++index) {
                    const char *entry = record + 16 + index * stride;
                    const char *member = relative(entry);
                    if (!member || std::strcmp(member, name)) continue;
                    const char *type = relative(entry + 4);
                    return type ? ABICopySwiftTypeSyntax(type, symbolicNameLength(type)) : nullptr;
                }
            }
        }
        offset += 16 + count * stride;
    }
    return nullptr;
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

ABISwiftSyntax *ABICopySwiftGenericRequirementTypeSyntax(const void *requirement, bool constraint) {
    const char *reference = relative(static_cast<const char *>(requirement) + (constraint ? 8 : 4));
    return reference ? ABICopySwiftTypeSyntax(reference, symbolicNameLength(reference)) : nullptr;
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
const void *ABISwiftTypeMetadataRequirement(const ABISwiftTypeMetadata *result, size_t index) {
    return result->requirements[index];
}
const void *ABISwiftTypeMetadataValue(const ABISwiftTypeMetadata *result) { return result->value; }
size_t ABISwiftTypeMetadataConformanceCount(const ABISwiftTypeMetadata *result) { return result->conformances.size(); }
const void *ABISwiftTypeMetadataConformance(const ABISwiftTypeMetadata *result, size_t index) { return result->conformances[index]; }
void ABIReleaseSwiftTypeMetadata(ABISwiftTypeMetadata *result) { delete result; }
