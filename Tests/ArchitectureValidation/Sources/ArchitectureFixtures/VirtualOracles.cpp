#include "VirtualMutation.hpp"
#include <stdint.h>

namespace ABIVTable {
int Primary::value(int input) const { return seed + input; }
int Secondary::adjusted(int input) const { return secondarySeed + input; }
Secondary *Secondary::identity() { return this; }
int Derived::value(int input) const { return ownSeed + input; }
int Derived::adjusted(int input) const { return ownSeed + secondarySeed + input; }
Derived *Derived::identity() { return this; }

// A separate translation unit preserves genuine virtual dispatch in optimized
// builds, while the final-class control can deliberately devirtualize.
__attribute__((noinline)) int primaryOracle(const Primary *object, int input) { return object->value(input); }
__attribute__((noinline)) int secondaryOracle(const Secondary *object, int input) { return object->adjusted(input); }
__attribute__((noinline)) Secondary *covariantOracle(Secondary *object) { return object->identity(); }
__attribute__((noinline)) int directOracle(const Derived *object, int input) { return object->value(input); }
}

// The compiler establishes both base conversion and vptr authentication.
static ABIVTable::Derived namedObject(40);
extern "C" void *ABINamedVirtualReceiver(uint32_t kind) {
    if (kind) return static_cast<ABIVTable::Secondary*>(&namedObject);
    return &namedObject;
}
extern "C" const void *ABINamedVirtualTable(uint32_t kind) {
    if (kind) return __builtin_get_vtable_pointer(static_cast<ABIVTable::Secondary*>(&namedObject));
    return __builtin_get_vtable_pointer(&namedObject);
}
