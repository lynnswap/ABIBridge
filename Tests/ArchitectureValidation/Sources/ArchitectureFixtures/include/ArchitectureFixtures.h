#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif
#ifdef __cplusplus
extern "C" {
#endif
#ifdef __OBJC__
Class _Nonnull ABIValidationInitializerClass(void);
NSObject * _Nullable ABIValidationCreateInitialized(int32_t seed) NS_RETURNS_RETAINED;
#endif
uint32_t ABIValidationCPUType(void);
uint32_t ABIValidationCPUSubtype(void);
bool ABIValidationPACCompiled(void);
int32_t ABIValidationAdd(int32_t a, int32_t b);
typedef struct {
    int64_t a, b, c, d, e, f, g, h;
} ABIValidationLarge;
ABIValidationLarge ABIValidationShiftLarge(ABIValidationLarge value);
void *ABIValidationCreateCounter(void);
void ABIValidationDeleteCounter(void *counter);
uintptr_t ABIValidationCounterSize(void);
uintptr_t ABIValidationCounterAlignment(void);
uintptr_t ABIValidationTableDiscriminator(void);
uintptr_t ABIValidationSlotDiscriminator(void);
int32_t ABIValidationCounterOracle(const void *counter);
int32_t ABIValidationCounterAdapter(void (*target)(void), void *counter, int32_t delta);
/// Null on success; otherwise an owned-by-fixture diagnostic string.
const char *ABIValidateNativeCalls(void);
/// Internal Objective-C replacement entry, including cached authenticated IMPs.
const char *ABIValidateObjCReplacement(void);
const char *ABIValidateNativeObjCHooks(void);
const char *ABIValidateCoordinatedObjCHooks(void);
/// Fixture-only probes; valid slot addresses and schemas come from its own image.
const void *ABIImportProbeImage(void);
int32_t ABIImportProbeCall(void);
typedef struct {
    bool changed;
    int32_t protectionResult;
    int32_t protectionBefore, protectionAfter;
    int32_t maximumBefore, maximumAfter;
    uint32_t regionFlags;
} ABIImportProbeResult;
const char *ABIValidateImportSlot(void *slot, int32_t key, uintptr_t extra, bool diverse,
    ABIImportProbeResult *result);
const char *ABIValidateReadOnlySignedSlot(ABIImportProbeResult *result);
/// Positive control using the same signing schema and call path as tamper mode.
bool ABIValidateAuthenticatedFunction(void);
/// Returns false if a signed-bit mutation could not be formed. A successful
/// authentication check must terminate the isolated probe before this returns true.
bool ABIValidateTamperedFunction(void);
void *ABIValidationAllocate(void);
void ABIValidationDeallocate(void *pointer);
void *ABIValidationAdvance(char *pointer, long offset);
uintptr_t ABIValidationAdvanceInteger(uintptr_t pointer, uintptr_t offset);
#ifdef __cplusplus
}
#endif
