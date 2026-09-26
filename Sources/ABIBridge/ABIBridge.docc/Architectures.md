# Architectures and pointer authentication

Distinguish the architecture of an inspected image from the ABI used by the calling process.

## Inspect metadata independently of execution

MachOKit can recognize arm64e.x1 metadata without executing that architecture. Finding a symbol in an image or cache does not establish that its address can be invoked by the current process. Preserve the complete CPU subtype, including capability bits, when recording an image's identity.

The compiler selects ABIBridge's authenticated call paths with `__has_feature(ptrauth_calls)`. Hardware support for PAC alone does not imply that a particular image was compiled with the arm64e ABI. Likewise, automatic pointer normalization is an inspection operation, not proof of authentication or of call compatibility.

## Current execution evidence

Focused fixtures were run on an iPhone Air with iOS 27.0, built using Xcode 27.0 with all linked package targets compiled for arm64e. The test host had Enhanced Security and hardware memory tagging enabled.

| Operation | Observed result |
| --- | --- |
| Compiler-lowered C/C++ calls through the native headers | Passed scalar calls, indirect results, bound receiver lifetime, and authenticated virtual dispatch. |
| Concrete Swift calls | Passed register/stack arguments, owned String results, and bound class receiver retention/release. |
| Memory reading and pointer discovery | Passed in-bounds arithmetic, copied reads, and bounded discovery in a tagged allocation. |
| Corrupted function-pointer signature | The isolated control terminated with `EXC_ARM_PAC_FAIL` inside authentication. |
| Swift/C dynamic invocation through libffi | Passed scalar calls, aggregate arguments/indirect results, C++ receiver and authenticated virtual calls, signed targets through an adapter, and Objective-C invocation. |

ABIBridge pins [ZDLibffi fork 0.380.1](https://github.com/lynnswap/ZDLibffi/releases/tag/0.380.1), which aligns the C and assembly authentication paths and the Mach closure trampolines. The original 0.380.0 dependency's arm64e failure and the integration regression tests are tracked in [#106](https://github.com/lynnswap/ABIBridge/issues/106).

These fixtures cover specific ABI contracts. They do not establish compatibility with arbitrary private layouts, compiler-specific signature discriminators, or every Swift signature. Authentication failures can terminate the process and are not Swift errors.

The tagged-allocation fixture records the allocation's top byte and original pointer bits. It does not test use-after-free protection or out-of-bounds enforcement. Passing it on a device without an observed tag supplies no evidence about tagged memory.

## Imported-function replacement evidence

The experimental `import-replacement` fixture distinguishes symbol discovery from writable call-site storage. On M5 Pro / macOS 26.6.2, the normal chained `getppid` import was in a TPRO-protected page. The kernel rejected adding write permission with `KERN_PROTECTION_FAILURE`; the original pointer, native behavior and current/maximum page protections remained unchanged. A legacy-binding build of the same fixture allowed replacement, captured-predecessor invocation and restoration. An allocated read-only control page also allowed mutation and restoration.

These are bounded fixture results, not a public rebinding capability. A maximum protection containing WRITE does not establish that the kernel permits a change, and an arm64 run does not validate pointer authentication. The [import-rebinding workstream](https://github.com/lynnswap/ABIBridge/issues/121) tracks supported mutation paths and concrete failure reporting separately from name resolution. Disabling process security is not a prerequisite for symbol inspection or existing invocation APIs.

## arm64e.x1 remains unverified at runtime

The compiler fixture and Swift trampoline produce these raw Mach-O headers with Xcode 27.0:

| Target | CPU type | Raw CPU subtype | Indirect calls | Typed pointer arithmetic |
| --- | --- | --- | --- | --- |
| arm64 | `0x0100000c` | `0x00000000` | Unsigned | Ordinary addition |
| arm64e | `0x0100000c` | `0x80000002` | Authenticated | Ordinary addition |
| arm64e.x1 | `0x0100000c` | `0x8000000c` | Authenticated | `addpt` |

The arm64e.x1 target retains the authenticated-call convention in these fixtures and changes compiler-generated pointer arithmetic. Integer arithmetic on address values is not automatically equivalent to checked pointer arithmetic. The available iPhone Air does not support the arm64e.x1 slice, so these are compilation observations only.

Earlier full package builds with Xcode 27.0 and 27.2 stopped in `SwiftMergeGeneratedHeaders` with `Unsupported Swift architectures: arm64e.x1`. With [Custom Xcode Build Service custom-v0.2.5](https://github.com/lynnswap/swift-build/releases/tag/custom-v0.2.5), both Xcode versions built and linked the `ArchitectureProbe` executable and all package dependencies for arm64e.x1, without disabling generated Objective-C headers. The executable and ABIBridge, MachOKit, and ZDLibffi objects preserved raw CPU subtype `0x8000000c`. Xcode 27.2 also produced an executable containing both arm64e and arm64e.x1 slices.

These results establish compilation and linking with that custom build service. They do not establish arm64e.x1 execution or a fix in Xcode's bundled service. The build settings and verification details are recorded in [#103](https://github.com/lynnswap/ABIBridge/issues/103#issuecomment-5846529137).

Apple's [Enhanced Security guidance](https://developer.apple.com/documentation/xcode/enabling-enhanced-security-for-your-app) describes `ENABLE_POINTER_AUTHENTICATION`, `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE`, the required entitlements, and supported hardware. Use matching settings and available slices throughout the app's dependencies, then verify the actually loaded image and runtime checks on hardware. Simulator execution cannot validate these protections. The outstanding hardware validation remains in [#103](https://github.com/lynnswap/ABIBridge/issues/103); parsing newer metadata does not require raising ABIBridge's deployment targets.
