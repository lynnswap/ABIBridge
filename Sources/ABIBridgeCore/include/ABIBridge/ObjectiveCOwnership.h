#ifndef ABIBRIDGE_OBJECTIVE_C_OWNERSHIP_H
#define ABIBRIDGE_OBJECTIVE_C_OWNERSHIP_H
#include <stdint.h>

/// Ownership overrides shared by Objective-C invocation and hooks. Zero-initialized options infer selector-family ownership.
typedef int32_t ABIObjCOwnership;
enum {
    ABIObjCOwnershipAutomatic = 0,
    ABIObjCOwnershipBorrowed = 1,
    ABIObjCOwnershipTransferred = 2
};

#endif
