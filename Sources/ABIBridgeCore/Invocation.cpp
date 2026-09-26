#include <ABIBridge/Invocation.h>
#include "NativeValueType.hpp"
#include <ptrauth.h>
#include <algorithm>
#include <atomic>
#include <climits>
#include <cstddef>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {
using abibridge::TypeStorage;

void fail(ABIResolutionFailure **error, int code, const char *message) {
    if (error) *error = ABICreateResolutionFailure(code, message);
}

ffi_type *scalarType(int32_t kind) {
    switch (kind) {
        case ABIValueVoid: return &ffi_type_void;
        case ABIValueUInt8: return &ffi_type_uint8;
        case ABIValueInt8: return &ffi_type_sint8;
        case ABIValueUInt16: return &ffi_type_uint16;
        case ABIValueInt16: return &ffi_type_sint16;
        case ABIValueUInt32: return &ffi_type_uint32;
        case ABIValueInt32: return &ffi_type_sint32;
        case ABIValueUInt64: return &ffi_type_uint64;
        case ABIValueInt64: return &ffi_type_sint64;
        case ABIValueFloat: return &ffi_type_float;
        case ABIValueDouble: return &ffi_type_double;
        case ABIValuePointer: return &ffi_type_pointer;
        default: return nullptr;
    }
}
}


struct ABICallInterface {
    std::atomic<size_t> references{1};
    ffi_cif cif{};
    std::shared_ptr<TypeStorage> result;
    std::vector<std::shared_ptr<TypeStorage>> parameters;
    std::vector<ffi_type*> nativeParameters;
};

ABIValueType *ABICreateScalarType(int32_t kind, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    auto *scalar = scalarType(kind);
    if (!scalar) {
        fail(error, ABIFailureUnsupportedDeclaration, "Unknown scalar C ABI type.");
        return nullptr;
    }
    auto storage = std::make_shared<TypeStorage>();
    storage->scalar = scalar;
    return new ABIValueType{std::move(storage)};
}

ABIValueType *ABICreateStructType(
    const ABIValueType *const *fields, size_t count, ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (!fields || !count) {
        fail(error, ABIFailureInvalidRequest, "A C aggregate requires field types.");
        return nullptr;
    }
    auto storage = std::make_shared<TypeStorage>();
    for (size_t index = 0; index < count; ++index) {
        if (!fields[index] || fields[index]->storage->native()->type == FFI_TYPE_VOID) {
            fail(error, ABIFailureInvalidRequest, "A C aggregate field must have a value type.");
            return nullptr;
        }
        storage->fields.push_back(fields[index]->storage);
        storage->elements.push_back(fields[index]->storage->native());
    }
    storage->elements.push_back(nullptr);
    storage->aggregate.elements = storage->elements.data();
    storage->offsets.resize(count);
    // libffi otherwise initializes aggregate layout lazily during preparation.
    // Complete it before publishing a type shared by concurrent interfaces.
    if (ffi_get_struct_offsets(FFI_DEFAULT_ABI, &storage->aggregate, storage->offsets.data()) != FFI_OK) {
        fail(error, ABIFailureUnsupportedDeclaration, "The aggregate cannot be represented by the platform C ABI.");
        return nullptr;
    }
    return new ABIValueType{std::move(storage)};
}

void ABIReleaseValueType(ABIValueType *type) { delete type; }
size_t ABIValueTypeSize(const ABIValueType *type) { return type->storage->size(); }
size_t ABIValueTypeAlignment(const ABIValueType *type) { return type->storage->native()->alignment; }
bool ABIValueTypeIsPointer(const ABIValueType *type) { return type->storage->native()->type == FFI_TYPE_POINTER; }
size_t ABIValueTypeFieldCount(const ABIValueType *type) { return type->storage->offsets.size(); }
size_t ABIValueTypeFieldOffset(const ABIValueType *type, size_t index) { return type->storage->offsets[index]; }

ABICallInterface *ABICreateCCallInterface(
    const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (!result || (count && !parameters) || count > UINT_MAX) {
        fail(error, ABIFailureInvalidRequest, "A result and a representable parameter list are required.");
        return nullptr;
    }
    auto interface = std::make_unique<ABICallInterface>();
    interface->result = result->storage;
    for (size_t index = 0; index < count; ++index) {
        if (!parameters[index] || parameters[index]->storage->native()->type == FFI_TYPE_VOID) {
            fail(error, ABIFailureInvalidRequest, "A parameter must have a non-void value type.");
            return nullptr;
        }
        interface->parameters.push_back(parameters[index]->storage);
        interface->nativeParameters.push_back(parameters[index]->storage->native());
    }
    if (ffi_prep_cif(&interface->cif, FFI_DEFAULT_ABI, static_cast<unsigned int>(count),
                    interface->result->native(), interface->nativeParameters.data()) != FFI_OK) {
        fail(error, ABIFailureUnsupportedDeclaration, "The signature cannot be represented by the platform C ABI.");
        return nullptr;
    }
    return interface.release();
}

void ABIRetainCallInterface(ABICallInterface *interface) { ++interface->references; }
void ABIReleaseCallInterface(ABICallInterface *interface) {
    if (interface && --interface->references == 0) delete interface;
}

struct ABICallClosure {
    ABICallInterface *interface;
    ffi_closure *storage = nullptr;
    void *code = nullptr;
    ABICallClosureHandler handler;
    void *context;

    ~ABICallClosure() {
        if (storage) ffi_closure_free(storage);
        ABIReleaseCallInterface(interface);
    }
};

ABICallClosure *ABICreateCallClosure(ABICallInterface *interface,
    ABICallClosureHandler handler, void *context, ABIResolutionFailure **error) {
    if (error) *error = nullptr;
    if (!interface || !handler) {
        fail(error, ABIFailureInvalidRequest, "A prepared interface and callback are required.");
        return nullptr;
    }
    ABIRetainCallInterface(interface);
    auto closure = std::make_unique<ABICallClosure>(interface, nullptr, nullptr, handler, context);
    closure->storage = static_cast<ffi_closure *>(ffi_closure_alloc(sizeof(ffi_closure), &closure->code));
    if (!closure->storage) {
        fail(error, ABIFailureUnsupportedDeclaration, "The platform could not allocate a callback entry.");
        return nullptr;
    }
    const auto status = ffi_prep_closure_loc(closure->storage, &interface->cif,
        [](ffi_cif *, void *result, void **arguments, void *context) {
            auto *closure = static_cast<ABICallClosure *>(context);
            closure->handler(closure->context, result, arguments);
        }, closure.get(), closure->code);
    if (status != FFI_OK) {
        fail(error, ABIFailureUnsupportedDeclaration, "The platform could not prepare a callback entry.");
        return nullptr;
    }
    return closure.release();
}

ABIUnmanagedFunction ABICallClosureFunction(const ABICallClosure *closure) {
    void *code = closure->code;
#if __has_feature(ptrauth_calls)
    // libffi's Apple trampoline allocator already signs this pointer with
    // function key / discriminator zero. Signing it as a raw address corrupts
    // it before the Objective-C runtime authenticates the installed IMP.
    code = ptrauth_auth_and_resign(code, ptrauth_key_function_pointer, 0,
        ptrauth_key_function_pointer, ptrauth_function_pointer_type_discriminator(void(void)));
#endif
    return reinterpret_cast<ABIUnmanagedFunction>(code);
}
void ABIReleaseCallClosure(ABICallClosure *closure) { delete closure; }

ABIUnmanagedFunction ABIUnsafeFunctionAtAddress(const void *address) {
    if (!address) return nullptr;
    void *pointer = const_cast<void*>(address);
#if __has_feature(ptrauth_calls)
    pointer = ptrauth_sign_unauthenticated(
        pointer, ptrauth_key_function_pointer,
        ptrauth_function_pointer_type_discriminator(void(void)));
#endif
    return reinterpret_cast<ABIUnmanagedFunction>(pointer);
}

bool ABIUnsafeInvokeCCallInterface(
    ABICallInterface *interface, ABIUnmanagedFunction function,
    void *result, void *const *arguments, ABIResolutionFailure **error)
{
    if (error) *error = nullptr;
    if (!interface || !function || (interface->result->size() && !result)
        || (!interface->parameters.empty() && !arguments)) {
        fail(error, ABIFailureInvalidRequest, "A call interface, function, and value storage are required.");
        return false;
    }
    std::vector<void*> values;
    values.reserve(interface->parameters.size());
    for (size_t index = 0; index < interface->parameters.size(); ++index) {
        if (!arguments[index]) {
            fail(error, ABIFailureInvalidRequest, "Each parameter requires value storage.");
            return false;
        }
        values.push_back(arguments[index]);
    }
    const size_t size = interface->result->size();
    const size_t capacity = std::max(size, sizeof(ffi_arg));
    std::vector<std::max_align_t> storage(
        (capacity + sizeof(std::max_align_t) - 1) / sizeof(std::max_align_t));
    ffi_call(&interface->cif, function, size ? storage.data() : nullptr, values.data());
    if (size) std::memcpy(result, storage.data(), size);
    return true;
}
