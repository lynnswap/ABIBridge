#include <ABIBridge/SwiftInvocation.h>
#include <cstdint>
#include <cstring>
#include <ptrauth.h>

extern "C" void *swift_projectBox(void *);
extern "C" const void *swift_getObjectType(void *);
namespace {
struct ErrorValueResult { const void *value; const void *metadata; const void *witness; };
struct BoxPair { void *object; void *buffer; };
}
extern "C" void swift_getErrorValue(const void *, void **, ErrorValueResult *);
extern "C" BoxPair __attribute__((swiftcall)) swift_allocBox(const void *);

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

struct EnumValueWitnessTable : ValueWitnessTable {
    uint32_t (*__ptrauth_swift_value_witness_function_pointer(0xa3b5) getEnumTag)(const void *, const void *);
    void (*__ptrauth_swift_value_witness_function_pointer(0x041d) destructiveProjectEnumData)(void *, const void *);
    void (*__ptrauth_swift_value_witness_function_pointer(0xb2e4) destructiveInjectEnumTag)(void *, uint32_t, const void *);
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

uint32_t ABISwiftGetValueWitnessFlags(const void *metadata) { return valueWitnesses(metadata)->flags; }

void ABISwiftCopyValue(const void *metadata, void *destination, const void *source) {
    valueWitnesses(metadata)->initializeWithCopy(destination, source, metadata);
}

void ABISwiftTakeValue(const void *metadata, void *destination, void *source) {
    valueWitnesses(metadata)->initializeWithTake(destination, source, metadata);
}

void ABISwiftDestroyValue(const void *metadata, void *value) {
    valueWitnesses(metadata)->destroy(value, metadata);
}

bool ABISwiftGetEnumTag(const void *metadata, const void *value, uint32_t *tag) {
    auto table = valueWitnesses(metadata);
    if (!(table->flags & 0x00200000)) return false;
    *tag = static_cast<const EnumValueWitnessTable *>(table)->getEnumTag(value, metadata);
    return true;
}

bool ABISwiftInitializeEmptyEnumCase(const void *metadata, void *destination, uint32_t tag) {
    auto table = valueWitnesses(metadata);
    if (!(table->flags & 0x00200000)) return false;
    static_cast<const EnumValueWitnessTable *>(table)->destructiveInjectEnumTag(destination, tag, metadata);
    return true;
}

bool ABISwiftInitializeEnumCase(const void *metadata, void *destination, uint32_t tag,
    const void *payloadMetadata, bool indirect, void *payload) {
    auto table = valueWitnesses(metadata);
    if (!(table->flags & 0x00200000)) return false;
    if (indirect) {
        auto box = swift_allocBox(payloadMetadata);
        valueWitnesses(payloadMetadata)->initializeWithTake(box.buffer, payload, payloadMetadata);
        std::memcpy(destination, &box.object, sizeof(box.object));
    } else {
        valueWitnesses(payloadMetadata)->initializeWithTake(destination, payload, payloadMetadata);
    }
    static_cast<const EnumValueWitnessTable *>(table)->destructiveInjectEnumTag(destination, tag, metadata);
    return true;
}

void ABISwiftTakeEnumPayload(const void *metadata, void *enumCopy,
    const void *payloadMetadata, bool indirect, void *destination) {
    auto table = static_cast<const EnumValueWitnessTable *>(valueWitnesses(metadata));
    table->destructiveProjectEnumData(enumCopy, metadata);
    auto payload = valueWitnesses(payloadMetadata);
    if (indirect) {
        void *box;
        std::memcpy(&box, enumCopy, sizeof(box));
        payload->initializeWithCopy(destination, swift_projectBox(box), payloadMetadata);
        ABIReleaseSwiftClosureContext(box);
    } else {
        payload->initializeWithTake(destination, enumCopy, payloadMetadata);
    }
}

bool ABISwiftProjectExistentialValue(const void *metadata, const void *value,
    ABISwiftExistentialProjection *result) {
    uintptr_t kind;
    std::memcpy(&kind, metadata, sizeof(kind));
    enum class Representation { opaque, classBound, error } representation;
    if (kind == 0x303) {
        uint32_t flags;
        std::memcpy(&flags, static_cast<const char *>(metadata) + sizeof(void *), sizeof(flags));
        // Class/Error compositions have mismatched native and value-witness
        // storage: https://github.com/lynnswap/ABIBridge/issues/302
        if ((flags & 0x3f000000) == 0x01000000 && !(flags & 0x80000000)) return false;
        // Projection follows metadata value-witness storage, whose special Error
        // representation takes priority over the class constraint.
        representation = (flags & 0x3f000000) == 0x01000000 ? Representation::error
            : !(flags & 0x80000000) ? Representation::classBound : Representation::opaque;
    } else if (kind == 0x307) {
        auto shape = ABISwiftExtendedExistentialShape(metadata);
        uint32_t flags;
        std::memcpy(&flags, shape, sizeof(flags));
        // Metatype and explicit-layout shapes have independent storage contracts.
        switch (flags & 0xff) {
        case 0: representation = Representation::opaque; break;
        case 1: representation = Representation::classBound; break;
        default: return false;
        }
    } else return false;
    switch (representation) {
    case Representation::opaque: {
        std::memcpy(&result->metadata, static_cast<const char *>(value) + 3 * sizeof(void *), sizeof(void *));
        if (valueWitnesses(result->metadata)->flags & 0x00020000) {
            void *box;
            std::memcpy(&box, value, sizeof(box));
            result->value = swift_projectBox(box);
        } else result->value = value;
        break;
    }
    case Representation::classBound: {
        void *object;
        std::memcpy(&object, value, sizeof(object));
        result->metadata = swift_getObjectType(object);
        result->value = value;
        break;
    }
    case Representation::error: {
        const void *error;
        std::memcpy(&error, value, sizeof(error));
        ErrorValueResult projected;
        swift_getErrorValue(error, &result->scratch, &projected);
        result->metadata = projected.metadata;
        result->value = projected.value;
        break;
    }
    }
    return true;
}
