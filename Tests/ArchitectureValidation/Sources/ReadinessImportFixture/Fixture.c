#include <stdint.h>
#include <unistd.h>

static uid_t (*volatile uidSlot)(void) = getuid;
static int32_t initializationCount;

__attribute__((constructor)) static void holdInitialization(void) {
    // Let the image observer receive the dyld event before this image is ready.
    usleep(500000);
    ++initializationCount;
}

uint32_t ABIReadinessUID(void) { return uidSlot(); }
int32_t ABIReadinessInitializationCount(void) { return initializationCount; }
