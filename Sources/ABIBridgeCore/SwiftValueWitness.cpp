#include <ABIBridge/SwiftInvocation.h>
#include <cstdint>
#include <cstring>
#include <ptrauth.h>

namespace {
// Swift's stable value-witness layout and address-discriminated authentication.
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/ValueWitness.def
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/MetadataValues.h
struct ValueWitnessTable {
    const void *initializeBufferWithCopyOfBuffer;
    void (*__ptrauth_swift_value_witness_function_pointer(0x04f8) destroy)(void *, const void *);
    void *(*__ptrauth_swift_value_witness_function_pointer(0xe3ba) initializeWithCopy)(void *, const void *, const void *);
    const void *assignWithCopy;
    void *(*__ptrauth_swift_value_witness_function_pointer(0x48d8) initializeWithTake)(void *, void *, const void *);
    const void *assignWithTake;
    const void *getEnumTagSinglePayload;
    const void *storeEnumTagSinglePayload;
    size_t size;
    size_t stride;
    uint32_t flags;
    uint32_t extraInhabitantCount;
};

const ValueWitnessTable *valueWitnesses(const void *metadata) {
    auto slot = static_cast<const char *>(metadata) - sizeof(void *);
    const void *table;
    std::memcpy(&table, slot, sizeof(table));
#if __has_feature(ptrauth_calls)
    table = ptrauth_auth_data(table, ptrauth_key_process_independent_data,
                             ptrauth_blend_discriminator(slot, 0x2e3f));
#endif
    return static_cast<const ValueWitnessTable *>(table);
}
}

ABISwiftValueLayout ABISwiftGetValueLayout(const void *metadata) {
    auto table = valueWitnesses(metadata);
    return {table->size, table->stride, (table->flags & 0xff) + size_t(1)};
}

void ABISwiftCopyValue(const void *metadata, void *destination, const void *source) {
    valueWitnesses(metadata)->initializeWithCopy(destination, source, metadata);
}

void ABISwiftTakeValue(const void *metadata, void *destination, void *source) {
    valueWitnesses(metadata)->initializeWithTake(destination, source, metadata);
}

void ABISwiftDestroyValue(const void *metadata, void *value) {
    valueWitnesses(metadata)->destroy(value, metadata);
}
