# Architectures and pointer authentication

Distinguish the architecture of an inspected image from the ABI used by the calling process.

## Supported architectures

ABIBridge supports arm64, arm64e, and arm64_32.

## Inspect metadata independently of execution

MachOKit can recognize arm64e.x1 metadata without executing that architecture. Finding a symbol in an image or cache does not establish that its address can be invoked by the current process. Preserve the complete CPU subtype, including capability bits, when recording an image's identity.

The compiler selects authenticated call paths with `__has_feature(ptrauth_calls)`. Hardware PAC support alone does not establish an image's arm64e ABI. Pointer normalization supplies inspection evidence; invocation needs the matching ABI and authentication contract.

## Current execution evidence

Focused fixtures were run on an iPhone Air with iOS 27.0, built using Xcode 27.0 with all linked package targets compiled for arm64e. The test host had Enhanced Security and hardware memory tagging enabled.

| Operation | Observed result |
| --- | --- |
| Compiler-lowered C/C++ calls through the native headers | Passed scalar calls, indirect results, bound receiver lifetime, and authenticated virtual dispatch. |
| Concrete Swift calls | Passed register/stack arguments, owned String results, and bound class receiver retention/release. |
| Memory reading and pointer discovery | Passed in-bounds arithmetic, copied reads, and bounded discovery in a tagged allocation. |
| Corrupted function-pointer signature | The isolated control terminated with `EXC_ARM_PAC_FAIL` inside authentication. |
| Swift/C dynamic invocation through libffi | Passed scalar calls, aggregate arguments/indirect results, C++ receiver and authenticated virtual calls, signed targets through an adapter, and Objective-C invocation. |

The [pinned ZDLibffi fork 0.380.1](https://github.com/lynnswap/ZDLibffi/releases/tag/0.380.1) fixes authentication in the C/assembly paths and Mach closure trampolines. See [#106](https://github.com/lynnswap/ABIBridge/issues/106) for the original arm64e failure and regression coverage.

These fixtures cover specific ABI contracts. They do not establish compatibility with arbitrary private layouts, compiler-specific signature discriminators, or every Swift signature. Authentication failures can terminate the process and are not Swift errors.

The tagged-allocation fixture records the allocation's top byte and original pointer bits. It does not test use-after-free protection or out-of-bounds enforcement. Passing it on a device without an observed tag supplies no evidence about tagged memory.

## Imported-function replacement evidence

The `import-replacement` fixture recorded the earlier VM-only behavior and the current thread-scoped TPRO implementation:

| Configuration | Import page | Control storage |
| --- | --- | --- |
| M5 Pro / macOS 26.6.2, normal chained `getppid` import | TPRO refused writes with `KERN_PROTECTION_FAILURE`; pointer, behavior, and protections stayed unchanged. | Legacy-binding and allocated read-only controls passed replacement, predecessor calls, and restoration. |
| iPhone Air / iOS 27.0, arm64e Enhanced Security host | TPRO refused mutation; pointer and protections stayed unchanged. | The allocated read-only control passed authenticated replacement, predecessor calls, and restoration. |
| iPhone Air / iOS 27.0.1, Xcode 27.2, Release arm64e, TPRO validation entitlements (November 2, 2026) | Authenticated chained import replacement, predecessor calls, conflict detection, and restoration passed with the TPRO flag present. Current/maximum protections stayed `1/3`; the full thread register state was preserved from both read-only and writable entry states. | Unsigned and IA/IB/DA/DB address-diversified controls passed. Primary, secondary, and covariant virtual entries also passed replacement and restoration on TPRO pages. |

The iPhone import used `DYLD_CHAINED_PTR_ARM64E_USERLAND24` with instruction key A, discriminator zero, and address diversity. Its captured original function authenticated correctly. Writable control storage does not establish writability of a protected import, even when maximum protections include WRITE. The macOS arm64 run also supplies no pointer-authentication evidence. See the [import-rebinding workstream](https://github.com/lynnswap/ABIBridge/issues/121) for mutation support and failure reporting. Symbol inspection and existing invocation APIs do not require disabling process security.

The November 2 run also passed the `code-references` probe and the public Swift/C/C++ virtual-hook probe. See the [validation instructions](https://github.com/lynnswap/ABIBridge/blob/main/Tests/ArchitectureValidation/README.md#imported-function-replacement-probe) for the explicit TPRO host configuration. These observations do not establish runtime support on every ARM64 CPU or on arm64_32.

## arm64e.x1 remains unverified at runtime

The compiler fixture and Swift trampoline produce these raw Mach-O headers with Xcode 27.0:

| Target | CPU type | Raw CPU subtype | Indirect calls | Typed pointer arithmetic |
| --- | --- | --- | --- | --- |
| arm64 | `0x0100000c` | `0x00000000` | Unsigned | Ordinary addition |
| arm64e | `0x0100000c` | `0x80000002` | Authenticated | Ordinary addition |
| arm64e.x1 | `0x0100000c` | `0x8000000c` | Authenticated | `addpt` |

The arm64e.x1 target retains the authenticated-call convention in these fixtures and changes compiler-generated pointer arithmetic. Integer arithmetic on address values is not automatically equivalent to checked pointer arithmetic. The available iPhone Air does not support the arm64e.x1 slice, so these are compilation observations only.

Xcode 27.0 and 27.2 full-package builds failed in `SwiftMergeGeneratedHeaders` with `Unsupported Swift architectures: arm64e.x1`. With [Custom Xcode Build Service custom-v0.2.5](https://github.com/lynnswap/swift-build/releases/tag/custom-v0.2.5), both built and linked `ArchitectureProbe` and its dependencies while preserving raw subtype `0x8000000c` and generated Objective-C headers. Xcode 27.2 also produced arm64e/arm64e.x1 universal output. This establishes compilation and linking with the custom service; runtime execution and Xcode's bundled service remain unverified. See [#103](https://github.com/lynnswap/ABIBridge/issues/103#issuecomment-5846529137) for settings and build evidence.

Follow Apple's [Enhanced Security guidance](https://developer.apple.com/documentation/xcode/enabling-enhanced-security-for-your-app) for `ENABLE_POINTER_AUTHENTICATION`, `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE`, entitlements, and supported hardware. Align settings across dependencies and verify loaded slices and runtime checks on hardware. Simulator runs cannot validate these protections. [#103](https://github.com/lynnswap/ABIBridge/issues/103) tracks the outstanding hardware work. Metadata parsing remains available at ABIBridge's existing deployment targets.
