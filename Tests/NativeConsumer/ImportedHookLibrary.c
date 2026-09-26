#include <stdint.h>
extern int32_t ABIImportedAdd(int32_t,int32_t);
extern void ABIImportedSet(int32_t*,int32_t);
int32_t (*ABIImportedAddSlot)(int32_t,int32_t)=ABIImportedAdd;
void (*ABIImportedSetSlot)(int32_t*,int32_t)=ABIImportedSet;
int32_t ABIImportedCall(int32_t a,int32_t b) { return ABIImportedAddSlot(a,b); }
void ABIImportedWrite(int32_t *output,int32_t value) { ABIImportedSetSlot(output,value); }
