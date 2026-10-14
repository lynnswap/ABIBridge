#include <ABIBridge/SwiftInvocation.h>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>

extern "C" const void *swift_getKeyPath(const void *, const void *);

namespace {
// The runtime consumes the compiler's pattern ABI, including the external
// descriptor's canonical identity and accessors, and signs accessor pointers.
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/stdlib/public/core/KeyPath.swift
struct KeyPathPattern {
    int32_t cache;
    int32_t environment;
    int32_t root;
    int32_t value;
    int32_t kvcString;
    uint32_t bufferHeader;
    uint32_t externalComponent;
    int32_t descriptorReference;
    uint32_t localCandidate;
    uint32_t padding;
    uint32_t environmentDepth;
    uint16_t parameterCount;
    uint8_t parameterFlags[2];
    char rootName[2];
    char valueName[3];
    const void *descriptor;
};

void initializePattern(KeyPathPattern &pattern, const void *descriptor) {
    pattern = {};
    pattern.environment = offsetof(KeyPathPattern, environmentDepth)
        - offsetof(KeyPathPattern, environment);
    // A low tag bit distinguishes mangled type references from metadata.
    pattern.root = offsetof(KeyPathPattern, rootName) + 1
        - offsetof(KeyPathPattern, root);
    pattern.value = offsetof(KeyPathPattern, valueName) + 1
        - offsetof(KeyPathPattern, value);
    pattern.bufferHeader = 3 * sizeof(uint32_t);
    // External components have tag zero; the low bit of this relative
    // reference selects the adjacent full-width descriptor pointer slot.
    pattern.descriptorReference = offsetof(KeyPathPattern, descriptor) + 1
        - offsetof(KeyPathPattern, descriptorReference);
    // The runtime requires a local candidate after the external component.
    // A nontrivial descriptor without captures replaces it in its entirety.
    pattern.localCandidate = 0x01000000;
    pattern.environmentDepth = 1;
    pattern.parameterCount = 2;
    pattern.parameterFlags[0] = pattern.parameterFlags[1] = 0x80;
    pattern.rootName[0] = 'x';
    pattern.valueName[0] = 'q';
    pattern.valueName[1] = '_';
    pattern.descriptor = descriptor;
}
}

const void *ABISwiftCreateWritableKeyPath(const void *descriptor,
    const void *root, const void *value) {
    KeyPathPattern pattern;
    initializePattern(pattern, descriptor);
    const void *arguments[] = {root, value};
    return swift_getKeyPath(&pattern, arguments);
}

size_t ABISwiftKeyPathPatternSize(void) {
    return sizeof(KeyPathPattern);
}

const void *ABISwiftCreateWritableKeyPathWithKVCKey(const void *descriptor,
    const void *root, const void *value, const char *key, void *storage) {
    auto &pattern = *new (storage) KeyPathPattern;
    initializePattern(pattern, descriptor);
    auto keyStorage = static_cast<char *>(storage) + sizeof(KeyPathPattern);
    std::memcpy(keyStorage, key, std::strlen(key) + 1);
    // The runtime borrows this string instead of copying it. Keep it beside
    // the pattern so its relative reference fits independently of image layout.
    pattern.kvcString = sizeof(KeyPathPattern) - offsetof(KeyPathPattern, kvcString);
    const void *arguments[] = {root, value};
    return swift_getKeyPath(&pattern, arguments);
}
