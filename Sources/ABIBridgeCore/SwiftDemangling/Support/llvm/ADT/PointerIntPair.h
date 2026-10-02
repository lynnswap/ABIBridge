#pragma once

// The remangler uses this only as an internal substitution-map key. Its
// pointer and marker do not need LLVM's packed representation or ABI.
namespace llvm {
template<class Pointer, unsigned, class Integer> class PointerIntPair {
    Pointer pointer{};
    Integer value{};
public:
    Pointer getPointer() const { return pointer; }
    Integer getInt() const { return value; }
    void setPointer(Pointer pointer) { this->pointer = pointer; }
    void setInt(Integer value) { this->value = value; }
};
}
