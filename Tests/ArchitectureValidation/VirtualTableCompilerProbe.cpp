#include "Sources/ArchitectureFixtures/VirtualOracles.cpp"
#include <ptrauth.h>
#include <stdint.h>

static_assert(__has_builtin(__builtin_get_vtable_pointer));
static_assert(__has_feature(ptrauth_calls) == EXPECT_PTRAUTH);
#if __has_feature(ptrauth_calls)
#define DISC(NAME) ptrauth_string_discriminator(NAME)
#else
#define DISC(NAME) 0
#endif
extern "C" {
extern const uintptr_t ABICompilerPrimaryVptr = DISC("_ZTVN9ABIVTable7PrimaryE");
extern const uintptr_t ABICompilerSecondaryVptr = DISC("_ZTVN9ABIVTable9SecondaryE");
extern const uintptr_t ABICompilerPrimarySlot = DISC("_ZNK9ABIVTable7Primary5valueEi");
extern const uintptr_t ABICompilerSecondarySlot = DISC("_ZNK9ABIVTable9Secondary8adjustedEi");
extern const uintptr_t ABICompilerCovariantSlot = DISC("_ZN9ABIVTable9Secondary8identityEv");
const void *ABICompilerPrimaryTable(ABIVTable::Derived *object) { return __builtin_get_vtable_pointer(object); }
const void *ABICompilerSecondaryTable(ABIVTable::Secondary *object) { return __builtin_get_vtable_pointer(object); }
}
