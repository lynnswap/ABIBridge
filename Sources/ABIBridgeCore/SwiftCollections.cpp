#include <ABIBridge/Backend/SwiftInvocation.h>
#include <algorithm>
#include <cstdint>
#include <cstdlib>

// Standard library entry points, exported from libswiftCore since the stable
// ABI. Their signatures follow the Swift calling convention the compiler uses
// for unspecialized calls: nonmutating methods take their generic arguments
// after `self`, mutating methods take the Self metadata and `self` in the
// context register. `makeIterator()` consumes `self`.

namespace {
struct MetadataResponse { const void *value; uintptr_t state; };
struct ArrayAllocation { const void *array; void *elements; };
}

extern "C" {
extern const char ABISwiftHashableDescriptor __asm__("_$sSHMp");

MetadataResponse __attribute__((swiftcall)) ABISwiftOptionalMetadata(uintptr_t, const void *)
    __asm__("_$sSqMa");
MetadataResponse __attribute__((swiftcall)) ABISwiftSetMetadata(uintptr_t, const void *, const void *)
    __asm__("_$sShMa");
MetadataResponse __attribute__((swiftcall)) ABISwiftSetIteratorMetadata(uintptr_t, const void *, const void *)
    __asm__("_$sSh8IteratorVMa");
MetadataResponse __attribute__((swiftcall))
ABISwiftDictionaryMetadata(uintptr_t, const void *, const void *, const void *) __asm__("_$sSDMa");
MetadataResponse __attribute__((swiftcall))
ABISwiftDictionaryIteratorMetadata(uintptr_t, const void *, const void *, const void *) __asm__("_$sSD8IteratorVMa");
MetadataResponse __attribute__((swiftcall))
swift_getTupleTypeMetadata2(uintptr_t, const void *, const void *, const char *, const void *);

ArrayAllocation __attribute__((swiftcall)) ABISwiftAllocateUninitializedArray(intptr_t, const void *)
    __asm__("_$ss27_allocateUninitializedArrayySayxG_BptBwlF");
intptr_t __attribute__((swiftcall)) ABISwiftArrayCountGetter(const void *, const void *)
    __asm__("_$sSa5countSivg");
void __attribute__((swiftcall)) ABISwiftArraySubscriptGetter(
    __attribute__((swift_indirect_result)) void *, intptr_t, const void *, const void *) __asm__("_$sSayxSicig");

const void *__attribute__((swiftcall)) ABISwiftSetInit(intptr_t, const void *, const void *)
    __asm__("_$sSh15minimumCapacityShyxGSi_tcfC");
bool __attribute__((swiftcall)) ABISwiftSetInsertMember(
    void *, void *, const void *, __attribute__((swift_context)) const void **)
    __asm__("_$sSh6insertySb8inserted_x17memberAfterInserttxnF");
void __attribute__((swiftcall)) ABISwiftSetMakeIterator(
    __attribute__((swift_indirect_result)) void *, const void *, const void *, const void *)
    __asm__("_$sSh12makeIteratorSh0B0Vyx_GyF");
void __attribute__((swiftcall)) ABISwiftSetIteratorNext(
    __attribute__((swift_indirect_result)) void *, const void *, __attribute__((swift_context)) void *)
    __asm__("_$sSh8IteratorV4nextxSgyF");

const void *__attribute__((swiftcall)) ABISwiftDictionaryInit(intptr_t, const void *, const void *, const void *)
    __asm__("_$sSD15minimumCapacitySDyxq_GSi_tcfC");
void __attribute__((swiftcall)) ABISwiftDictionaryUpdateValue(
    __attribute__((swift_indirect_result)) void *, void *, void *, const void *,
    __attribute__((swift_context)) const void **) __asm__("_$sSD11updateValue_6forKeyq_Sgq_n_xtF");
void __attribute__((swiftcall)) ABISwiftDictionaryMakeIterator(
    __attribute__((swift_indirect_result)) void *, const void *, const void *, const void *, const void *)
    __asm__("_$sSD12makeIteratorSD0B0Vyxq__GyF");
void __attribute__((swiftcall)) ABISwiftDictionaryIteratorNext(
    __attribute__((swift_indirect_result)) void *, const void *, __attribute__((swift_context)) void *)
    __asm__("_$sSD8IteratorV4nextx3key_q_5valuetSgyF");
}

namespace {
// Uninitialized storage for one value of a complete metadata's type.
class ValueBuffer {
public:
    explicit ValueBuffer(const void *metadata) {
        auto layout = ABISwiftGetValueLayout(metadata);
        if (posix_memalign(&pointer_, std::max(layout.alignment, sizeof(void *)), std::max<size_t>(layout.size, 1))) {
            abort();
        }
    }
    ~ValueBuffer() { free(pointer_); }
    ValueBuffer(const ValueBuffer &) = delete;
    ValueBuffer &operator=(const ValueBuffer &) = delete;
    void *get() const { return pointer_; }
private:
    void *pointer_ = nullptr;
};

// An Optional's payload is stored at the Optional's address, and tag 0 is `some`.
bool hasPayload(const void *optional, const void *value) {
    uint32_t tag = 1;
    ABISwiftGetEnumTag(optional, value, &tag);
    return tag == 0;
}
}

extern "C" {

const void *ABISwiftHashableConformance(const void *metadata) {
    return ABISwiftConformance(metadata, &ABISwiftHashableDescriptor);
}

const void *ABISwiftArrayCreate(const void *element, intptr_t count, void **elements) {
    auto allocation = ABISwiftAllocateUninitializedArray(count, element);
    *elements = allocation.elements;
    return allocation.array;
}

intptr_t ABISwiftArrayCount(const void *array, const void *element) {
    return ABISwiftArrayCountGetter(array, element);
}

void ABISwiftArrayCopyElement(const void *array, intptr_t index, const void *element, void *destination) {
    ABISwiftArraySubscriptGetter(destination, index, array, element);
}

const void *ABISwiftSetCreate(intptr_t capacity, const void *element, const void *hashable) {
    return ABISwiftSetInit(capacity, element, hashable);
}

bool ABISwiftSetInsert(const void **set, void *member, const void *element, const void *hashable) {
    auto setType = ABISwiftSetMetadata(0, element, hashable).value;
    ValueBuffer present(element);
    bool inserted = ABISwiftSetInsertMember(present.get(), member, setType, set);
    ABISwiftDestroyValue(element, present.get());
    return inserted;
}

void ABISwiftSetForEach(const void *set, const void *element, const void *hashable,
                        void *context, ABISwiftCollectionVisitor visit) {
    auto iteratorType = ABISwiftSetIteratorMetadata(0, element, hashable).value;
    auto optionalType = ABISwiftOptionalMetadata(0, element).value;
    ValueBuffer iterator(iteratorType);
    ValueBuffer next(optionalType);
    const void *consumed;
    ABISwiftCopyValue(ABISwiftSetMetadata(0, element, hashable).value, &consumed, &set);
    ABISwiftSetMakeIterator(iterator.get(), consumed, element, hashable);
    for (;;) {
        ABISwiftSetIteratorNext(next.get(), iteratorType, iterator.get());
        if (!hasPayload(optionalType, next.get())) break;
        visit(context, next.get(), nullptr);
    }
    ABISwiftDestroyValue(iteratorType, iterator.get());
}

const void *ABISwiftDictionaryCreate(intptr_t capacity, const void *key, const void *value, const void *hashable) {
    return ABISwiftDictionaryInit(capacity, key, value, hashable);
}

void ABISwiftDictionaryUpdate(const void **dictionary, void *key, void *value,
                              const void *keyType, const void *valueType, const void *hashable) {
    auto dictionaryType = ABISwiftDictionaryMetadata(0, keyType, valueType, hashable).value;
    auto optionalType = ABISwiftOptionalMetadata(0, valueType).value;
    ValueBuffer previous(optionalType);
    ABISwiftDictionaryUpdateValue(previous.get(), value, key, dictionaryType, dictionary);
    ABISwiftDestroyValue(optionalType, previous.get());
}

void ABISwiftDictionaryForEach(const void *dictionary, const void *keyType, const void *valueType,
                               const void *hashable, void *context, ABISwiftCollectionVisitor visit) {
    auto iteratorType = ABISwiftDictionaryIteratorMetadata(0, keyType, valueType, hashable).value;
    auto elementType = swift_getTupleTypeMetadata2(0, keyType, valueType, "key value ", nullptr).value;
    auto optionalType = ABISwiftOptionalMetadata(0, elementType).value;
    // TupleTypeMetadata: kind, element count, labels, then (type, offset) per element.
    auto valueOffset = reinterpret_cast<const uintptr_t *>(elementType)[3 + 2 + 1];
    ValueBuffer iterator(iteratorType);
    ValueBuffer next(optionalType);
    const void *consumed;
    ABISwiftCopyValue(ABISwiftDictionaryMetadata(0, keyType, valueType, hashable).value, &consumed, &dictionary);
    ABISwiftDictionaryMakeIterator(iterator.get(), consumed, keyType, valueType, hashable);
    for (;;) {
        ABISwiftDictionaryIteratorNext(next.get(), iteratorType, iterator.get());
        if (!hasPayload(optionalType, next.get())) break;
        visit(context, next.get(), static_cast<char *>(next.get()) + valueOffset);
    }
    ABISwiftDestroyValue(iteratorType, iterator.get());
}

}
