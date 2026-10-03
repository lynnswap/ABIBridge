#include <ABIBridge/SwiftInvocation.h>
#include "NativeValueType.hpp"
#include "SwiftCallbackCode.hpp"
#include <ABIBridge/SwiftCallbacks.h>
#include <mutex>
#include <pthread.h>
#include <cstdlib>
#include <cstddef>
#include <ptrauth.h>
#include <algorithm>
#include <cstring>
#include <memory>
#include <optional>
#include <new>
#include <limits>

// Swift's stable runtime uses preserve_most for reference counting on AArch64.
// These operations also handle capture contexts, whose metadata need not be
// ordinary class metadata (https://github.com/swiftlang/swift/blob/main/include/swift/Runtime/HeapObject.h).
#if defined(__aarch64__)
#define ABI_SWIFT_REFCOUNT_CC __attribute__((preserve_most))
#else
#define ABI_SWIFT_REFCOUNT_CC
#endif
extern "C" void *ABI_SWIFT_REFCOUNT_CC swift_retain(void *);
extern "C" void ABI_SWIFT_REFCOUNT_CC swift_release(void *);

void ABIRetainSwiftClosureContext(void *context) { swift_retain(context); }
void ABIReleaseSwiftClosureContext(void *context) { swift_release(context); }

ABIUnmanagedFunction ABIAuthenticateSwiftClosureFunction(const void *function, uint16_t discriminator) {
    if (!function) return nullptr;
#if __has_feature(ptrauth_calls)
    function = ptrauth_auth_and_resign(function, ptrauth_key_function_pointer, discriminator,
        ptrauth_key_function_pointer, ptrauth_function_pointer_type_discriminator(void(void)));
#endif
    ABIUnmanagedFunction result;
    std::memcpy(&result, &function, sizeof(result));
    return result;
}
const void *ABISignSwiftClosureFunction(ABIUnmanagedFunction function, uint16_t discriminator) {
    if (!function) return nullptr;
    const void *result;
    std::memcpy(&result, &function, sizeof(result));
#if __has_feature(ptrauth_calls)
    result = ptrauth_auth_and_resign(result, ptrauth_key_function_pointer,
        ptrauth_function_pointer_type_discriminator(void(void)), ptrauth_key_function_pointer, discriminator);
#endif
    return result;
}

namespace {
using abibridge::TypeStorage;

// Fixed-width fields keep the assembly offsets identical on arm64_32.
struct CallFrame {
    uint64_t integers[8]{};
    uint64_t floating[8]{};
    uint64_t integerResults[4]{};
    uint64_t floatingResults[4]{};
    uint64_t indirectResult = 0;
    uint64_t context = 0;
    uint64_t stack = 0;
    uint64_t stackSize = 0;
    uint64_t error = 0;
};
static_assert(offsetof(CallFrame, integerResults) == 128);
static_assert(offsetof(CallFrame, floatingResults) == 160);
static_assert(offsetof(CallFrame, indirectResult) == 192);
static_assert(offsetof(CallFrame, context) == 200);
static_assert(offsetof(CallFrame, stack) == 208);
static_assert(offsetof(CallFrame, stackSize) == 216);
static_assert(offsetof(CallFrame, error) == 224);

extern "C" void ABIInvokeSwiftAssembly(CallFrame *, ABIUnmanagedFunction, uint64_t);

struct Component {
    size_t offset;
    size_t size;
    bool floating;
    bool optionalSingleton = false;
};
struct Layout {
    std::vector<Component> components;
    bool indirect = false;
};
enum class Bank { integer, floating, stack };
enum class ArgumentSource { parameter, result, error };
struct ArgumentMove {
    size_t argument;
    Component component;
    Bank bank;
    size_t destination;
    bool indirect;
    size_t extent = 0;
    ArgumentSource source = ArgumentSource::parameter;
    TypeStorage *pack = nullptr;
};

void flatten(TypeStorage &type, size_t offset, std::vector<Component> &components) {
    if (!type.fields.empty()) {
        for (size_t index = 0; index < type.fields.size(); ++index)
            flatten(*type.fields[index], offset + type.offsets[index], components);
    } else if (type.size()) {
        const auto kind = type.native()->type;
        components.push_back({offset, type.size(), kind == FFI_TYPE_FLOAT || kind == FFI_TYPE_DOUBLE});
    }
}

Layout lower(TypeStorage &type) {
    if (type.swiftIndirect) return Layout{{}, true};
    if (type.swiftOptionalSingleton) return Layout{{{0, 1, false, true}}, false};
    std::vector<Component> fields;
    flatten(type, 0, fields);
    Layout result;
    // Swift coalesces adjacent integer storage inside a pointer-sized chunk;
    // floating fields stay separate. See Clang's SwiftAggLowering and the Swift
    // ABI CallingConventionSummary, rather than the platform C aggregate rules.
    for (const auto &field : fields) {
        if (!result.components.empty()) {
            auto &previous = result.components.back();
            if (!previous.floating && !field.floating &&
                (previous.offset + previous.size - 1) / sizeof(void *) == field.offset / sizeof(void *)) {
                const auto end = field.offset + field.size;
                size_t width = 1;
                while ((previous.offset / width + 1) * width < end) width *= 2;
                previous.offset = previous.offset / width * width;
                previous.size = width;
                continue;
            }
        }
        result.components.push_back(field);
    }
    // Supported scalars occupy one hardware register, including Int64 on
    // arm64_32. Pointer width controls coalescing, not register capacity.
    result.indirect = result.components.size() > 4;
    return result;
}

void fail(ABIResolutionFailure **error, int code, const char *message) {
    if (error) *error = ABICreateResolutionFailure(code, message);
}

size_t aligned(size_t value, size_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

struct AlignedValue {
    struct Delete {
        std::align_val_t alignment;
        void operator()(void *address) const { ::operator delete(address, alignment); }
    };
    std::unique_ptr<void, Delete> storage;
    AlignedValue(size_t size, size_t alignment)
        : storage(::operator new(aligned(std::max(size_t(1), size), alignment), std::align_val_t(std::max(alignment, alignof(std::max_align_t)))),
                  Delete{std::align_val_t(std::max(alignment, alignof(std::max_align_t)))}) {
        std::memset(storage.get(), 0, size);
    }
    void *data() { return storage.get(); }
};

struct SwiftField {
    std::shared_ptr<TypeStorage> type;
    size_t offset;
};
void expandTuple(const std::shared_ptr<TypeStorage> &type, size_t offset, std::vector<SwiftField> &fields) {
    if (type->swiftTuple) {
        for (size_t index = 0; index < type->fields.size(); ++index)
            expandTuple(type->fields[index], offset + type->offsets[index], fields);
    } else fields.push_back({type, offset});
}
}

ABIValueType *ABICreateSwiftStorageType(
    const ABIValueType *components, size_t size, size_t alignment, ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (!components || components->storage->swiftIndirect || !alignment ||
        (alignment & (alignment - 1)) || alignment > std::numeric_limits<unsigned short>::max()) {
        fail(error, ABIFailureInvalidRequest, "Swift storage must contain its components and have a valid alignment.");
        return nullptr;
    }
    std::vector<Component> fields;
    flatten(*components->storage, 0, fields);
    if (std::any_of(fields.begin(), fields.end(), [size](const Component &field) {
        return field.offset > size || field.size > size - field.offset;
    })) {
        fail(error, ABIFailureInvalidRequest, "Swift ABI components exceed the value's accessible bytes.");
        return nullptr;
    }
    auto source = components->storage;
    if (source->size() == size && source->native()->alignment == alignment)
        return new ABIValueType{std::move(source)};
    auto storage = std::make_shared<TypeStorage>();
    storage->fields.push_back(source);
    storage->offsets.push_back(0);
    storage->elements = {source->native(), nullptr};
    storage->aggregate = {size, static_cast<unsigned short>(alignment), FFI_TYPE_STRUCT, storage->elements.data()};
    return new ABIValueType{std::move(storage)};
}

ABIValueType *ABICreateSwiftOptionalSingletonType(void) {
    auto storage = std::make_shared<TypeStorage>();
    storage->swiftOptionalSingleton = true;
    storage->aggregate = {sizeof(void *), alignof(void *), FFI_TYPE_STRUCT, nullptr};
    return new ABIValueType{std::move(storage)};
}

static void packOptionalSingleton(void *destination, const void *source) {
    uintptr_t value;
    std::memcpy(&value, source, sizeof(value));
    *static_cast<uint8_t *>(destination) = value == 0;
}

static void unpackOptionalSingleton(void *destination, const void *source) {
    // Swift restores the singleton's metadata before loading this value.
    const uintptr_t value = *static_cast<const uint8_t *>(source) == 0;
    std::memcpy(destination, &value, sizeof(value));
}

ABIValueType *ABICreateSwiftIndirectStorageType(
    size_t size, size_t alignment, ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (!alignment || (alignment & (alignment - 1)) ||
        alignment > std::numeric_limits<unsigned short>::max()) {
        fail(error, ABIFailureInvalidRequest, "Indirect Swift storage requires a valid alignment.");
        return nullptr;
    }
    auto storage = std::make_shared<TypeStorage>();
    storage->swiftIndirect = true;
    storage->aggregate = {size, static_cast<unsigned short>(alignment), FFI_TYPE_STRUCT, nullptr};
    return new ABIValueType{std::move(storage)};
}

ABIValueType *ABICreateSwiftTupleStorageType(
    const ABIValueType *const *fields, const size_t *offsets, size_t count,
    size_t size, size_t alignment, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if ((count && (!fields || !offsets)) || !alignment || (alignment & (alignment - 1)) ||
        alignment > std::numeric_limits<unsigned short>::max()) {
        fail(error, ABIFailureInvalidRequest, "A Swift tuple requires element offsets and valid storage alignment.");
        return nullptr;
    }
    auto storage = std::make_shared<TypeStorage>();
    storage->swiftTuple = true;
    for (size_t index = 0; index < count; ++index) {
        if (!fields[index] || offsets[index] > size || fields[index]->storage->size() > size - offsets[index]) {
            fail(error, ABIFailureInvalidRequest, "Swift tuple elements must fit their concrete storage.");
            return nullptr;
        }
        storage->fields.push_back(fields[index]->storage);
        storage->offsets.push_back(offsets[index]);
        storage->elements.push_back(fields[index]->storage->native());
    }
    storage->elements.push_back(nullptr);
    storage->aggregate = {size, static_cast<unsigned short>(alignment), FFI_TYPE_STRUCT, storage->elements.data()};
    return new ABIValueType{std::move(storage)};
}

ABIValueType *ABICreateSwiftPackStorageType(
    const ABIValueType *const *fields, const size_t *offsets, size_t count,
    size_t size, size_t alignment, ABIResolutionFailure **error) {
    auto type = ABICreateSwiftTupleStorageType(fields, offsets, count, size, alignment, error);
    if (type) {
        type->storage->swiftTuple = false;
        type->storage->swiftPack = true;
        type->storage->swiftIndirect = true;
    }
    return type;
}

static std::vector<void *> swiftPackElements(TypeStorage &type, void *value) {
    std::vector<void *> elements;
    elements.reserve(type.fields.size());
    for (const auto offset : type.offsets) elements.push_back(static_cast<uint8_t *>(value) + offset);
    return elements;
}

struct ABISwiftCallInterface {
    std::shared_ptr<TypeStorage> result;
    std::shared_ptr<TypeStorage> directResult;
    struct ResultCopy { size_t logical, direct, size; bool optionalSingleton = false; };
    std::vector<ResultCopy> resultCopies;
    std::vector<SwiftField> indirectResults;
    std::vector<std::shared_ptr<TypeStorage>> parameters;
    Layout resultLayout;
    std::shared_ptr<TypeStorage> errorResult;
    Layout errorLayout;
    bool typedError = false;
    bool indirectError = false;
    std::vector<ArgumentMove> moves;
    size_t stackSize = 0;
};

static void prepareSwiftResult(ABISwiftCallInterface &interface) {
    interface.directResult = interface.result;
    std::vector<SwiftField> fields;
    expandTuple(interface.result, 0, fields);
    if ((interface.result->swiftTuple || interface.result->swiftOptionalSingleton) &&
        std::any_of(fields.begin(), fields.end(), [](const SwiftField &field) {
            return field.type->swiftIndirect || field.type->swiftOptionalSingleton || lower(*field.type).components.empty();
        })) {
        auto direct = std::make_shared<TypeStorage>();
        size_t size = 0, alignment = 1;
        for (const auto &field : fields) {
            if (field.type->swiftIndirect) { interface.indirectResults.push_back(field); continue; }
            if (lower(*field.type).components.empty()) continue;
            auto physical = field.type;
            if (physical->swiftOptionalSingleton) {
                physical = std::make_shared<TypeStorage>();
                physical->scalar = &ffi_type_uint8;
            }
            size = aligned(size, physical->native()->alignment);
            direct->fields.push_back(physical);
            direct->offsets.push_back(size);
            direct->elements.push_back(physical->native());
            interface.resultCopies.push_back({field.offset, size, field.type->size(), field.type->swiftOptionalSingleton});
            size += physical->size();
            alignment = std::max(alignment, size_t(physical->native()->alignment));
        }
        direct->elements.push_back(nullptr);
        direct->aggregate = {size, static_cast<unsigned short>(alignment), FFI_TYPE_STRUCT, direct->elements.data()};
        // Swift uses the dedicated indirect-result register only when the one
        // formal output is the entire result. Otherwise outputs precede inputs.
        if (interface.indirectResults.size() == 1 && size == 0) {
            const auto field = interface.indirectResults.front();
            direct = field.type;
            interface.resultCopies = {{field.offset, 0, field.type->size()}};
            interface.indirectResults.clear();
        }
        interface.directResult = std::move(direct);
    }
    interface.resultLayout = lower(*interface.directResult);
}

struct SwiftResultStorage {
    std::optional<AlignedValue> temporary;
    std::vector<void *> pack;
    void *direct;
    explicit SwiftResultStorage(const ABISwiftCallInterface &interface, void *logical) : direct(logical) {
        if (interface.directResult->swiftPack) {
            const auto offset = interface.resultCopies.empty() ? 0 : interface.resultCopies[0].logical;
            pack = swiftPackElements(*interface.directResult, static_cast<uint8_t *>(logical) + offset);
            direct = pack.data();
        } else if (interface.resultCopies.size() == 1 && interface.resultCopies[0].direct == 0 &&
            !interface.resultCopies[0].optionalSingleton &&
            interface.resultCopies[0].size == interface.directResult->size()) {
            direct = static_cast<uint8_t *>(logical) + interface.resultCopies[0].logical;
        } else if (!interface.resultCopies.empty()) {
            temporary.emplace(interface.directResult->size(), interface.directResult->native()->alignment);
            direct = temporary->data();
        }
    }
    void copyToLogical(const ABISwiftCallInterface &interface, void *logical) {
        if (!temporary) return;
        for (const auto &copy : interface.resultCopies) {
            auto destination = static_cast<uint8_t *>(logical) + copy.logical;
            auto source = static_cast<const uint8_t *>(direct) + copy.direct;
            if (copy.optionalSingleton) unpackOptionalSingleton(destination, source);
            else std::memcpy(destination, source, copy.size);
        }
    }
};

static ABISwiftCallInterface *createSwiftCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, const ABIValueType *errorResult, bool typedError, ABIResolutionFailure **error,
    bool asyncEntry = false)
{
    if (error) *error = nullptr;
#if !defined(__aarch64__) && !defined(__x86_64__)
    fail(error, ABIFailureUnsupportedDeclaration, "No Swift call implementation for this architecture.");
    return nullptr;
#else
    if (!result || (count && !parameters)) {
        fail(error, ABIFailureInvalidRequest, "A result and parameter storage descriptions are required.");
        return nullptr;
    }
    auto interface = std::make_unique<ABISwiftCallInterface>();
    interface->result = result->storage;
    prepareSwiftResult(*interface);
    if (errorResult) {
        if (!typedError && errorResult->storage->size() != sizeof(void *)) {
            fail(error, ABIFailureInvalidRequest, "An untyped Swift error requires one error-reference word.");
            return nullptr;
        }
        interface->errorResult = errorResult->storage;
        interface->errorLayout = lower(*errorResult->storage);
        interface->typedError = typedError;
        // Swift merges direct typed errors into integer result registers.
        // Floating/indirect errors and indirect ordinary results need a
        // separate trailing error-output pointer (GenCall.cpp).
        interface->indirectError = typedError && (interface->resultLayout.indirect || !interface->indirectResults.empty() ||
            interface->errorLayout.indirect ||
            std::any_of(interface->errorLayout.components.begin(), interface->errorLayout.components.end(),
                [](const Component &component) { return component.floating; }));
    }
    size_t integers = 0, floating = 0, stack = 0;
#if defined(__x86_64__)
    constexpr size_t integerLimit = 6;
#else
    constexpr size_t integerLimit = 8;
#endif
    auto append = [&](ArgumentMove move) {
        const auto &component = move.component;
        if (component.floating && floating < 8) {
            move.bank = Bank::floating;
            move.destination = floating++;
        } else if (!component.floating && integers < integerLimit) {
            move.bank = Bank::integer;
            move.destination = integers++;
        } else {
#if defined(__x86_64__)
            stack = aligned(stack, 8);
            move.destination = stack;
            stack += 8;
#else
            stack = aligned(stack, component.size);
            move.destination = stack;
            stack += component.size;
#endif
        }
        interface->moves.push_back(move);
    };
    for (size_t index = 0; index < interface->indirectResults.size(); ++index) {
        const auto &field = interface->indirectResults[index];
        append({index, {field.offset, sizeof(void *), false}, Bank::stack, 0, true,
                field.type->size(), ArgumentSource::result, field.type->swiftPack ? field.type.get() : nullptr});
    }
    for (size_t index = 0; index < count; ++index) {
        if (!parameters[index]) {
            fail(error, ABIFailureInvalidRequest, "Each Swift parameter requires a storage description.");
            return nullptr;
        }
        interface->parameters.push_back(parameters[index]->storage);
        std::vector<SwiftField> fields;
        expandTuple(parameters[index]->storage, 0, fields);
        for (const auto &field : fields) {
            auto layout = lower(*field.type);
            if (layout.indirect) layout.components = {{0, sizeof(void *), false}};
            for (auto component : layout.components) {
                const auto available = field.type->size() - component.offset;
                component.offset += field.offset;
                append({index, component, Bank::stack, 0, layout.indirect, available, ArgumentSource::parameter,
                        field.type->swiftPack ? field.type.get() : nullptr});
            }
        }
    }
    if (interface->indirectError)
        append({0, {0, sizeof(void *), false}, Bank::stack, 0, false, 0, ArgumentSource::error});
#if defined(__x86_64__)
    // swifttailcc reuses the caller's reserved eight-byte slot. Assembly copies
    // every argument byte, but only whole 16-byte groups change the stack pointer.
    interface->stackSize = asyncEntry ? stack : aligned(stack, 16);
#else
    interface->stackSize = aligned(stack, 16);
#endif
    return interface.release();
#endif
}

ABISwiftCallInterface *ABICreateSwiftCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, ABIResolutionFailure **error) {
    return createSwiftCallInterface(result, parameters, count, nullptr, false, error);
}

ABISwiftCallInterface *ABICreateSwiftThrowingCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    const ABIValueType *errorResult, bool typedError, ABIResolutionFailure **error) {
    if (!errorResult) {
        fail(error, ABIFailureInvalidRequest, "A throwing Swift call requires an error representation.");
        return nullptr;
    }
    return createSwiftCallInterface(result, parameters, count, errorResult, typedError, error);
}

void ABIReleaseSwiftCallInterface(ABISwiftCallInterface *interface) { delete interface; }
bool ABISwiftValueIsIndirect(const ABIValueType *type) { return lower(*type->storage).indirect; }

static void marshalSwiftArguments(
    ABISwiftCallInterface *interface, void *const *arguments, void *result, void *errorResult,
    CallFrame &frame, std::vector<uint8_t> &stack, std::vector<std::vector<void *>> &packs) {
    uintptr_t errorAddress = reinterpret_cast<uintptr_t>(errorResult);
    for (const auto &move : interface->moves) {
        const bool errorArgument = move.source == ArgumentSource::error;
        const auto base = errorArgument ? reinterpret_cast<const uint8_t *>(&errorAddress)
            : static_cast<const uint8_t *>(move.source == ArgumentSource::result ? result : arguments[move.argument]);
        const auto source = base + move.component.offset;
        void *destination;
        switch (move.bank) {
            case Bank::integer: destination = &frame.integers[move.destination]; break;
            case Bank::floating: destination = &frame.floating[move.destination]; break;
            case Bank::stack: destination = stack.data() + move.destination; break;
        }
        if (move.indirect) {
            const void *value = source;
            if (move.pack) {
                packs.push_back(swiftPackElements(*move.pack, const_cast<uint8_t *>(source)));
                value = packs.back().data();
            }
            const uintptr_t address = reinterpret_cast<uintptr_t>(value);
            std::memcpy(destination, &address, sizeof(address));
        } else if (move.component.optionalSingleton) {
            packOptionalSingleton(destination, source);
        } else {
            const auto available = errorArgument ? sizeof(errorAddress) : move.extent;
            std::memcpy(destination, source, std::min(move.component.size, available));
        }
    }
}

static bool copySwiftCompletion(
    ABISwiftCallInterface *interface, const CallFrame &frame, void *result, SwiftResultStorage &storage, void *errorResult) {
    auto copyRegisters = [&](const Layout &layout, TypeStorage &type, void *output) {
        size_t integers = 0, floating = 0;
        for (const auto &component : layout.components) {
            const auto source = component.floating ? &frame.floatingResults[floating++] : &frame.integerResults[integers++];
            // Coalesced register padding is not part of a live Swift value.
            const auto available = type.size() - component.offset;
            std::memcpy(static_cast<uint8_t *>(output) + component.offset, source, std::min(component.size, available));
        }
    };
    if (interface->errorResult && frame.error) {
        if (!interface->typedError) {
            const auto reference = uintptr_t(frame.error);
            std::memcpy(errorResult, &reference, sizeof(reference));
        } else if (!interface->indirectError) {
            copyRegisters(interface->errorLayout, *interface->errorResult, errorResult);
        }
        return true;
    }
    if (!interface->resultLayout.indirect)
        copyRegisters(interface->resultLayout, *interface->directResult, storage.direct);
    storage.copyToLogical(*interface, result);
    return false;
}

static bool invokeSwiftCallInterface(
    ABISwiftCallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, const void *context,
    void *errorResult, bool *didThrow, ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (didThrow) *didThrow = false;
    if (!interface || !function || (interface->result->size() && !result) ||
        (!interface->parameters.empty() && !arguments)) {
        fail(error, ABIFailureInvalidRequest, "A Swift call interface, function and value storage are required.");
        return false;
    }
    if (interface->errorResult && (!didThrow ||
        ((interface->errorResult->size() || interface->indirectError) && !errorResult))) {
        fail(error, ABIFailureInvalidRequest, "A throwing Swift call requires error storage and a failure indicator.");
        return false;
    }
    for (size_t index = 0; index < interface->parameters.size(); ++index) {
        if (!arguments[index]) {
            fail(error, ABIFailureInvalidRequest, "Each Swift argument requires live value storage.");
            return false;
        }
    }
    CallFrame frame;
    std::vector<uint8_t> stack(interface->stackSize);
    frame.stack = reinterpret_cast<uintptr_t>(stack.data());
    frame.stackSize = stack.size();
    frame.context = reinterpret_cast<uintptr_t>(context);
    SwiftResultStorage resultStorage(*interface, result);
    std::vector<std::vector<void *>> packs;
    if (interface->resultLayout.indirect)
        frame.indirectResult = reinterpret_cast<uintptr_t>(resultStorage.direct);
    marshalSwiftArguments(interface, arguments, result, errorResult, frame, stack, packs);
    uint64_t discriminator = 0;
#if __has_feature(ptrauth_calls)
    discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
    ABIInvokeSwiftAssembly(&frame, function, discriminator);
    const bool threw = copySwiftCompletion(interface, frame, result, resultStorage, errorResult);
    if (didThrow) *didThrow = threw;
    return true;
}

bool ABIUnsafeInvokeSwiftCallInterface(
    ABISwiftCallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, const void *context, ABIResolutionFailure **error) {
    return invokeSwiftCallInterface(interface, function, result, arguments, context, nullptr, nullptr, error);
}

bool ABIUnsafeInvokeSwiftThrowingCallInterface(
    ABISwiftCallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, const void *context,
    void *errorResult, bool *didThrow, ABIResolutionFailure **error) {
    return invokeSwiftCallInterface(interface, function, result, arguments, context, errorResult, didThrow, error);
}


namespace swift { class AsyncContext; }
using SwiftAsyncResume = __attribute__((swiftasynccall)) void(
    swift::AsyncContext * __attribute__((swift_async_context)));
struct SwiftExecutorRef { uintptr_t identity, implementation; };
extern "C" __attribute__((swiftcall)) void *swift_task_alloc(size_t);
extern "C" __attribute__((swiftcall)) void swift_task_dealloc(void *);
extern "C" __attribute__((swiftcall)) SwiftExecutorRef swift_task_getCurrentExecutor();
extern "C" __attribute__((swiftcall)) void *swift_task_getCurrent();
const void *ABISwiftCurrentTask(void) { return swift_task_getCurrent(); }

#if __has_feature(ptrauth_calls)
#define ABI_ASYNC_PARENT __ptrauth(ptrauth_key_process_independent_data, 1, 0xbda2)
#define ABI_ASYNC_RESUME __ptrauth(ptrauth_key_function_pointer, 1, 0xd707)
#else
#define ABI_ASYNC_PARENT
#define ABI_ASYNC_RESUME
#endif
struct SwiftAsyncHeader {
    swift::AsyncContext * ABI_ASYNC_PARENT parent;
    SwiftAsyncResume * ABI_ASYNC_RESUME resume;
};
struct alignas(16) SwiftAsyncBridgeContext {
    SwiftAsyncHeader header;
    ABISwiftAsyncInvocation *invocation;
    SwiftAsyncHeader *callee;
    SwiftExecutorRef executor;
};
static_assert(sizeof(SwiftAsyncBridgeContext) == (sizeof(void *) == 8 ? 48 : 32));

struct SwiftAsyncTransfer {
    CallFrame values;
    uint64_t function = 0;
    uint64_t asyncContext = 0;
    uint64_t discriminator = 0;
};
static_assert(offsetof(SwiftAsyncTransfer, function) == 232);
static_assert(offsetof(SwiftAsyncTransfer, asyncContext) == 240);
static_assert(offsetof(SwiftAsyncTransfer, discriminator) == 248);

struct ABISwiftAsyncCallInterface {
    std::shared_ptr<ABISwiftCallInterface> entry, completion;
    size_t argumentCount;
    bool inheritsCallerIsolation;
};
struct ABISwiftAsyncInvocation {
    std::shared_ptr<ABISwiftCallInterface> entry, completion;
    SwiftAsyncTransfer transfer;
    std::vector<uint8_t> stack;
    std::vector<void *> arguments;
    std::vector<void *> outputs;
    std::vector<std::vector<void *>> packs;
    std::optional<SwiftResultStorage> resultStorage;
    uintptr_t isolation[2]{};
    uint32_t contextSize;
    void *result;
    void *errorResult;
    bool didThrow = false;
};

extern "C" __attribute__((swiftasynccall))
void ABISwiftAsyncResume(swift::AsyncContext * __attribute__((swift_async_context)));
extern "C" __attribute__((swiftasynccall))
void ABISwiftAsyncResumeCaller(swift::AsyncContext *context __attribute__((swift_async_context))) {
    auto *header = reinterpret_cast<SwiftAsyncHeader *>(context);
    [[clang::musttail]] return header->resume(context);
}

ABISwiftAsyncCallInterface *ABICreateSwiftAsyncCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters, size_t count,
    const ABIValueType *errorResult, bool typedError, bool inheritsCallerIsolation,
    ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (count && !parameters) {
        fail(error, ABIFailureInvalidRequest, "Async arguments require native layouts.");
        return nullptr;
    }
    auto completion = std::shared_ptr<ABISwiftCallInterface>(
        createSwiftCallInterface(result, nullptr, 0, errorResult, typedError, error));
    if (!completion) return nullptr;
    using Type = std::unique_ptr<ABIValueType, decltype(&ABIReleaseValueType)>;
    Type pointer(ABICreateScalarType(ABIValuePointer, error), ABIReleaseValueType);
    Type empty(ABICreateScalarType(ABIValueVoid, error), ABIReleaseValueType);
    if (!pointer || !empty) return nullptr;
    std::vector<const ABIValueType *> inputs;
    if (completion->resultLayout.indirect) inputs.push_back(pointer.get());
    for (size_t index = 0; index < completion->indirectResults.size(); ++index) inputs.push_back(pointer.get());
    if (inheritsCallerIsolation) { inputs.push_back(pointer.get()); inputs.push_back(pointer.get()); }
    for (size_t index = 0; index < count; ++index) inputs.push_back(parameters[index]);
    if (completion->indirectError) inputs.push_back(pointer.get());
    auto entry = std::shared_ptr<ABISwiftCallInterface>(
        createSwiftCallInterface(empty.get(), inputs.data(), inputs.size(), nullptr, false, error, true));
    if (!entry) return nullptr;
    return new ABISwiftAsyncCallInterface{std::move(entry), std::move(completion), count, inheritsCallerIsolation};
}
void ABIReleaseSwiftAsyncCallInterface(ABISwiftAsyncCallInterface *interface) { delete interface; }

ABISwiftAsyncInvocation *ABICreateSwiftAsyncInvocation(
    ABISwiftAsyncCallInterface *interface, ABIUnmanagedFunction function, uint32_t contextSize,
    void *result, void *const *arguments, const void *context, void *errorResult, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!interface || !function || contextSize < sizeof(SwiftAsyncHeader) ||
        (interface->completion->result->size() && !result) ||
        (interface->argumentCount && !arguments) ||
        (interface->completion->errorResult && !errorResult)) {
        fail(error, ABIFailureInvalidRequest, "Async invocation requires code, a context header, and live value buffers.");
        return nullptr;
    }
    auto invocation = std::make_unique<ABISwiftAsyncInvocation>();
    invocation->entry = interface->entry;
    invocation->completion = interface->completion;
    invocation->contextSize = contextSize;
    invocation->result = result;
    invocation->resultStorage.emplace(*interface->completion, result);
    invocation->errorResult = errorResult;
    invocation->stack.resize(interface->entry->stackSize);
    auto &frame = invocation->transfer.values;
    frame.stack = reinterpret_cast<uintptr_t>(invocation->stack.data());
    frame.stackSize = invocation->stack.size();
    frame.context = reinterpret_cast<uintptr_t>(context);
    std::memcpy(&invocation->transfer.function, &function, sizeof(function));
#if __has_feature(ptrauth_calls)
    invocation->transfer.discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
    auto &inputs = invocation->arguments;
    if (interface->completion->resultLayout.indirect) inputs.push_back(&invocation->resultStorage->direct);
    for (const auto &field : interface->completion->indirectResults) {
        void *output = static_cast<uint8_t *>(result) + field.offset;
        if (field.type->swiftPack) {
            invocation->packs.push_back(swiftPackElements(*field.type, output));
            output = invocation->packs.back().data();
        }
        invocation->outputs.push_back(output);
    }
    for (auto &output : invocation->outputs) inputs.push_back(&output);
    if (interface->inheritsCallerIsolation) {
        inputs.push_back(&invocation->isolation[0]);
        inputs.push_back(&invocation->isolation[1]);
    }
    for (size_t index = 0; index < interface->argumentCount; ++index) {
        if (!arguments[index]) {
            fail(error, ABIFailureInvalidRequest, "Each async argument requires live storage.");
            return nullptr;
        }
        inputs.push_back(arguments[index]);
    }
    if (interface->completion->indirectError) inputs.push_back(&invocation->errorResult);
    return invocation.release();
}
bool ABISwiftAsyncInvocationDidThrow(const ABISwiftAsyncInvocation *invocation) { return invocation->didThrow; }
void ABIReleaseSwiftAsyncInvocation(ABISwiftAsyncInvocation *invocation) { delete invocation; }

// These helpers run synchronously on the active Swift task. Assembly owns the
// tail transfer; no C frame or borrowed stack argument survives suspension.
extern "C" SwiftAsyncTransfer *ABIPrepareSwiftAsyncEntry(
    ABISwiftAsyncInvocation *invocation, SwiftAsyncBridgeContext *bridge, uintptr_t actor, uintptr_t witness) {
    bridge->invocation = invocation;
    bridge->executor = swift_task_getCurrentExecutor();
    invocation->isolation[0] = actor;
    invocation->isolation[1] = witness;
    marshalSwiftArguments(invocation->entry.get(), invocation->arguments.data(), nullptr, nullptr,
                          invocation->transfer.values, invocation->stack, invocation->packs);
    bridge->callee = static_cast<SwiftAsyncHeader *>(swift_task_alloc(invocation->contextSize));
    bridge->callee->parent = reinterpret_cast<swift::AsyncContext *>(bridge);
    bridge->callee->resume = ABISwiftAsyncResume;
    invocation->transfer.asyncContext = reinterpret_cast<uintptr_t>(bridge->callee);
    return &invocation->transfer;
}

extern "C" SwiftAsyncTransfer *ABICompleteSwiftAsync(
    SwiftAsyncHeader *callee, const CallFrame *returned) {
    auto *bridge = reinterpret_cast<SwiftAsyncBridgeContext *>(callee->parent);
    auto *invocation = bridge->invocation;
    invocation->didThrow = copySwiftCompletion(invocation->completion.get(), *returned,
                                               invocation->result, *invocation->resultStorage, invocation->errorResult);
    swift_task_dealloc(callee);
    auto &transfer = invocation->transfer;
    transfer.asyncContext = reinterpret_cast<uintptr_t>(bridge);
    // swift_task_switch takes an ordinary discriminator-zero continuation.
    auto *resume = ABISwiftAsyncResumeCaller;
#if __has_feature(ptrauth_calls)
    resume = ptrauth_sign_unauthenticated(ptrauth_strip(resume, ptrauth_key_function_pointer),
                                         ptrauth_key_function_pointer, 0);
#endif
    transfer.values.integers[0] = 0;
    std::memcpy(&transfer.values.integers[0], &resume, sizeof(resume));
    transfer.values.integers[1] = bridge->executor.identity;
    transfer.values.integers[2] = bridge->executor.implementation;
    return &transfer;
}

namespace {
struct SwiftHandler {
    ABISwiftCallbackFunctions functions{};
    void *context = nullptr;
    ~SwiftHandler() { if (functions.releaseContext) functions.releaseContext(context); }
};
struct SwiftClosureHandler {
    bool usesNativeContext = false;
    void (*invoke)(void *, void *const *, void *) = nullptr;
    bool (*invokeThrowing)(void *, void *const *, void *, void *) = nullptr;
    void *(*copyCodeOwner)(void *) = nullptr;
    void *(*copyBodyOwner)(void *) = nullptr;
    ABISwiftResultInitializer initializeResult = nullptr;
    void (*releaseContext)(void *) = nullptr;
    void *context = nullptr;
    ~SwiftClosureHandler() { if (releaseContext) releaseContext(context); }
};
struct SwiftFallbackOwner {
    void *context = nullptr;
    void (*release)(void *) = nullptr;
    ~SwiftFallbackOwner() { if (release) release(context); }
};
struct SwiftOwnedResult {
    AlignedValue value;
    SwiftHandler &handler;
    bool initialized = false;
    bool isError;
    SwiftOwnedResult(TypeStorage &type, SwiftHandler &handler, bool isError = false)
        : value(type.size(), type.native()->alignment), handler(handler), isError(isError) {}
    ~SwiftOwnedResult() { clear(); }
    void clear() {
        const bool owned = initialized;
        initialized = false;
        const auto destroy = isError ? handler.functions.destroyError : handler.functions.destroyResult;
        if (owned && destroy) destroy(handler.context, value.data());
    }
};
}

struct ABISwiftCallback {
    ABISwiftCallInterface interface;
    ABIUnmanagedFunction fallback;
    SwiftFallbackOwner fallbackOwner;
    std::mutex mutex;
    std::shared_ptr<SwiftHandler> handler;
    std::unique_ptr<SwiftClosureHandler> closure;
    std::unique_ptr<abibridge::SwiftCallbackCode> code;
    ABISwiftCallback(const ABISwiftCallInterface &interface, ABIUnmanagedFunction fallback)
        : interface(interface), fallback(fallback) {}
};

struct ABISwiftClosureCallback {
    ABISwiftCallback entry;
    explicit ABISwiftClosureCallback(const ABISwiftCallInterface &interface) : entry(interface, nullptr) {}
};

static ABISwiftClosureCallback *createSwiftClosureCallback(ABISwiftCallInterface *interface,
    ABISwiftClosureCallbackFunctions normal, ABISwiftThrowingClosureCallbackFunctions throwing,
    void *context, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (interface && interface->errorResult && !throwing.invoke) {
        fail(error, ABIFailureUnsupportedDeclaration, "Throwing Swift callbacks require an error-result handler.");
        return nullptr;
    }
    if (!interface || (!normal.invoke && !throwing.invoke)) {
        fail(error, ABIFailureInvalidRequest, "A concrete Swift call interface and closure callback are required.");
        return nullptr;
    }
    auto callback = std::make_unique<ABISwiftClosureCallback>(*interface);
    auto &entry = callback->entry;
    entry.code = std::make_unique<abibridge::SwiftCallbackCode>(&entry, error, true);
    if (!entry.code->function()) return nullptr;
    entry.closure = std::make_unique<SwiftClosureHandler>();
    entry.closure->invoke = normal.invoke;
    entry.closure->invokeThrowing = throwing.invoke;
    entry.closure->releaseContext = throwing.invoke ? throwing.releaseContext : normal.releaseContext;
    entry.closure->copyCodeOwner = throwing.invoke ? throwing.copyCodeOwner : normal.copyCodeOwner;
    entry.closure->copyBodyOwner = throwing.invoke ? throwing.copyBodyOwner : normal.copyBodyOwner;
    entry.closure->initializeResult = throwing.invoke ? throwing.initializeResult : normal.initializeResult;
    entry.closure->usesNativeContext = throwing.invoke ? throwing.usesNativeContext : normal.usesNativeContext;
    entry.closure->context = context;
    return callback.release();
}
ABISwiftClosureCallback *ABICreateSwiftClosureCallback(ABISwiftCallInterface *interface,
    ABISwiftClosureCallbackFunctions functions, void *context, ABIResolutionFailure **error) {
    return createSwiftClosureCallback(interface, functions, {}, context, error);
}
ABISwiftClosureCallback *ABICreateSwiftThrowingClosureCallback(ABISwiftCallInterface *interface,
    ABISwiftThrowingClosureCallbackFunctions functions, void *context, ABIResolutionFailure **error) {
    return createSwiftClosureCallback(interface, {}, functions, context, error);
}
ABIUnmanagedFunction ABISwiftClosureCallbackFunction(const ABISwiftClosureCallback *callback) {
    return callback ? callback->entry.code->function() : nullptr;
}
void ABIReleaseSwiftClosureCallback(ABISwiftClosureCallback *callback) { delete callback; }
bool ABIIsSwiftClosureCallbackFunction(ABIUnmanagedFunction function) {
    return abibridge::SwiftCallbackCode::closureContext(function) != nullptr;
}
void *ABICopySwiftClosureCallbackCodeOwner(ABIUnmanagedFunction function, void *nativeContext) {
    auto *callback = static_cast<ABISwiftCallback *>(abibridge::SwiftCallbackCode::closureContext(function));
    if (!callback || !callback->closure->copyCodeOwner) return nullptr;
    return callback->closure->copyCodeOwner(callback->closure->usesNativeContext ? nativeContext : callback->closure->context);
}
void *ABICopySwiftClosureCallbackBodyOwner(ABIUnmanagedFunction function, void *nativeContext) {
    auto *callback = static_cast<ABISwiftCallback *>(abibridge::SwiftCallbackCode::closureContext(function));
    if (!callback || !callback->closure->copyBodyOwner) return nullptr;
    return callback->closure->copyBodyOwner(callback->closure->usesNativeContext ? nativeContext : callback->closure->context);
}

struct ABISwiftIncomingCall {
    ABIUnmanagedFunction fallback;
    CallFrame &frame;
    std::optional<ABISwiftAsyncCallInterface> asynchronous;
    uint32_t contextSize = 0;
    const void *task = nullptr;
    std::vector<void *> outputs;
    void *indirectResult = nullptr;
    uintptr_t isolation[2]{};
    ABISwiftCallInterface interface;
    std::shared_ptr<SwiftHandler> handler;
    std::unique_ptr<SwiftOwnedResult> pendingResult, pendingError;
    std::vector<AlignedValue> storage;
    std::vector<void *> arguments;
    const void *receiver;
    void *indirectError = nullptr;
    pthread_t thread = pthread_self();
    std::unique_ptr<SwiftOwnedResult> completed;
    std::unique_ptr<SwiftOwnedResult> assigned;
    bool active = true;
    bool untouchedFallback = false;
    bool prepared = false;

    ABISwiftIncomingCall(ABISwiftCallback &callback, std::shared_ptr<SwiftHandler> handler,
                        CallFrame &frame)
        : fallback(callback.fallback), frame(frame), interface(callback.interface), handler(std::move(handler)),
          receiver(reinterpret_cast<const void *>(frame.context)) {}
    ABISwiftIncomingCall(const ABISwiftAsyncCallInterface &interface, ABIUnmanagedFunction fallback,
                        uint32_t contextSize, CallFrame &frame)
        : fallback(fallback), frame(frame), asynchronous(interface), contextSize(contextSize), task(swift_task_getCurrent()),
          interface(*interface.completion), receiver(reinterpret_cast<const void *>(frame.context)) {}
    ~ABISwiftIncomingCall() {
        if (prepared && !untouchedFallback && handler->functions.destroyConsumedArguments)
            handler->functions.destroyConsumedArguments(handler->context, receiver, arguments.data(), arguments.size());
    }
};

ABISwiftCallback *ABICreateSwiftCallback(ABISwiftCallInterface *interface,
    ABIUnmanagedFunction fallback, ABISwiftCallbackFunctions functions, void *context,
    void *fallbackOwner, void (*releaseFallbackOwner)(void *), ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (!interface || !fallback || !functions.invoke) {
        fail(error, ABIFailureInvalidRequest, "A concrete Swift call interface, fallback and callback are required.");
        return nullptr;
    }
    auto callback = std::make_unique<ABISwiftCallback>(*interface, fallback);
    callback->code = std::make_unique<abibridge::SwiftCallbackCode>(callback.get(), error);
    if (!callback->code->function()) return nullptr;
    {
        std::lock_guard lock(callback->mutex);
        callback->handler = std::make_shared<SwiftHandler>();
        callback->handler->functions = functions;
        callback->handler->context = context;
        callback->fallbackOwner.context = fallbackOwner;
        callback->fallbackOwner.release = releaseFallbackOwner;
    }
    return callback.release();
}
ABIUnmanagedFunction ABISwiftCallbackFunction(const ABISwiftCallback *callback) {
    return callback ? callback->code->function() : nullptr;
}
void ABIClearSwiftCallback(ABISwiftCallback *callback) {
    if (!callback) return;
    std::shared_ptr<SwiftHandler> previous;
    { std::lock_guard lock(callback->mutex); previous = std::move(callback->handler); }
}
void ABIReleaseSwiftCallback(ABISwiftCallback *callback) { delete callback; }

namespace {
bool checkIncoming(ABISwiftIncomingCall *call, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!call) { fail(error, ABIFailureInvalidRequest, "A live Swift callback invocation is required."); return false; }
    if (!call->asynchronous && !pthread_equal(call->thread, pthread_self())) {
        fail(error, ABIFailureWrongThread, "A Swift callback invocation stays on its entering thread."); return false;
    }
    if (call->asynchronous && call->task != swift_task_getCurrent()) {
        fail(error, ABIFailureInvalidRequest, "An asynchronous Swift hook stays on its entering task."); return false;
    }
    if (!call->active) { fail(error, ABIFailureInvalidRequest, "The Swift callback invocation has expired."); return false; }
    return true;
}

void unpackArguments(const ABISwiftCallInterface &interface, CallFrame &frame,
                     std::vector<AlignedValue> &storage, std::vector<void *> &arguments, void **errorResult = nullptr,
                     bool borrowIndirect = false) {
    storage.reserve(interface.parameters.size());
    arguments.reserve(interface.parameters.size());
    for (const auto &type : interface.parameters) {
        if (borrowIndirect && !type->swiftTuple && !type->swiftPack && lower(*type).indirect) {
            arguments.push_back(nullptr);
            continue;
        }
        storage.emplace_back(type->size(), type->native()->alignment);
        arguments.push_back(storage.back().data());
    }
    for (const auto &move : interface.moves) {
        if (move.source == ArgumentSource::result) continue;
        const void *source = nullptr;
        switch (move.bank) {
            case Bank::integer: source = &frame.integers[move.destination]; break;
            case Bank::floating: source = &frame.floating[move.destination]; break;
            case Bank::stack: source = reinterpret_cast<const uint8_t *>(frame.stack) + move.destination; break;
        }
        if (move.source == ArgumentSource::error) {
            // The trailing typed-error pointer is hidden from the Swift body.
            if (errorResult) std::memcpy(errorResult, source, sizeof(void *));
            continue;
        }
        auto *destination = static_cast<uint8_t *>(arguments[move.argument]);
        if (move.indirect) {
            uintptr_t pointer = 0;
            std::memcpy(&pointer, source, sizeof(pointer));
            if (move.pack) {
                auto **elements = reinterpret_cast<void **>(pointer);
                for (size_t index = 0; index < move.pack->fields.size(); ++index)
                    std::memcpy(destination + move.component.offset + move.pack->offsets[index],
                                elements[index], move.pack->fields[index]->size());
            } else if (borrowIndirect && !interface.parameters[move.argument]->swiftTuple)
                arguments[move.argument] = reinterpret_cast<void *>(pointer);
            else std::memcpy(destination + move.component.offset, reinterpret_cast<const void *>(pointer), move.extent);
        } else if (move.component.optionalSingleton) {
            unpackOptionalSingleton(destination + move.component.offset, source);
        } else {
            const auto available = move.extent;
            std::memcpy(destination + move.component.offset, source, std::min(move.component.size, available));
        }
    }
}

void packRegisters(const Layout &layout, TypeStorage &type, CallFrame &frame, const void *value) {
    std::memset(frame.integerResults, 0, sizeof(frame.integerResults));
    std::memset(frame.floatingResults, 0, sizeof(frame.floatingResults));
    size_t integers = 0, floating = 0;
    for (const auto &component : layout.components) {
        void *destination = component.floating ? static_cast<void *>(&frame.floatingResults[floating++])
            : static_cast<void *>(&frame.integerResults[integers++]);
        const auto available = type.size() - component.offset;
        std::memcpy(destination, static_cast<const uint8_t *>(value) + component.offset, std::min(component.size, available));
    }
}
void packResult(const ABISwiftCallInterface &interface, CallFrame &frame, void *value,
                void *const *outputs = nullptr, ABISwiftResultInitializer initializeResult = nullptr,
                void *context = nullptr) {
    auto initialize = [&](void *destination, void *source, size_t logicalOffset, size_t size) {
        if (!size) return;
        if (initializeResult) initializeResult(context, logicalOffset, size, destination, source);
        else std::memcpy(destination, source, size);
    };
    auto copyOutput = [&](TypeStorage &type, void *destination, void *source, size_t logicalOffset) {
        if (!type.swiftPack) { initialize(destination, source, logicalOffset, type.size()); return; }
        auto **elements = static_cast<void **>(destination);
        for (size_t index = 0; index < type.fields.size(); ++index)
            initialize(elements[index], static_cast<uint8_t *>(source) + type.offsets[index],
                       logicalOffset + type.offsets[index], type.fields[index]->size());
    };
    for (size_t index = 0; index < interface.indirectResults.size(); ++index) {
        void *destination = nullptr;
        if (outputs) destination = outputs[index];
        else {
            const auto &move = interface.moves[index];
            const void *source = move.bank == Bank::integer ? static_cast<const void *>(&frame.integers[move.destination])
                : reinterpret_cast<const uint8_t *>(frame.stack) + move.destination;
            std::memcpy(&destination, source, sizeof(destination));
        }
        const auto &field = interface.indirectResults[index];
        copyOutput(*field.type, destination, static_cast<uint8_t *>(value) + field.offset, field.offset);
    }
    if (interface.directResult->swiftPack) {
        const auto offset = interface.resultCopies.empty() ? 0 : interface.resultCopies[0].logical;
        copyOutput(*interface.directResult, reinterpret_cast<void *>(frame.indirectResult),
                   static_cast<uint8_t *>(value) + offset, offset);
        return;
    }
    if (interface.resultLayout.indirect) {
        auto *destination = reinterpret_cast<uint8_t *>(frame.indirectResult);
        if (interface.resultCopies.empty()) {
            initialize(destination, value, 0, interface.directResult->size());
        } else {
            // A tuple can have an ABI-only aggregate for its direct fields.
            // Move its complete logical fields; its padded carrier has no metadata.
            for (const auto &copy : interface.resultCopies) {
                auto *source = static_cast<uint8_t *>(value) + copy.logical;
                if (copy.optionalSingleton) packOptionalSingleton(destination + copy.direct, source);
                else initialize(destination + copy.direct, source, copy.logical, copy.size);
            }
        }
        return;
    }
    SwiftResultStorage storage(interface, value);
    if (storage.temporary) for (const auto &copy : interface.resultCopies) {
        auto destination = static_cast<uint8_t *>(storage.direct) + copy.direct;
        auto source = static_cast<const uint8_t *>(value) + copy.logical;
        if (copy.optionalSingleton) packOptionalSingleton(destination, source);
        else std::memcpy(destination, source, copy.size);
    }
    packRegisters(interface.resultLayout, *interface.directResult, frame, storage.direct);
}
void packError(const ABISwiftCallInterface &interface, CallFrame &frame, const void *value, void *indirect,
               ABISwiftResultInitializer initializeError = nullptr, void *context = nullptr) {
    // A throwing callback promises an initialized error of its declared type.
    if (!interface.errorResult) std::abort();
    if (!interface.typedError) {
        std::memcpy(&frame.error, value, sizeof(void *));
    } else {
        frame.error = 1;
        if (interface.indirectError) {
            if (initializeError) initializeError(context, 0, interface.errorResult->size(), indirect, const_cast<void *>(value));
            else std::memcpy(indirect, value, interface.errorResult->size());
        }
        else packRegisters(interface.errorLayout, *interface.errorResult, frame, value);
    }
}
}

struct ABISwiftAsyncClosureCallback {
    ABISwiftAsyncCallInterface interface;
    std::unique_ptr<abibridge::SwiftCallbackCode> code;
    ABISwiftAsyncClosureCallbackFunctions functions{};
    void *context = nullptr;
    ABIUnmanagedFunction fallback = nullptr;
    uint32_t contextSize = 0;
    ABISwiftClosureValue (*createHookBody)(void *, ABISwiftIncomingCall *) = nullptr;
    explicit ABISwiftAsyncClosureCallback(const ABISwiftAsyncCallInterface &interface) : interface(interface) {}
    ~ABISwiftAsyncClosureCallback() { if (functions.releaseContext) functions.releaseContext(context); }
};
struct SwiftAsyncCallbackInvocation {
    ABISwiftAsyncClosureCallback &callback;
    std::unique_ptr<ABISwiftIncomingCall> hook;
    SwiftAsyncHeader *caller = nullptr;
    std::vector<AlignedValue> storage;
    std::vector<void *> arguments;
    AlignedValue result, error;
    void *indirectResult = nullptr, *indirectError = nullptr;
    std::vector<void *> outputs;
    uint64_t nativeContext = 0;
    ABISwiftClosureValue body{};
    bool didThrow = false;
    SwiftAsyncTransfer transfer;
    explicit SwiftAsyncCallbackInvocation(ABISwiftAsyncClosureCallback &callback)
        : callback(callback),
          result(callback.interface.completion->result->size(), callback.interface.completion->result->native()->alignment),
          error(callback.interface.completion->errorResult ? callback.interface.completion->errorResult->size() : 0,
                callback.interface.completion->errorResult ? callback.interface.completion->errorResult->native()->alignment : 1) {}
};
struct alignas(16) SwiftAsyncCallbackContext {
    SwiftAsyncHeader header;
    SwiftAsyncCallbackInvocation *invocation;
    SwiftAsyncHeader *body;
    SwiftExecutorRef executor;
};
static_assert(sizeof(SwiftAsyncCallbackContext) == (sizeof(void *) == 8 ? 48 : 32));
extern "C" __attribute__((swiftasynccall))
void ABISwiftAsyncCallbackBodyResume(swift::AsyncContext * __attribute__((swift_async_context)));
extern "C" void ABISwiftAsyncCallbackFinish(void);

ABISwiftAsyncClosureCallback *ABICreateSwiftAsyncClosureCallback(ABISwiftAsyncCallInterface *interface,
    ABISwiftAsyncClosureCallbackFunctions functions, void *context, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!interface || !functions.createBody) {
        fail(error, ABIFailureInvalidRequest, "An async interface and compiler-managed body factory are required.");
        return nullptr;
    }
    auto callback = std::make_unique<ABISwiftAsyncClosureCallback>(*interface);
    callback->code = std::make_unique<abibridge::SwiftCallbackCode>(callback.get(), error, true, sizeof(SwiftAsyncCallbackContext));
    if (!callback->code->function()) return nullptr;
    callback->functions = functions;
    callback->context = context;
    return callback.release();
}
ABISwiftAsyncClosureCallback *ABICreateSwiftAsyncHookCallback(ABISwiftAsyncCallInterface *interface,
    ABIUnmanagedFunction fallback, uint32_t contextSize,
    ABISwiftClosureValue (*createBody)(void *, ABISwiftIncomingCall *),
    void *context, void (*releaseContext)(void *), ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!interface || !fallback || contextSize < sizeof(SwiftAsyncHeader) || !createBody) {
        fail(error, ABIFailureInvalidRequest, "An async interface, predecessor and body factory are required."); return nullptr;
    }
    auto callback = std::make_unique<ABISwiftAsyncClosureCallback>(*interface);
    // A virtual caller allocates the size advertised by this descriptor.
    // Raw pass-through reuses that context for the captured native entry.
    callback->code = std::make_unique<abibridge::SwiftCallbackCode>(callback.get(), error, false, contextSize);
    if (!callback->code->function()) return nullptr;
    callback->fallback = fallback;
    callback->contextSize = contextSize;
    callback->createHookBody = createBody;
    callback->context = context;
    callback->functions.releaseContext = releaseContext;
    return callback.release();
}
ABIUnmanagedFunction ABISwiftAsyncHookCallbackFunction(const ABISwiftAsyncClosureCallback *callback) {
    return callback->code->function();
}

const void *ABISwiftAsyncClosureCallbackDescriptor(const ABISwiftAsyncClosureCallback *callback) {
    return callback->code->asyncDescriptor();
}
void ABIReleaseSwiftAsyncClosureCallback(ABISwiftAsyncClosureCallback *callback) { delete callback; }
bool ABIIsSwiftAsyncClosureCallbackFunction(ABIUnmanagedFunction function) {
    return abibridge::SwiftCallbackCode::closureContext(function, true) != nullptr;
}
void *ABICopySwiftAsyncClosureCallbackCodeOwner(ABIUnmanagedFunction function, void *nativeContext) {
    auto *callback = static_cast<ABISwiftAsyncClosureCallback *>(abibridge::SwiftCallbackCode::closureContext(function, true));
    if (!callback || !callback->functions.copyCodeOwner) return nullptr;
    return callback->functions.copyCodeOwner(callback->functions.usesNativeContext ? nativeContext : callback->context);
}
void *ABICopySwiftAsyncClosureCallbackBodyOwner(ABIUnmanagedFunction function, void *nativeContext) {
    auto *callback = static_cast<ABISwiftAsyncClosureCallback *>(abibridge::SwiftCallbackCode::closureContext(function, true));
    if (!callback || !callback->functions.copyBodyOwner) return nullptr;
    return callback->functions.copyBodyOwner(callback->functions.usesNativeContext ? nativeContext : callback->context);
}

extern "C" SwiftAsyncTransfer *ABIPrepareSwiftAsyncCallback(
    ABISwiftAsyncClosureCallback *callback, CallFrame *incoming, SwiftAsyncCallbackContext *bridge) {
    auto *invocation = new SwiftAsyncCallbackInvocation(*callback);
    invocation->nativeContext = incoming->context;
    uintptr_t actor = 0, witness = 0;
    size_t incomingStackSize = callback->interface.entry->stackSize;
    if (callback->createHookBody) {
        invocation->hook = std::make_unique<ABISwiftIncomingCall>(callback->interface,
            callback->fallback, callback->contextSize, *incoming);
        invocation->body = callback->createHookBody(callback->context, invocation->hook.get());
        if (!invocation->body.function) {
            invocation->hook->untouchedFallback = true;
            delete invocation;
            // The prologue reserved an entire transfer record. Preserve every
            // incoming register and stack word for a raw generic mismatch.
            auto *transfer = reinterpret_cast<SwiftAsyncTransfer *>(incoming);
            std::memcpy(&transfer->function, &callback->fallback, sizeof(callback->fallback));
            transfer->asyncContext = reinterpret_cast<uintptr_t>(bridge);
            transfer->values.stackSize = 0;
#if __has_feature(ptrauth_calls)
            transfer->discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
            return transfer;
        }
        auto &call = *invocation->hook;
        incomingStackSize = call.asynchronous->entry->stackSize;
        actor = call.isolation[0]; witness = call.isolation[1];
        invocation->caller = reinterpret_cast<SwiftAsyncHeader *>(bridge);
        bridge = static_cast<SwiftAsyncCallbackContext *>(swift_task_alloc(sizeof(SwiftAsyncCallbackContext)));
    } else {
    // The native caller's async argument borrows end at completion, not at this
    // entry prologue. Preserve indirect addresses through the suspended body.
    unpackArguments(*callback->interface.entry, *incoming, invocation->storage, invocation->arguments, nullptr, true);
    size_t index = 0;
    auto pointer = [&]() {
        uintptr_t value;
        std::memcpy(&value, invocation->arguments[index++], sizeof(value));
        return value;
    };
    if (callback->interface.completion->resultLayout.indirect)
        invocation->indirectResult = reinterpret_cast<void *>(pointer());
    for (size_t output = 0; output < callback->interface.completion->indirectResults.size(); ++output)
        invocation->outputs.push_back(reinterpret_cast<void *>(pointer()));
    if (callback->interface.inheritsCallerIsolation) { actor = pointer(); witness = pointer(); }
    auto *arguments = invocation->arguments.empty() ? nullptr : invocation->arguments.data() + index;
    index += callback->interface.argumentCount;
    if (callback->interface.completion->indirectError)
        invocation->indirectError = reinterpret_cast<void *>(pointer());
    invocation->body = callback->functions.createBody(callback->functions.usesNativeContext
        ? reinterpret_cast<void *>(incoming->context) : callback->context, arguments, invocation->result.data(),
        callback->interface.completion->errorResult ? invocation->error.data() : nullptr, &invocation->didThrow);
    }
    bridge->invocation = invocation;
    bridge->executor = swift_task_getCurrentExecutor();

    // The body factory supplies a live compiler-generated stored Void closure,
    // whose empty result remains formally indirect in generic function storage.
    // check-swift-async-closure-codegen.py verifies this fixed internal contract.
    struct Descriptor { int32_t entry; uint32_t contextSize; };
    const auto *descriptor = static_cast<const Descriptor *>(
        ABIAuthenticateSwiftAsyncClosureDescriptor(invocation->body.function, callback->interface.inheritsCallerIsolation ? 51264 : 29199));
    const auto address = reinterpret_cast<uintptr_t>(descriptor) + intptr_t(descriptor->entry);
    auto function = ABIUnsafeFunctionAtAddress(reinterpret_cast<const void *>(address));
    bridge->body = static_cast<SwiftAsyncHeader *>(swift_task_alloc(descriptor->contextSize));
    bridge->body->parent = reinterpret_cast<swift::AsyncContext *>(bridge);
    bridge->body->resume = ABISwiftAsyncCallbackBodyResume;
    auto &transfer = invocation->transfer;
    std::memcpy(&transfer.function, &function, sizeof(function));
    transfer.asyncContext = reinterpret_cast<uintptr_t>(bridge->body);
#if __has_feature(ptrauth_calls)
    transfer.discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
    transfer.values.integers[0] = 0; // The indirect empty result is never accessed.
    transfer.values.integers[1] = actor;
    transfer.values.integers[2] = witness;
    transfer.values.context = reinterpret_cast<uintptr_t>(invocation->body.context);
    transfer.values.stackSize = incomingStackSize;
    return &transfer;
}

extern "C" SwiftAsyncTransfer *ABICompleteSwiftAsyncCallback(SwiftAsyncHeader *body) {
    auto *bridge = reinterpret_cast<SwiftAsyncCallbackContext *>(body->parent);
    auto *invocation = bridge->invocation;
    swift_task_dealloc(body);
    ABIReleaseSwiftClosureContext(invocation->body.context);
    auto &transfer = invocation->transfer;
    transfer.asyncContext = reinterpret_cast<uintptr_t>(bridge);
    auto *resume = ABISwiftAsyncCallbackFinish;
#if __has_feature(ptrauth_calls)
    resume = ptrauth_sign_unauthenticated(ptrauth_strip(resume, ptrauth_key_function_pointer), ptrauth_key_function_pointer, 0);
#endif
    transfer.values.integers[0] = 0;
    std::memcpy(&transfer.values.integers[0], &resume, sizeof(resume));
    transfer.values.integers[1] = bridge->executor.identity;
    transfer.values.integers[2] = bridge->executor.implementation;
    return &transfer;
}

extern "C" void ABIFinishSwiftAsyncCallback(SwiftAsyncCallbackContext *bridge, SwiftAsyncTransfer *transfer) {
    std::unique_ptr<SwiftAsyncCallbackInvocation> invocation(bridge->invocation);
    *transfer = {};
    if (invocation->hook) {
        auto &call = *invocation->hook;
        call.active = false;
        auto &result = call.assigned ? call.assigned : call.completed;
        // The Swift execution body guarantees a completed native outcome,
        // including unchanged fallback after an unrepresentable failure.
        if (!result) std::abort();
        transfer->values.indirectResult = reinterpret_cast<uintptr_t>(call.indirectResult);
        transfer->values.error = call.interface.errorResult ? 0 : invocation->nativeContext;
        if (result->isError) packError(call.interface, transfer->values, result->value.data(), call.indirectError,
            call.handler->functions.initializeError, call.handler->context);
        else packResult(call.interface, transfer->values, result->value.data(), call.outputs.data(),
            call.handler->functions.initializeResult, call.handler->context);
        result->initialized = false;
        auto resume = reinterpret_cast<ABIUnmanagedFunction>(invocation->caller->resume);
        std::memcpy(&transfer->function, &resume, sizeof(resume));
        transfer->asyncContext = reinterpret_cast<uintptr_t>(invocation->caller);
#if __has_feature(ptrauth_calls)
        transfer->discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
        swift_task_dealloc(bridge);
        return;
    }
    auto &completion = *invocation->callback.interface.completion;
    transfer->values.indirectResult = reinterpret_cast<uintptr_t>(invocation->indirectResult);
    transfer->values.error = completion.errorResult ? 0 : invocation->nativeContext;
    if (invocation->didThrow)
        packError(completion, transfer->values, invocation->error.data(), invocation->indirectError);
    else {
        auto &callback = invocation->callback;
        auto *context = callback.functions.usesNativeContext
            ? reinterpret_cast<void *>(invocation->nativeContext) : callback.context;
        packResult(completion, transfer->values, invocation->result.data(), invocation->outputs.data(),
                   callback.functions.initializeResult, context);
    }
    auto resume = reinterpret_cast<ABIUnmanagedFunction>(bridge->header.resume);
    std::memcpy(&transfer->function, &resume, sizeof(resume));
    transfer->asyncContext = reinterpret_cast<uintptr_t>(bridge);
#if __has_feature(ptrauth_calls)
    transfer->discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
}

size_t ABISwiftIncomingArgumentCount(const ABISwiftIncomingCall *call) { return call->arguments.size(); }
const void *ABISwiftIncomingContext(const ABISwiftIncomingCall *call) { return call->receiver; }
bool ABISwiftIncomingReadPointer(ABISwiftIncomingCall *call, const ABISwiftCallInterface *interface,
    size_t index, uintptr_t *value, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    if (!interface || !value || index >= interface->parameters.size()
        || interface->parameters[index]->size() != sizeof(void *)) {
        fail(error, ABIFailureInvalidRequest, "A pointer argument and its physical Swift interface are required."); return false;
    }
    for (const auto &move : interface->moves) {
        if (move.source != ArgumentSource::parameter || move.argument != index) continue;
        if (move.indirect || move.component.offset != 0 || move.component.size != sizeof(void *)) break;
        const void *source = move.bank == Bank::integer ? static_cast<const void *>(&call->frame.integers[move.destination])
            : move.bank == Bank::floating ? static_cast<const void *>(&call->frame.floating[move.destination])
            : reinterpret_cast<const uint8_t *>(call->frame.stack) + move.destination;
        std::memcpy(value, source, sizeof(void *));
        return true;
    }
    fail(error, ABIFailureInvalidRequest, "The selected Swift argument is not a directly passed pointer word.");
    return false;
}
bool ABISwiftAsyncIncomingReadPointer(ABISwiftIncomingCall *call, const ABISwiftAsyncCallInterface *interface,
    size_t index, uintptr_t *value, ABIResolutionFailure **error) {
    const size_t prefix = interface->completion->resultLayout.indirect + interface->completion->indirectResults.size()
        + (interface->inheritsCallerIsolation ? 2 : 0);
    return ABISwiftIncomingReadPointer(call, interface->entry.get(), prefix + index, value, error);
}
bool ABISwiftAsyncIncomingPrepare(ABISwiftIncomingCall *call, const ABISwiftAsyncCallInterface *interface,
    ABISwiftCallbackFunctions functions, void *context, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    if (!interface || call->prepared || !call->asynchronous) {
        fail(error, ABIFailureInvalidRequest, "An unprepared async hook and its bound interface are required."); return false;
    }
    auto handler = std::make_shared<SwiftHandler>();
    handler->functions = functions; handler->context = context;
    call->handler = std::move(handler);
    call->asynchronous = *interface; call->interface = *interface->completion;
    unpackArguments(*interface->entry, call->frame, call->storage, call->arguments, nullptr, true);
    size_t prefix = 0;
    auto pointer = [&]() { uintptr_t value; std::memcpy(&value, call->arguments[prefix++], sizeof(value)); return value; };
    if (call->interface.resultLayout.indirect) call->indirectResult = reinterpret_cast<void *>(pointer());
    for (size_t index = 0; index < call->interface.indirectResults.size(); ++index)
        call->outputs.push_back(reinterpret_cast<void *>(pointer()));
    if (interface->inheritsCallerIsolation) { call->isolation[0] = pointer(); call->isolation[1] = pointer(); }
    if (call->interface.indirectError) {
        uintptr_t value; std::memcpy(&value, call->arguments[prefix + interface->argumentCount], sizeof(value));
        call->indirectError = reinterpret_cast<void *>(value);
    }
    call->arguments.erase(call->arguments.begin(), call->arguments.begin() + prefix);
    call->arguments.resize(interface->argumentCount);
    call->prepared = true;
    return true;
}
ABISwiftAsyncInvocation *ABISwiftIncomingCreateAsyncProceed(ABISwiftIncomingCall *call,
    void *const *arguments, size_t count, const void *receiver, bool untouched, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return nullptr;
    auto &interface = *call->asynchronous;
    if (!untouched && count != interface.argumentCount) {
        fail(error, ABIFailureInvalidRequest, "Arguments must match the selected async hook interface."); return nullptr;
    }
    call->pendingResult = std::make_unique<SwiftOwnedResult>(*interface.completion->result, *call->handler);
    call->pendingError = interface.completion->errorResult
        ? std::make_unique<SwiftOwnedResult>(*interface.completion->errorResult, *call->handler, true) : nullptr;
    auto *invocation = ABICreateSwiftAsyncInvocation(&interface, call->fallback, call->contextSize,
        call->pendingResult->value.data(), untouched ? call->arguments.data() : arguments,
        untouched ? call->receiver : receiver, call->pendingError ? call->pendingError->value.data() : nullptr, error);
    if (invocation && untouched) call->untouchedFallback = true;
    return invocation;
}
void ABISwiftIncomingCompleteAsyncProceed(ABISwiftIncomingCall *call, ABISwiftAsyncInvocation *invocation) {
    auto result = invocation->didThrow ? std::move(call->pendingError) : std::move(call->pendingResult);
    result->initialized = true;
    auto previous = std::move(call->completed);
    call->completed = std::move(result);
}

bool ABISwiftIncomingPrepare(ABISwiftIncomingCall *call, const ABISwiftCallInterface *interface,
    ABISwiftCallbackFunctions functions, void *context, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    if (!interface || call->prepared) {
        fail(error, ABIFailureInvalidRequest, "An unprepared Swift invocation and its bound interface are required."); return false;
    }
    auto handler = std::make_shared<SwiftHandler>();
    handler->functions = functions;
    handler->context = context;
    call->interface = *interface;
    call->handler = std::move(handler);
    unpackArguments(call->interface, call->frame, call->storage, call->arguments, &call->indirectError, true);
    call->prepared = true;
    return true;
}
void *ABISwiftIncomingArgumentAddress(ABISwiftIncomingCall *call, size_t index) {
    return checkIncoming(call, nullptr) && index < call->arguments.size() ? call->arguments[index] : nullptr;
}
bool ABISwiftIncomingReadArgument(ABISwiftIncomingCall *call, size_t index,
    void *output, size_t size, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    const auto *interface = &call->interface;
    size_t parameter = index;
    if (call->asynchronous) {
        const auto &async = *call->asynchronous;
        interface = async.entry.get();
        parameter += async.completion->resultLayout.indirect + async.completion->indirectResults.size()
            + (async.inheritsCallerIsolation ? 2 : 0);
    }
    if (index >= call->arguments.size() || parameter >= interface->parameters.size()
        || size != interface->parameters[parameter]->size() || (size && !output)) {
        fail(error, ABIFailureInvalidRequest, "The destination must match the selected Swift argument storage."); return false;
    }
    if (size) std::memcpy(output, call->arguments[index], size);
    return true;
}
bool ABISwiftIncomingProceed(ABISwiftIncomingCall *call, void *const *arguments, size_t count,
    const void *receiver, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    auto &interface = call->interface;
    if (count != interface.parameters.size()) {
        fail(error, ABIFailureInvalidRequest, "The argument count must match the Swift call interface."); return false;
    }
    auto result = std::make_unique<SwiftOwnedResult>(*interface.result, *call->handler);
    auto nativeError = interface.errorResult
        ? std::make_unique<SwiftOwnedResult>(*interface.errorResult, *call->handler, true) : nullptr;
    bool didThrow = false;
    if (!invokeSwiftCallInterface(&interface, call->fallback, result->value.data(), arguments, receiver,
        nativeError ? nativeError->value.data() : nullptr, &didThrow, error)) return false;
    if (didThrow) result = std::move(nativeError);
    result->initialized = true;
    // Publish the new state before releasing an old value. Its destructor may
    // reenter this invocation; detached storage stays alive during destruction.
    auto previous = std::move(call->completed);
    call->completed = std::move(result);
    return true;
}
bool ABISwiftIncomingCopyResult(ABISwiftIncomingCall *call, void *output, size_t size, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    if (!call->completed || call->completed->isError || size != call->interface.result->size() || (size && !output)) {
        fail(error, ABIFailureInvalidRequest, "A completed original call and matching result storage are required."); return false;
    }
    if (size) std::memcpy(output, call->completed->value.data(), size);
    return true;
}
bool ABISwiftIncomingDidThrow(const ABISwiftIncomingCall *call) {
    return call && call->completed && call->completed->isError;
}
void *ABISwiftIncomingResultAddress(ABISwiftIncomingCall *call) {
    return checkIncoming(call, nullptr) && call->completed ? call->completed->value.data() : nullptr;
}
bool ABISwiftIncomingCopyError(ABISwiftIncomingCall *call, void *output, size_t size, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    if (!call->completed || !call->completed->isError || !call->interface.errorResult
        || size != call->interface.errorResult->size() || (size && !output)) {
        fail(error, ABIFailureInvalidRequest, "A completed thrown error and matching error storage are required."); return false;
    }
    if (size) std::memcpy(output, call->completed->value.data(), size);
    return true;
}
bool ABISwiftIncomingSetResult(ABISwiftIncomingCall *call, const void *value, size_t size, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    if (size != call->interface.result->size() || (size && !value)) {
        fail(error, ABIFailureInvalidRequest, "The owned result must match the Swift result storage."); return false;
    }
    auto result = std::make_unique<SwiftOwnedResult>(*call->interface.result, *call->handler);
    if (size) {
        if (auto initialize = call->handler->functions.initializeResult)
            initialize(call->handler->context, 0, size, result->value.data(), const_cast<void *>(value));
        else std::memcpy(result->value.data(), value, size);
    }
    result->initialized = true;
    auto previous = std::move(call->assigned);
    call->assigned = std::move(result);
    return true;
}
bool ABISwiftIncomingSetError(ABISwiftIncomingCall *call, const void *value, size_t size, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    const auto &type = call->interface.errorResult;
    if (!type || size != type->size() || (size && !value)) {
        fail(error, ABIFailureInvalidRequest, "The owned error must match the native error storage."); return false;
    }
    auto result = std::make_unique<SwiftOwnedResult>(*type, *call->handler, true);
    if (size) {
        if (auto initialize = call->handler->functions.initializeError)
            initialize(call->handler->context, 0, size, result->value.data(), const_cast<void *>(value));
        else std::memcpy(result->value.data(), value, size);
    }
    result->initialized = true;
    auto previous = std::move(call->assigned);
    call->assigned = std::move(result);
    return true;
}

namespace {
void invokeUntouchedSwiftFallback(ABISwiftCallback &callback, CallFrame &frame) {
    frame.stackSize = callback.interface.stackSize;
    const auto preservedError = frame.error;
    uint64_t discriminator = 0;
#if __has_feature(ptrauth_calls)
    discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
    ABIInvokeSwiftAssembly(&frame, callback.fallback, discriminator);
    // Outside a throwing entry this is an ordinary callee-saved register.
    if (!callback.interface.errorResult) frame.error = preservedError;
}
}

extern "C" __attribute__((visibility("hidden"))) void ABIDispatchSwiftCallback(ABISwiftCallback *callback, CallFrame *frame) {
    if (callback->closure) {
        std::vector<AlignedValue> storage;
        std::vector<void *> arguments;
        auto &interface = callback->interface;
        void *indirectError = nullptr;
        // Synchronous closure arguments are guaranteed for this entire callback.
        // Preserve their original address, including address-sensitive resilient values.
        unpackArguments(interface, *frame, storage, arguments, &indirectError, true);
        AlignedValue result(interface.result->size(), interface.result->native()->alignment);
        if (interface.errorResult) frame->error = 0;
        auto *context = callback->closure->usesNativeContext
            ? reinterpret_cast<void *>(frame->context) : callback->closure->context;
        if (callback->closure->invokeThrowing) {
            AlignedValue error(interface.errorResult ? interface.errorResult->size() : 0,
                               interface.errorResult ? interface.errorResult->native()->alignment : 1);
            const bool threw = callback->closure->invokeThrowing(context, arguments.data(),
                result.data(), interface.errorResult ? error.data() : nullptr);
            if (threw) {
                packError(interface, *frame, error.data(), indirectError);
                return;
            }
        } else {
            callback->closure->invoke(context, arguments.data(), result.data());
        }
        packResult(interface, *frame, result.data(), nullptr, callback->closure->initializeResult, context);
        return; // The native caller owns the selected result or error.
    }
    std::shared_ptr<SwiftHandler> handler;
    { std::lock_guard lock(callback->mutex); handler = callback->handler; }
    const auto receiver = reinterpret_cast<const void *>(frame->context);
    if (!handler) {
        invokeUntouchedSwiftFallback(*callback, *frame);
        return;
    }
    ABISwiftIncomingCall call(*callback, handler, *frame);
    if (!handler->functions.preparesArguments) {
        unpackArguments(call.interface, *frame, call.storage, call.arguments, &call.indirectError, true);
        call.prepared = true;
    }
    handler->functions.invoke(handler->context, &call);
    call.active = false;
    if (!call.assigned && !call.completed) {
        call.untouchedFallback = true;
        invokeUntouchedSwiftFallback(*callback, *frame);
        return;
    }
    auto &result = call.assigned ? call.assigned : call.completed;
    if (call.interface.errorResult) frame->error = 0;
    if (result->isError) packError(call.interface, *frame, result->value.data(), call.indirectError,
        call.handler->functions.initializeError, call.handler->context);
    else packResult(call.interface, *frame, result->value.data(), nullptr,
        call.handler->functions.initializeResult, call.handler->context);
    result->initialized = false; // The native caller now owns the result.
}

namespace {
bool swiftStorageTypesEqual(const std::shared_ptr<TypeStorage> &first, const std::shared_ptr<TypeStorage> &second) {
    if (first->native()->type != second->native()->type || first->size() != second->size()
        || first->native()->alignment != second->native()->alignment || first->fields.size() != second->fields.size()
        || first->swiftIndirect != second->swiftIndirect || first->swiftTuple != second->swiftTuple || first->swiftPack != second->swiftPack
        || first->swiftOptionalSingleton != second->swiftOptionalSingleton
        || first->offsets != second->offsets) return false;
    for (size_t index = 0; index < first->fields.size(); ++index)
        if (!swiftStorageTypesEqual(first->fields[index], second->fields[index])) return false;
    return true;
}
}
bool ABIValueTypesEqual(const ABIValueType *first, const ABIValueType *second) {
    return first && second && swiftStorageTypesEqual(first->storage, second->storage);
}
