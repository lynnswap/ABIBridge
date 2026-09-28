#include <ptrauth.h>

// Compiler contract: ErrorClosureFactory.make(_: UnsafeRawPointer)
// -> (UnsafeRawPointer) throws -> Void. The returned entry belongs to a
// separately loaded provider, so retaining this factory image is insufficient.
struct ClosureValue { const void *function; void *context; };

__attribute__((swiftcall))
struct ClosureValue make(const void *entry) __asm__("$s19ErrorClosureFactory4makeyySVKcSVF");

__attribute__((swiftcall))
struct ClosureValue make(const void *entry) {
#if __has_feature(ptrauth_calls)
    entry = ptrauth_auth_and_resign(entry, ptrauth_key_function_pointer, 0,
                                  ptrauth_key_function_pointer, 62266);
#endif
    return (struct ClosureValue){entry, 0};
}
