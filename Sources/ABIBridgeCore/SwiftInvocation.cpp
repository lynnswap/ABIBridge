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
};
static_assert(offsetof(CallFrame, integerResults) == 128);
static_assert(offsetof(CallFrame, floatingResults) == 160);
static_assert(offsetof(CallFrame, indirectResult) == 192);
static_assert(offsetof(CallFrame, context) == 200);
static_assert(offsetof(CallFrame, stack) == 208);
static_assert(offsetof(CallFrame, stackSize) == 216);

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
    if (!components || !alignment ||
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

struct ABISwiftCallInterface {
    std::shared_ptr<TypeStorage> result;
    std::vector<std::shared_ptr<TypeStorage>> parameters;
    Layout resultLayout;
    std::vector<ArgumentMove> moves;
    size_t stackSize = 0;
};

ABISwiftCallInterface *ABICreateSwiftCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, ABIResolutionFailure **error)
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
    size_t integers = 0, floating = 0, stack = 0;
#if defined(__x86_64__)
    constexpr size_t integerLimit = 6;
#else
    constexpr size_t integerLimit = 8;
#endif
    for (size_t index = 0; index < count; ++index) {
        if (!parameters[index]) {
            fail(error, ABIFailureInvalidRequest, "Each Swift parameter requires a storage description.");
            return nullptr;
        }
        interface->parameters.push_back(parameters[index]->storage);
        auto layout = lower(*parameters[index]->storage);
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
    interface->stackSize = aligned(stack, 16);
    return interface.release();
#endif
}

void ABIReleaseSwiftCallInterface(ABISwiftCallInterface *interface) { delete interface; }
bool ABISwiftValueIsIndirect(const ABIValueType *type) { return lower(*type->storage).indirect; }

bool ABIUnsafeInvokeSwiftCallInterface(
    ABISwiftCallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, const void *context,
    ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (!interface || !function || (interface->result->size() && !result) ||
        (!interface->parameters.empty() && !arguments)) {
        fail(error, ABIFailureInvalidRequest, "A Swift call interface, function and value storage are required.");
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
    for (const auto &move : interface->moves) {
        const auto source = static_cast<const uint8_t *>(arguments[move.argument]) + move.component.offset;
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
            const auto available = interface->parameters[move.argument]->size() - move.component.offset;
            std::memcpy(destination, source, std::min(move.component.size, available));
        }
    }
    uint64_t discriminator = 0;
#if __has_feature(ptrauth_calls)
    discriminator = ptrauth_function_pointer_type_discriminator(void(void));
#endif
    ABIInvokeSwiftAssembly(&frame, function, discriminator);
    if (!interface->resultLayout.indirect) {
        size_t integers = 0, floating = 0;
        for (const auto &component : interface->resultLayout.components) {
            const auto source = component.floating ? &frame.floatingResults[floating++] : &frame.integerResults[integers++];
            // A coalesced register may include trailing padding beyond the
            // value's allocation (for example, three bytes passed as i32).
            const auto available = interface->result->size() - component.offset;
            std::memcpy(static_cast<uint8_t *>(result) + component.offset, source, std::min(component.size, available));
        }
    }
    return true;
}

namespace {
struct SwiftHandler {
    ABISwiftCallbackFunctions functions{};
    void *context = nullptr;
    ~SwiftHandler() { if (functions.releaseContext) functions.releaseContext(context); }
};
struct SwiftClosureHandler {
    ABISwiftClosureCallbackFunctions functions{};
    void *context = nullptr;
    ~SwiftClosureHandler() { if (functions.releaseContext) functions.releaseContext(context); }
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

ABISwiftClosureCallback *ABICreateSwiftClosureCallback(ABISwiftCallInterface *interface,
    ABISwiftClosureCallbackFunctions functions, void *context, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!interface || !functions.invoke) {
        fail(error, ABIFailureInvalidRequest, "A concrete Swift call interface and closure callback are required.");
        return nullptr;
    }
    auto callback = std::make_unique<ABISwiftClosureCallback>(*interface);
    auto &entry = callback->entry;
    entry.code = std::make_unique<abibridge::SwiftCallbackCode>(&entry, error, true);
    if (!entry.code->function()) return nullptr;
    entry.closure = std::make_unique<SwiftClosureHandler>();
    entry.closure->functions = functions;
    entry.closure->context = context;
    return callback.release();
}
ABIUnmanagedFunction ABISwiftClosureCallbackFunction(const ABISwiftClosureCallback *callback) {
    return callback ? callback->entry.code->function() : nullptr;
}
void ABIReleaseSwiftClosureCallback(ABISwiftClosureCallback *callback) { delete callback; }
bool ABIIsSwiftClosureCallbackFunction(ABIUnmanagedFunction function) {
    return abibridge::SwiftCallbackCode::isClosureFunction(function);
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
                     std::vector<AlignedValue> &storage, std::vector<void *> &arguments) {
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

void packResult(const ABISwiftCallInterface &interface, CallFrame &frame, const void *value) {
    std::memset(frame.integerResults, 0, sizeof(frame.integerResults));
    std::memset(frame.floatingResults, 0, sizeof(frame.floatingResults));
    if (interface.resultLayout.indirect) {
        std::memcpy(reinterpret_cast<void *>(frame.indirectResult), value, interface.result->size());
        return;
    }
    size_t integers = 0, floating = 0;
    for (const auto &component : interface.resultLayout.components) {
        void *destination = component.floating ? static_cast<void *>(&frame.floatingResults[floating++])
            : static_cast<void *>(&frame.integerResults[integers++]);
        const auto available = interface.result->size() - component.offset;
        std::memcpy(destination, static_cast<const uint8_t *>(value) + component.offset, std::min(component.size, available));
    }
}
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
        unpackArguments(callback->interface, *frame, storage, arguments);
        AlignedValue result(callback->interface.result->size(), callback->interface.result->native()->alignment);
        callback->closure->functions.invoke(callback->closure->context, arguments.data(), result.data());
        packResult(callback->interface, *frame, result.data());
        return; // The native caller owns the initialized result.
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
