#ifndef ABIBRIDGE_NATIVE_VALUE_TYPE_HPP
#define ABIBRIDGE_NATIVE_VALUE_TYPE_HPP

#include <ffi.h>
#include <memory>
#include <vector>

namespace abibridge {
struct TypeStorage {
    ffi_type *scalar = nullptr;
    ffi_type aggregate{0, 0, FFI_TYPE_STRUCT, nullptr};
    std::vector<std::shared_ptr<TypeStorage>> fields;
    std::vector<ffi_type*> elements;
    std::vector<size_t> offsets;

    ffi_type *native() { return scalar ? scalar : &aggregate; }
    size_t size() { return native()->type == FFI_TYPE_VOID ? 0 : native()->size; }
};
}

struct ABIValueType {
    std::shared_ptr<abibridge::TypeStorage> storage;
};
#endif
