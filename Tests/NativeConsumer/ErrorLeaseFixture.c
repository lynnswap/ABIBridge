#include <stddef.h>

extern void *swift_errorRetain(void *error);

// A C-only image can unload; Swift metadata registration can pin a Swift
// provider. This declaration matches the emitted IR for module ErrorLease:
// public func fail(_ reference: UnsafeRawPointer) throws.
__attribute__((swiftcall))
void fail(const void *reference, void *context __attribute__((swift_context)),
          void **error __attribute__((swift_error_result))) __asm__("$s10ErrorLease4failyySVKF");

__attribute__((swiftcall))
void fail(const void *reference, void *context __attribute__((swift_context)),
          void **error __attribute__((swift_error_result))) {
    (void)context;
    *error = swift_errorRetain((void *)reference);
}

const void *ABIErrorLeaseEntry(void) { return (const void *)&fail; }
