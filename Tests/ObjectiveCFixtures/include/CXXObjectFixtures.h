#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*ABICXXGenericFunction)(void);
extern const int32_t ABICXXFixtureData;
void *ABICXXCreateCounter(int32_t value);
void ABICXXDeleteCounter(void *value);
size_t ABICXXCounterSize(void);
size_t ABICXXCounterAlignment(void);
int32_t ABICXXCounterLiveCount(void);
void *ABICXXCreateToken(int32_t value);
void ABICXXDeleteToken(void *value);
int32_t ABICXXTokenValue(const void *value);
int32_t ABICXXTokenLiveCount(void);
void *ABICXXTransformAdapter(ABICXXGenericFunction target, void *receiver, const void *argument);

void *ABICXXCreateDerived(void);
void ABICXXDeleteDerived(void *value);
size_t ABICXXDerivedSize(void);
size_t ABICXXDerivedAlignment(void);
size_t ABICXXSecondaryOffset(const void *value);
size_t ABICXXSecondarySize(void);
size_t ABICXXSecondaryAlignment(void);
int32_t ABICXXBaseOracle(const void *value);
int32_t ABICXXSecondaryOracle(const void *value);
uintptr_t ABICXXBaseVTableDiscriminator(void);
uintptr_t ABICXXSecondaryVTableDiscriminator(void);
uintptr_t ABICXXBaseSlotDiscriminator(void);
uintptr_t ABICXXSecondarySlotDiscriminator(void);
void ABICXXStoreSignedDataPointer(void *storage, const void *value);

#ifdef __cplusplus
}
#endif
