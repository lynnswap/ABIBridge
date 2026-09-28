#include <cstdint>
#include <ptrauth.h>

namespace swift { class AsyncContext; }
using ErrorResume = __attribute__((swiftasynccall)) void(
    swift::AsyncContext * __attribute__((swift_async_context)),
    void * __attribute__((swift_context)));
struct Header {
    void *parent;
#if __has_feature(ptrauth_calls)
    ErrorResume * __ptrauth(ptrauth_key_function_pointer, 1, 0xd707) resume;
#else
    ErrorResume *resume;
#endif
};
extern "C" void *swift_errorRetain(void *);

// A noncapturing async entry in a C-only image, so dyld can unload it.
extern "C" __attribute__((swiftasynccall))
void ABIAsyncLeaseThrow(swift::AsyncContext *context __attribute__((swift_async_context)),
    void *reference) {
    auto *header = reinterpret_cast<Header *>(context);
    auto *error = swift_errorRetain(reference);
    [[clang::musttail]] return header->resume(context, error);
}

asm(".section __TEXT,__const\n"
    ".p2align 3\n"
    "_ABIAsyncLeaseDescriptor:\n"
    ".long _ABIAsyncLeaseThrow - _ABIAsyncLeaseDescriptor\n"
    ".long 16\n");
extern "C" const uint32_t ABIAsyncLeaseDescriptor[];
extern "C" const void *ABIAsyncLeaseEntry(void) { return ABIAsyncLeaseDescriptor; }
