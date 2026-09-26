#include "ABIBridgeLoadingFixture.h"

static int32_t initializedValue;
static int32_t constructorCount;
__attribute__((constructor)) static void initialize(void) {
    initializedValue = 42;
    ++constructorCount;
}
int32_t ABIImageLoadingFixtureValue(void) { return initializedValue; }
int32_t ABIImageLoadingFixtureConstructorCount(void) { return constructorCount; }
