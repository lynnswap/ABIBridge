#include <ABIBridge/Backend/SwiftProtocolConformance.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <ptrauth.h>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <new>

// A registered section remains in the runtime's conformance search list:
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/stdlib/public/runtime/ProtocolConformance.cpp
// Descriptor fields and pointer-signing schemas follow:
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/Runtime/Config.h
extern "C" void swift_registerProtocolConformances(const void *, const void *);
extern "C" const void *swift_getObjCClassMetadata(const void *);

namespace {
constexpr const char *payloadIvar = "_abiSwiftProtocolContext";
// Every generated class has the same direct superclass and sole ivar layout.
// Publication precedes instance creation, so the offset is stable on all calls.
std::atomic<std::ptrdiff_t> payloadOffset{0};
std::atomic<Class> proxySuperclass{Nil};

struct InstanceContext {
    void *value;
    bool (*invoke)(void *, size_t, void *const *, void *, void *);
    void (*release)(void *);
};

InstanceContext *instanceContext(const void *object) {
    InstanceContext *result;
    std::memcpy(&result, static_cast<const char *>(object) + payloadOffset.load(std::memory_order_relaxed), sizeof(result));
    return result;
}

void destroyInstance(id instance, SEL selector) {
    auto *context = instanceContext(instance);
    if (context) {
        if (context->release) context->release(context->value);
        delete context;
    }
    // Every registered proxy directly subclasses NSObject. Use the defining
    // superclass even if another Objective-C facility has changed its isa.
    objc_super parent{instance, proxySuperclass.load(std::memory_order_relaxed)};
    reinterpret_cast<void (*)(objc_super *, SEL)>(objc_msgSendSuper)(&parent, selector);
}

void fail(ABIResolutionFailure **error, int code, const char *message) {
    if (error) *error = ABICreateResolutionFailure(code, message);
}

struct Descriptor {
    int32_t protocol;
    int32_t type;
    int32_t witnesses;
    uint32_t flags;
};

}

struct ABISwiftProtocolConformance {
    Descriptor descriptor{};
    const void *protocol = nullptr;
    Class type = Nil;
    int32_t record = 0;
};

const void *ABICreateSwiftProtocolClass(ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    static std::atomic<uint64_t> sequence{0};
    char name[96];
    std::snprintf(name, sizeof(name), "ABIBridge_SwiftProtocol_%llx_%llu",
                  static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&sequence)),
                  static_cast<unsigned long long>(sequence.fetch_add(1)));
    Class base = objc_getClass("NSObject");
    if (!base) {
        fail(error, ABIFailureMetadataUnavailable, "NSObject must be loaded to create a native protocol class.");
        return nullptr;
    }
    Class type = objc_allocateClassPair(base, name, 0);
    if (!type) {
        fail(error, ABIFailureMetadataUnavailable, "Cannot allocate a native protocol class.");
        return nullptr;
    }
    const uint8_t pointerAlignment = sizeof(void *) == 8 ? 3 : 2;
    if (!class_addIvar(type, payloadIvar, sizeof(InstanceContext *), pointerAlignment, "^v") ||
        !class_addMethod(type, sel_registerName("dealloc"),
                        reinterpret_cast<IMP>(&destroyInstance), "v@:")) {
        objc_disposeClassPair(type);
        fail(error, ABIFailureMetadataUnavailable, "Cannot initialize a native protocol class.");
        return nullptr;
    }
    objc_registerClassPair(type);
    payloadOffset.store(ivar_getOffset(class_getInstanceVariable(type, payloadIvar)), std::memory_order_relaxed);
    proxySuperclass.store(base, std::memory_order_relaxed);
    return type;
}

const void *ABISwiftProtocolClassMetadata(const void *type) {
    return type ? swift_getObjCClassMetadata(type) : nullptr;
}

ABISwiftProtocolConformance *ABICreateSwiftProtocolConformance(
    const void *type, const void *protocolDescriptor, const ABIUnmanagedFunction *entries,
    const uint16_t *discriminators, size_t count, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!type || !protocolDescriptor || (count && (!entries || !discriminators))) {
        fail(error, ABIFailureInvalidRequest, "A prepared class, Swift protocol and complete witness entries are required.");
        return nullptr;
    }
    // Relative references and the table share an allocation, so every
    // intra-record displacement is representable even with distant images.
    const auto allocationBytes = sizeof(ABISwiftProtocolConformance) + (count + 1) * sizeof(void *);
    auto allocation = std::make_unique<char[]>(allocationBytes);
    auto *published = new (allocation.get()) ABISwiftProtocolConformance();
    published->protocol = protocolDescriptor;
    published->type = reinterpret_cast<Class>(const_cast<void *>(type));

    // The protocol uses a relative indirect reference, so descriptors in
    // another image need not be within signed 32-bit reach of this allocation.
    auto **table = reinterpret_cast<const void **>(allocation.get() + sizeof(ABISwiftProtocolConformance));
    published->descriptor.flags = 3u << 3; // IndirectObjCClass
    published->descriptor.protocol = static_cast<int32_t>(
        reinterpret_cast<char *>(&published->protocol) - reinterpret_cast<char *>(&published->descriptor.protocol)) | 1;
    published->descriptor.type = static_cast<int32_t>(
        reinterpret_cast<char *>(&published->type) - reinterpret_cast<char *>(&published->descriptor.type));
    published->descriptor.witnesses = static_cast<int32_t>(
        reinterpret_cast<char *>(table) - reinterpret_cast<char *>(&published->descriptor.witnesses));
    published->record = static_cast<int32_t>(
        reinterpret_cast<char *>(&published->descriptor) - reinterpret_cast<char *>(&published->record));
    table[0] = &published->descriptor;
#if __has_feature(ptrauth_calls)
    published->protocol = ptrauth_sign_unauthenticated(
        protocolDescriptor, ptrauth_key_process_independent_data,
        ptrauth_blend_discriminator(&published->protocol, 0xae86));
    table[0] = ptrauth_sign_unauthenticated(table[0], ptrauth_key_process_independent_data,
                                          ptrauth_blend_discriminator(table, 0xc6eb));
#endif
    for (size_t index = 0; index < count; ++index) {
        const void *entry;
        std::memcpy(&entry, &entries[index], sizeof(entry));
#if __has_feature(ptrauth_calls)
        entry = ptrauth_auth_and_resign(
            entry, ptrauth_key_function_pointer,
            ptrauth_function_pointer_type_discriminator(void(void)),
            ptrauth_key_process_independent_code,
            ptrauth_blend_discriminator(table + index + 1, discriminators[index]));
#endif
        table[index + 1] = entry;
    }
    // No operation after publication can fail. The runtime owns the reference
    // to this allocation permanently; it does not expose unregistration.
    swift_registerProtocolConformances(&published->record, &published->record + 1);
    allocation.release();
    return published;
}

const void *ABISwiftProtocolConformanceWitnessTable(const ABISwiftProtocolConformance *conformance) {
    return conformance ? reinterpret_cast<const char *>(conformance) + sizeof(*conformance) : nullptr;
}
void *ABICreateSwiftProtocolInstance(const ABISwiftProtocolConformance *conformance,
    void *context, bool (*invoke)(void *, size_t, void *const *, void *, void *),
    void (*releaseContext)(void *), ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!conformance || !invoke) {
        fail(error, ABIFailureInvalidRequest, "A registered Swift protocol conformance and an instance callback are required.");
        return nullptr;
    }
    auto payload = std::make_unique<InstanceContext>(InstanceContext{context, invoke, releaseContext});
    id object = class_createInstance(conformance->type, 0);
    if (!object) {
        fail(error, ABIFailureMetadataUnavailable, "Cannot allocate a native protocol instance.");
        return nullptr;
    }
    auto *value = payload.release();
    std::memcpy(reinterpret_cast<char *>(object) + payloadOffset.load(std::memory_order_relaxed), &value, sizeof(value));
    return object;
}
bool ABIInvokeSwiftProtocolInstance(const void *object, size_t slot,
    void *const *arguments, void *result, void *errorResult) {
    auto *context = instanceContext(object);
    return context->invoke(context->value, slot, arguments, result, errorResult);
}
