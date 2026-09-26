#ifndef ABIBRIDGE_CORE_H
#define ABIBRIDGE_CORE_H

// Internal umbrella. The supported C consumer surface is Inspection.h.
#include <ABIBridge/Inspection.h>
#include <ABIBridge/ObjectiveCHooks.h>
#include <ABIBridge/Runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Demangles an Itanium name with an optional Mach-O underscore. Returns null
/// when decoding fails; the caller frees a successful result with ABIFreeString.
char *ABICopyDemangledCXXName(const char *name);
/// Demangles a modern Swift symbol. Returns null when decoding is unavailable
/// or the name is unsupported. A successful result belongs to the caller.
char *ABICopyDemangledSwiftName(const char *name);
/// Frees a string returned by either demangling function.
void ABIFreeString(char *string);

#ifdef __cplusplus
}
#endif

#include <ABIBridge/Invocation.h>
#include <ABIBridge/NativeDispatch.h>
#include <ABIBridge/SwiftInvocation.h>

#endif
