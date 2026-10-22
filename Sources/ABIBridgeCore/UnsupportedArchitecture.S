// ABIBridge's Swift call and callback trampolines exist only for AArch64
// (arm64, arm64e, and arm64_32). Xcode builds package targets for every
// standard architecture in Release and Archive builds, even for apps that
// exclude x86_64, so other slices must compile. Linking one into a binary
// fails instead on this undefined symbol; the no_dead_strip section keeps the
// reference through -dead_strip.
#if !defined(__aarch64__)
.section __DATA,__abibridge_arch,regular,no_dead_strip
.p2align 3
    .quad _ABIBridge_supports_only_arm64_arm64e_arm64_32
#endif
