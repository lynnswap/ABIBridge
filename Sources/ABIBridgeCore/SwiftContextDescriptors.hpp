#ifndef ABIBRIDGE_SWIFT_CONTEXT_DESCRIPTORS_HPP
#define ABIBRIDGE_SWIFT_CONTEXT_DESCRIPTORS_HPP

#include <cstddef>
#include <cstdint>
#include <cstring>

// Context descriptor layouts are part of Swift's ABI.
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h
namespace abibridge {
template<class T> T read(const void *address) {
    T result;
    std::memcpy(&result, address, sizeof(result));
    return result;
}

inline const char *relative(const void *field) {
    auto offset = read<int32_t>(field);
    return offset ? static_cast<const char *>(field) + offset : nullptr;
}

/// The context that contains a descriptor, or null for a module.
const char *parentContext(const char *descriptor);
/// The generic context header of a generic type descriptor, or null.
const char *nominalGenericHeader(const char *descriptor);
/// The first of a generic context's 12-byte requirement records.
const char *genericRequirements(const char *header);
/// The length of a mangled name that can contain symbolic references.
size_t symbolicNameLength(const char *name);
/// The name of the module that contains a descriptor.
const char *declaringModule(const char *descriptor);
/// The nominal descriptor that an extension extends, resolved in the generic
/// environment of a type with `metadata` and `descriptor` declared in it.
/// Without metadata, only a symbolic reference to the nominal resolves.
const char *extendedNominal(const char *extension, const void *metadata, const char *descriptor);
/// Whether two requirement records state the same requirement. Records that
/// cannot be compared count as different.
bool sameRequirement(const char *lhs, const char *rhs);
}

#endif
