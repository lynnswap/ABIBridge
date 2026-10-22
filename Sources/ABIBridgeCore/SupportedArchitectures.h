#ifndef ABIBRIDGE_SUPPORTED_ARCHITECTURES_H
#define ABIBRIDGE_SUPPORTED_ARCHITECTURES_H

// The Swift call and callback trampolines implement only the AArch64 Swift
// calling convention. Reject other targets instead of building a library
// without them.
#if !defined(__aarch64__)
#error ABIBridge supports only arm64, arm64e, and arm64_32 targets; x86_64 is not supported.
#endif

#endif
