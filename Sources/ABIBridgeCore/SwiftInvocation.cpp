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
};
struct Layout {
    std::vector<Component> components;
    bool indirect = false;
};
enum class Bank { integer, floating, stack };
struct ArgumentMove {
    size_t argument;
    Component component;
    Bank bank;
    size_t destination;
    bool indirect;
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

struct ABISwiftCallInterface {
    std::shared_ptr<TypeStorage> result;
    std::vector<std::shared_ptr<TypeStorage>> parameters;
    Layout resultLayout;
    std::shared_ptr<TypeStorage> errorResult;
    Layout errorLayout;
    bool typedError = false;
    bool indirectError = false;
    std::vector<ArgumentMove> moves;
    size_t stackSize = 0;
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
    interface->resultLayout = lower(*result->storage);
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
        interface->indirectError = typedError && (interface->resultLayout.indirect ||
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
    for (size_t index = 0; index < count + size_t(interface->indirectError); ++index) {
        Layout layout;
        if (index == count) {
            layout.components = {{0, sizeof(void *), false}};
        } else {
            if (!parameters[index]) {
                fail(error, ABIFailureInvalidRequest, "Each Swift parameter requires a storage description.");
                return nullptr;
            }
            interface->parameters.push_back(parameters[index]->storage);
            layout = lower(*parameters[index]->storage);
        }
        if (layout.indirect) layout.components = {{0, sizeof(void *), false}};
        for (const auto &component : layout.components) {
            ArgumentMove move{index, component, Bank::stack, 0, layout.indirect};
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
        }
    }
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
    ABISwiftCallInterface *interface, void *const *arguments, void *errorResult,
    CallFrame &frame, std::vector<uint8_t> &stack) {
    uintptr_t errorAddress = reinterpret_cast<uintptr_t>(errorResult);
    for (const auto &move : interface->moves) {
        const bool errorArgument = move.argument == interface->parameters.size();
        const auto base = errorArgument ? reinterpret_cast<const uint8_t *>(&errorAddress)
            : static_cast<const uint8_t *>(arguments[move.argument]);
        const auto source = base + move.component.offset;
        const auto sourceSize = errorArgument ? sizeof(errorAddress) : interface->parameters[move.argument]->size();
        void *destination;
        switch (move.bank) {
            case Bank::integer: destination = &frame.integers[move.destination]; break;
            case Bank::floating: destination = &frame.floating[move.destination]; break;
            case Bank::stack: destination = stack.data() + move.destination; break;
        }
        if (move.indirect) {
            const uintptr_t address = reinterpret_cast<uintptr_t>(source);
            std::memcpy(destination, &address, sizeof(address));
        } else {
            const auto available = sourceSize - move.component.offset;
            std::memcpy(destination, source, std::min(move.component.size, available));
        }
    }
}

static bool copySwiftCompletion(
    ABISwiftCallInterface *interface, const CallFrame &frame, void *result, void *errorResult) {
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
        copyRegisters(interface->resultLayout, *interface->result, result);
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
    if (interface->resultLayout.indirect)
        frame.indirectResult = reinterpret_cast<uintptr_t>(result);
    marshalSwiftArguments(interface, arguments, errorResult, frame, stack);
    uint64_t discriminator = 0;
#if __has_feature(ptrauth_calls)
    discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
    ABIInvokeSwiftAssembly(&frame, function, discriminator);
    const bool threw = copySwiftCompletion(interface, frame, result, errorResult);
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
    if (interface->completion->resultLayout.indirect) inputs.push_back(&invocation->result);
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
    marshalSwiftArguments(invocation->entry.get(), invocation->arguments.data(), nullptr,
                          invocation->transfer.values, invocation->stack);
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
                                               invocation->result, invocation->errorResult);
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
    void (*invoke)(void *, void *const *, void *) = nullptr;
    bool (*invokeThrowing)(void *, void *const *, void *, void *) = nullptr;
    void *(*copyCodeOwner)(void *) = nullptr;
    void (*releaseContext)(void *) = nullptr;
    void *context = nullptr;
    ~SwiftClosureHandler() { if (releaseContext) releaseContext(context); }
};
struct SwiftFallbackOwner {
    void *context = nullptr;
    void (*release)(void *) = nullptr;
    ~SwiftFallbackOwner() { if (release) release(context); }
};
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
struct SwiftOwnedResult {
    AlignedValue value;
    SwiftHandler &handler;
    bool initialized = false;
    SwiftOwnedResult(TypeStorage &type, SwiftHandler &handler)
        : value(type.size(), type.native()->alignment), handler(handler) {}
    ~SwiftOwnedResult() { clear(); }
    void clear() {
        const bool owned = initialized;
        initialized = false;
        if (owned && handler.functions.destroyResult)
            handler.functions.destroyResult(handler.context, value.data());
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
void *ABICopySwiftClosureCallbackCodeOwner(ABIUnmanagedFunction function) {
    auto *callback = static_cast<ABISwiftCallback *>(abibridge::SwiftCallbackCode::closureContext(function));
    if (!callback || !callback->closure->copyCodeOwner) return nullptr;
    return callback->closure->copyCodeOwner(callback->closure->context);
}

struct ABISwiftIncomingCall {
    ABISwiftCallback &callback;
    std::shared_ptr<SwiftHandler> handler;
    std::vector<AlignedValue> storage;
    std::vector<void *> arguments;
    const void *receiver;
    pthread_t thread = pthread_self();
    std::unique_ptr<SwiftOwnedResult> completed;
    std::unique_ptr<SwiftOwnedResult> assigned;
    bool active = true;
    bool untouchedFallback = false;

    ABISwiftIncomingCall(ABISwiftCallback &callback, std::shared_ptr<SwiftHandler> handler,
                        const void *receiver)
        : callback(callback), handler(std::move(handler)), receiver(receiver) {}
    ~ABISwiftIncomingCall() {
        if (!untouchedFallback && handler->functions.destroyConsumedArguments)
            handler->functions.destroyConsumedArguments(handler->context, receiver, arguments.data(), arguments.size());
    }
};

ABISwiftCallback *ABICreateSwiftCallback(ABISwiftCallInterface *interface,
    ABIUnmanagedFunction fallback, ABISwiftCallbackFunctions functions, void *context,
    void *fallbackOwner, void (*releaseFallbackOwner)(void *), ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (interface && interface->errorResult) {
        fail(error, ABIFailureUnsupportedDeclaration, "Throwing Swift callbacks require an error-result handler.");
        return nullptr;
    }
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
    if (!pthread_equal(call->thread, pthread_self())) {
        fail(error, ABIFailureWrongThread, "A Swift callback invocation stays on its entering thread."); return false;
    }
    if (!call->active) { fail(error, ABIFailureInvalidRequest, "The Swift callback invocation has expired."); return false; }
    return true;
}

void unpackArguments(const ABISwiftCallInterface &interface, CallFrame &frame,
                     std::vector<AlignedValue> &storage, std::vector<void *> &arguments, void **errorResult = nullptr) {
    storage.reserve(interface.parameters.size());
    arguments.reserve(interface.parameters.size());
    for (const auto &type : interface.parameters) {
        storage.emplace_back(type->size(), type->native()->alignment);
        arguments.push_back(storage.back().data());
    }
    for (const auto &move : interface.moves) {
        const void *source = nullptr;
        switch (move.bank) {
            case Bank::integer: source = &frame.integers[move.destination]; break;
            case Bank::floating: source = &frame.floating[move.destination]; break;
            case Bank::stack: source = reinterpret_cast<const uint8_t *>(frame.stack) + move.destination; break;
        }
        if (move.argument == interface.parameters.size()) {
            // The trailing typed-error pointer is hidden from the Swift body.
            if (errorResult) std::memcpy(errorResult, source, sizeof(void *));
            continue;
        }
        auto *destination = static_cast<uint8_t *>(arguments[move.argument]);
        if (move.indirect) {
            uintptr_t pointer = 0;
            std::memcpy(&pointer, source, sizeof(pointer));
            std::memcpy(destination, reinterpret_cast<const void *>(pointer), interface.parameters[move.argument]->size());
        } else {
            const auto available = interface.parameters[move.argument]->size() - move.component.offset;
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
void packResult(const ABISwiftCallInterface &interface, CallFrame &frame, const void *value) {
    if (interface.resultLayout.indirect) {
        std::memcpy(reinterpret_cast<void *>(frame.indirectResult), value, interface.result->size());
        return;
    }
    packRegisters(interface.resultLayout, *interface.result, frame, value);
}
void packError(const ABISwiftCallInterface &interface, CallFrame &frame, const void *value, void *indirect) {
    // A throwing callback promises an initialized error of its declared type.
    if (!interface.errorResult) std::abort();
    if (!interface.typedError) {
        std::memcpy(&frame.error, value, sizeof(void *));
    } else {
        frame.error = 1;
        if (interface.indirectError) std::memcpy(indirect, value, interface.errorResult->size());
        else packRegisters(interface.errorLayout, *interface.errorResult, frame, value);
    }
}
}

struct ABISwiftAsyncClosureCallback {
    ABISwiftAsyncCallInterface interface;
    std::unique_ptr<abibridge::SwiftCallbackCode> code;
    ABISwiftAsyncClosureCallbackFunctions functions{};
    void *context = nullptr;
    explicit ABISwiftAsyncClosureCallback(const ABISwiftAsyncCallInterface &interface) : interface(interface) {}
    ~ABISwiftAsyncClosureCallback() { if (functions.releaseContext) functions.releaseContext(context); }
};
struct SwiftAsyncCallbackInvocation {
    ABISwiftAsyncClosureCallback &callback;
    std::vector<AlignedValue> storage;
    std::vector<void *> arguments;
    AlignedValue result, error;
    void *indirectResult = nullptr, *indirectError = nullptr;
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
const void *ABISwiftAsyncClosureCallbackDescriptor(const ABISwiftAsyncClosureCallback *callback) {
    return callback->code->asyncDescriptor();
}
void ABIReleaseSwiftAsyncClosureCallback(ABISwiftAsyncClosureCallback *callback) { delete callback; }
bool ABIIsSwiftAsyncClosureCallbackFunction(ABIUnmanagedFunction function) {
    return abibridge::SwiftCallbackCode::closureContext(function, true) != nullptr;
}
void *ABICopySwiftAsyncClosureCallbackCodeOwner(ABIUnmanagedFunction function) {
    auto *callback = static_cast<ABISwiftAsyncClosureCallback *>(abibridge::SwiftCallbackCode::closureContext(function, true));
    if (!callback || !callback->functions.copyCodeOwner) return nullptr;
    return callback->functions.copyCodeOwner(callback->context);
}

extern "C" SwiftAsyncTransfer *ABIPrepareSwiftAsyncCallback(
    ABISwiftAsyncClosureCallback *callback, CallFrame *incoming, SwiftAsyncCallbackContext *bridge) {
    auto *invocation = new SwiftAsyncCallbackInvocation(*callback);
    bridge->invocation = invocation;
    bridge->executor = swift_task_getCurrentExecutor();
    invocation->nativeContext = incoming->context;
    unpackArguments(*callback->interface.entry, *incoming, invocation->storage, invocation->arguments);
    size_t index = 0;
    auto pointer = [&]() {
        uintptr_t value;
        std::memcpy(&value, invocation->arguments[index++], sizeof(value));
        return value;
    };
    if (callback->interface.completion->resultLayout.indirect)
        invocation->indirectResult = reinterpret_cast<void *>(pointer());
    uintptr_t actor = 0, witness = 0;
    if (callback->interface.inheritsCallerIsolation) { actor = pointer(); witness = pointer(); }
    auto *arguments = invocation->arguments.empty() ? nullptr : invocation->arguments.data() + index;
    index += callback->interface.argumentCount;
    if (callback->interface.completion->indirectError)
        invocation->indirectError = reinterpret_cast<void *>(pointer());
    invocation->body = callback->functions.createBody(callback->context, arguments, invocation->result.data(),
        callback->interface.completion->errorResult ? invocation->error.data() : nullptr, &invocation->didThrow);

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
    transfer.values.stackSize = callback->interface.entry->stackSize;
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
    auto &completion = *invocation->callback.interface.completion;
    transfer->values.indirectResult = reinterpret_cast<uintptr_t>(invocation->indirectResult);
    transfer->values.error = completion.errorResult ? 0 : invocation->nativeContext;
    if (invocation->didThrow)
        packError(completion, transfer->values, invocation->error.data(), invocation->indirectError);
    else packResult(completion, transfer->values, invocation->result.data());
    auto resume = reinterpret_cast<ABIUnmanagedFunction>(bridge->header.resume);
    std::memcpy(&transfer->function, &resume, sizeof(resume));
    transfer->asyncContext = reinterpret_cast<uintptr_t>(bridge);
#if __has_feature(ptrauth_calls)
    transfer->discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
}

size_t ABISwiftIncomingArgumentCount(const ABISwiftIncomingCall *call) { return call->arguments.size(); }
const void *ABISwiftIncomingContext(const ABISwiftIncomingCall *call) { return call->receiver; }
bool ABISwiftIncomingReadArgument(ABISwiftIncomingCall *call, size_t index,
    void *output, size_t size, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    if (index >= call->arguments.size() || size != call->callback.interface.parameters[index]->size() || (size && !output)) {
        fail(error, ABIFailureInvalidRequest, "The destination must match the selected Swift argument storage."); return false;
    }
    if (size) std::memcpy(output, call->arguments[index], size);
    return true;
}
bool ABISwiftIncomingProceed(ABISwiftIncomingCall *call, void *const *arguments, size_t count,
    const void *receiver, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    auto &interface = call->callback.interface;
    if (count != interface.parameters.size()) {
        fail(error, ABIFailureInvalidRequest, "The argument count must match the Swift call interface."); return false;
    }
    auto result = std::make_unique<SwiftOwnedResult>(*interface.result, *call->handler);
    if (!ABIUnsafeInvokeSwiftCallInterface(&interface, call->callback.fallback, result->value.data(), arguments, receiver, error)) return false;
    result->initialized = true;
    // Publish the new state before releasing an old value. Its destructor may
    // reenter this invocation; detached storage stays alive during destruction.
    auto previous = std::move(call->completed);
    call->completed = std::move(result);
    return true;
}
bool ABISwiftIncomingCopyResult(ABISwiftIncomingCall *call, void *output, size_t size, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    if (!call->completed || size != call->callback.interface.result->size() || (size && !output)) {
        fail(error, ABIFailureInvalidRequest, "A completed original call and matching result storage are required."); return false;
    }
    if (size) std::memcpy(output, call->completed->value.data(), size);
    return true;
}
bool ABISwiftIncomingSetResult(ABISwiftIncomingCall *call, const void *value, size_t size, ABIResolutionFailure **error) {
    if (!checkIncoming(call, error)) return false;
    if (size != call->callback.interface.result->size() || (size && !value)) {
        fail(error, ABIFailureInvalidRequest, "The owned result must match the Swift result storage."); return false;
    }
    auto result = std::make_unique<SwiftOwnedResult>(*call->callback.interface.result, *call->handler);
    if (size) std::memcpy(result->value.data(), value, size);
    result->initialized = true;
    auto previous = std::move(call->assigned);
    call->assigned = std::move(result);
    return true;
}

extern "C" __attribute__((visibility("hidden"))) void ABIDispatchSwiftCallback(ABISwiftCallback *callback, CallFrame *frame) {
    if (callback->closure) {
        std::vector<AlignedValue> storage;
        std::vector<void *> arguments;
        auto &interface = callback->interface;
        void *indirectError = nullptr;
        unpackArguments(interface, *frame, storage, arguments, &indirectError);
        AlignedValue result(interface.result->size(), interface.result->native()->alignment);
        if (interface.errorResult) frame->error = 0;
        if (callback->closure->invokeThrowing) {
            AlignedValue error(interface.errorResult ? interface.errorResult->size() : 0,
                               interface.errorResult ? interface.errorResult->native()->alignment : 1);
            const bool threw = callback->closure->invokeThrowing(callback->closure->context, arguments.data(),
                result.data(), interface.errorResult ? error.data() : nullptr);
            if (threw) {
                packError(interface, *frame, error.data(), indirectError);
                return;
            }
        } else {
            callback->closure->invoke(callback->closure->context, arguments.data(), result.data());
        }
        packResult(interface, *frame, result.data());
        return; // The native caller owns the selected result or error.
    }
    std::shared_ptr<SwiftHandler> handler;
    { std::lock_guard lock(callback->mutex); handler = callback->handler; }
    const auto receiver = reinterpret_cast<const void *>(frame->context);
    if (!handler) {
        std::vector<AlignedValue> storage;
        std::vector<void *> arguments;
        unpackArguments(callback->interface, *frame, storage, arguments);
        AlignedValue result(callback->interface.result->size(), callback->interface.result->native()->alignment);
        // The interface and original buffers were established before publishing
        // this entry; failure here would violate an internal invocation contract.
        if (!ABIUnsafeInvokeSwiftCallInterface(&callback->interface, callback->fallback, result.data(), arguments.data(), receiver, nullptr)) std::abort();
        packResult(callback->interface, *frame, result.data());
        return;
    }
    ABISwiftIncomingCall call(*callback, std::move(handler), receiver);
    unpackArguments(callback->interface, *frame, call.storage, call.arguments);
    call.handler->functions.invoke(call.handler->context, &call);
    call.active = false;
    if (!call.assigned && !call.completed) {
        call.completed = std::make_unique<SwiftOwnedResult>(*callback->interface.result, *call.handler);
        if (!ABIUnsafeInvokeSwiftCallInterface(&callback->interface, callback->fallback,
            call.completed->value.data(), call.arguments.data(), receiver, nullptr)) std::abort();
        call.completed->initialized = true;
        call.untouchedFallback = true;
    }
    auto &result = call.assigned ? call.assigned : call.completed;
    packResult(callback->interface, *frame, result->value.data());
    result->initialized = false; // The native caller now owns the result.
}

namespace {
bool swiftStorageTypesEqual(const std::shared_ptr<TypeStorage> &first, const std::shared_ptr<TypeStorage> &second) {
    if (first->native()->type != second->native()->type || first->size() != second->size()
        || first->native()->alignment != second->native()->alignment || first->fields.size() != second->fields.size()) return false;
    for (size_t index = 0; index < first->fields.size(); ++index)
        if (!swiftStorageTypesEqual(first->fields[index], second->fields[index])) return false;
    return true;
}
}
bool ABIValueTypesEqual(const ABIValueType *first, const ABIValueType *second) {
    return first && second && swiftStorageTypesEqual(first->storage, second->storage);
}
