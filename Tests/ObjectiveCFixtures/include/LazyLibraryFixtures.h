#ifndef ABI_LAZY_LIBRARY_FIXTURES_H
#define ABI_LAZY_LIBRARY_FIXTURES_H
#include <stddef.h>
/// Caller frees the returned synthetic Mach-O storage with free().
unsigned char *ABICreateLazyLibraryFixture(int wide, int swapped);
size_t ABILazyLibraryFixtureSize(void);
#endif
