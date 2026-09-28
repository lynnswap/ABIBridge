#include <stdint.h>
#include <ptrauth.h>

// A C-only image can actually unload; Swift metadata registration may pin a
// Swift provider. The symbol and two-word result match this compiler fixture:
// module ClosureLease; public func makeClosure() -> (Int64) -> Int64.
struct ClosureValue { const void *function; void *context; };

__attribute__((swiftcall))
static int64_t add(int64_t value, void *context __attribute__((swift_context))) {
    return value + 7;
}

__attribute__((swiftcall))
struct ClosureValue makeClosure(void) __asm__("$s12ClosureLease04makeA0s5Int64VADcyF");

__attribute__((swiftcall))
struct ClosureValue makeClosure(void) {
    const void *function = (const void *)&add;
#if __has_feature(ptrauth_calls)
    function = ptrauth_auth_and_resign(function, ptrauth_key_function_pointer, 0,
                                     ptrauth_key_function_pointer, 21761);
#endif
    return (struct ClosureValue){function, 0};
}
