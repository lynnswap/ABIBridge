#include "include/LazyLibraryFixtures.h"
#include "../NativeConsumer/LazyLibraryFixture.h"

unsigned char *ABICreateLazyLibraryFixture(int wide, int swapped) { return ABITestLazyCreate(wide, swapped); }
size_t ABILazyLibraryFixtureSize(void) { return ABITestLazySize; }
