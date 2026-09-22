#ifndef ABIBRIDGE_NATIVE_DISPATCH_H
#define ABIBRIDGE_NATIVE_DISPATCH_H

#include <ABIBridge/Invocation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABIVirtualCallTarget ABIVirtualCallTarget;
enum {
    ABIAuthenticationUnsigned = -1,
    ABIAuthenticationInstructionA = 0,
    ABIAuthenticationInstructionB = 1,
    ABIAuthenticationDataA = 2,
    ABIAuthenticationDataB = 3
};

/// True when this build uses the pointer-authenticated call ABI.
bool ABIUsesPointerAuthentication(void);

/// Reads one pointer-sized field and authenticates data with an explicit schema.
/// Storage must remain readable for sizeof(void*) bytes. Null stays null.
/// Authentication failure is not translated to an error.
const void *ABIUnsafeReadAuthenticatedPointer(
    const void *storage, int32_t key, uintptr_t discriminator, bool addressDiversity);

/// Captures an absolute function-pointer slot, authenticates/resigns it for the
/// generic C call ABI, and retains its containing image when loader metadata is
/// available. The caller keeps table/code storage alive during lookup and owns
/// any generated code for which no containing image is known.
ABIVirtualCallTarget *ABICopyVirtualCallTarget(
    const void *storage, int32_t key, uintptr_t discriminator, bool addressDiversity,
    ABIResolutionFailure **error);
void ABIReleaseVirtualCallTarget(ABIVirtualCallTarget *target);
/// A signed generic C function pointer borrowed from a retained target.
ABIUnmanagedFunction ABIVirtualCallTargetFunction(const ABIVirtualCallTarget *target);
/// Preserves the generic C function pointer's signature when passing it as a
/// pointer-sized adapter argument. It must not be re-signed as an unsigned address.
const void *ABIFunctionPointerBits(ABIUnmanagedFunction function);

#ifdef __cplusplus
}
#endif
#endif
