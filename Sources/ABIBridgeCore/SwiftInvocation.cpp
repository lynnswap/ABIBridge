#include <ABIBridge/SwiftInvocation.h>
#include "NativeValueType.hpp"
#include <ptrauth.h>
#include <algorithm>
#include <cstring>
#include <memory>

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
    size_t registers = 0;
    for (const auto &component : result.components)
        registers += component.floating ? 1 : (component.size + sizeof(void *) - 1) / sizeof(void *);
    result.indirect = registers > 4;
    return result;
}

void fail(ABIResolutionFailure **error, int code, const char *message) {
    if (error) *error = ABICreateResolutionFailure(code, message);
}

size_t aligned(size_t value, size_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}
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
        if (!parameters[index] || !parameters[index]->storage->size()) {
            fail(error, ABIFailureInvalidRequest, "An explicit Swift parameter must have a value representation.");
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
            std::memcpy(destination, source, move.component.size);
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
            std::memcpy(static_cast<uint8_t *>(result) + component.offset, source, component.size);
        }
    }
    return true;
}
