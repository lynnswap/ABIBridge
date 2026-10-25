#pragma once
#ifdef __cplusplus
extern "C" {
#endif

/// Demangles an Itanium name with an optional Mach-O underscore. Returns null when decoding fails; the caller frees a successful result with ABIFreeString.
char *ABICopyDemangledCXXName(const char *name);
/// Demangles a modern Swift symbol. Returns null when decoding is unavailable or the name is unsupported. A successful result belongs to the caller.
char *ABICopyDemangledSwiftName(const char *name);
/// Frees a string allocated by a backend operation.
void ABIFreeString(char *string);

#ifdef __cplusplus
}
#endif
