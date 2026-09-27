#include <stdint.h>
extern int32_t ABIImportedAdd(int32_t, int32_t);
extern void ABIRunImportedMonitorInitializer(void);
static int32_t (*volatile slot)(int32_t, int32_t) = ABIImportedAdd;
__attribute__((constructor)) static void initialize(void) { ABIRunImportedMonitorInitializer(); }
int32_t ABIMonitoredCall(int32_t a, int32_t b) { return slot(a, b); }
