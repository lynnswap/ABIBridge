#include <stdint.h>

_Static_assert(__has_feature(ptrauth_calls) == EXPECT_PTRAUTH,
               "The compiler must select the expected authenticated-call ABI");

__attribute__((noinline)) long compilerCall(long (*function)(long), long value) {
    return function(value) + 1;
}

__attribute__((noinline)) char *compilerAdvance(char *pointer, long offset) {
    return pointer + offset;
}

__attribute__((noinline)) uintptr_t compilerAdvanceInteger(uintptr_t pointer, uintptr_t offset) {
    return pointer + offset;
}
