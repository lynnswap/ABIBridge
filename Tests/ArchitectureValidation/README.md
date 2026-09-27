# Architecture and replacement validation

This package compares compiler-generated calls with ABIBridge's invocation machinery. Run its tests with Xcode using the commands in [CONTRIBUTING](../../CONTRIBUTING.md). The `replacement` mode additionally checks the internal Objective-C callback boundary on a signed device host. It is not a public hook-installation API.

## Objective-C replacement boundary

The package-private Swift `ObjCReplacement` and internal `ABIBridgeObjCXX/Replacement.h` entry points prepare a callable implementation without mutating a method table. The root package's `ObjectiveCReplacementTests` temporarily install that implementation on dedicated compiler-authored fixture classes. Managed registration, inheritance, and multiple-hook ordering are covered by `ObjectiveCMethodHookTests` and the public [method-hook guide](../../Sources/ABIBridge/ABIBridge.docc/ObjectiveCMethodHooks.md). Public initializer hooks are covered by `ObjectiveCInitializerHookTests` and the Swift initializer consumer; the native frontend consumers exercise C, C++, ARC/MRC Objective-C++, and mixed Swift/C chains.

The boundary keeps these contracts:

- A prepared C interface is shared immutably by invocations and retained by its libffi closure. Argument decoding reads borrowed native storage; it does not copy every incoming argument into a temporary heap buffer.
- Each call has its own result and callback frame. Swift continuations are non-Sendable views with runtime expiry/thread checks. Saving a view does not extend the native frame. This implementation requires no experimental lifetime flags or consumer `@testable` import; validation uses package access.
- A callback failure before entering the next implementation passes the original native arguments through. Once a next-call result exists, failure preserves that result instead of repeating native side effects. Declared signature/ownership correctness and no foreign exception unwinding through libffi remain caller requirements.
- Ordinary results preserve Objective-C +0/+1 conventions and explicit ownership overrides. Initializer entry handles incoming +1 self without creating a Swift reference to it, calls native initialization once, and forwards the actual +1 object or nil. Replacing self and super/nested initialization are tested independently. Explicit consumed arguments and other special lifetime methods are outside this boundary.
- The ordinary callback stays on its caller's thread. The MainActor route requires a known MainActor method contract, checks the thread before Swift argument decoding, and synchronously uses `MainActor.assumeIsolated`. It does not infer arbitrary executor isolation from installation or dispatch work to another actor. Background entry bypasses the actor callback and reports the violation.
- Invalidation drops the entry's callback reference under a lock and releases captures outside it. An in-flight callback snapshot keeps its captures until completion. No registry or frame lock spans callback/native execution, and invalidation from a callback does not wait for itself.
- Publishing an IMP makes its executable entry and fallback binding process-lived. Owner release invalidates callback behavior but leaves cached IMPs callable. An unpublished entry can free its closure immediately. An explicit fallback owner can retain generated original code or a dynamic class independently of callback captures; otherwise their validity remains the caller's responsibility. This intentionally separates executable lifetime from callback lifetime; it does not promise physical teardown or unloading of retained images.
- Apple's libffi allocator returns an already signed trampoline pointer on arm64e. The bridge authenticates/re-signs that value for its function-pointer type; it must not sign it again as an unsigned address. Objective-C installation and cached-IMP invocation both exercise this contract.

## Checks

Run the root replacement tests in both configurations. The Release run retains normal optimized package visibility; it does not enable testability to expose private symbols.

```sh
xcodebuild test -scheme ABIBridge -destination 'platform=macOS,arch=arm64' \
  -only-testing:ABIBridgeTests/ObjectiveCReplacementTests
xcodebuild test -configuration Release -scheme ABIBridge \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ABIBridgeTests/ObjectiveCReplacementTests
```

Coverage includes narrow signed results, standard structures, mixed register/stack arguments, class/object/block values, retained results, conversion failures, main-thread/background entry, concurrent invocations, in-flight invalidation, saved IMPs, and same/nil/replacement initializer results. Benchmarks print direct/callback/inactive timings for scalar, structure, and object paths without imposing machine-specific timing assertions. Allocation profiling should compare the same configuration and iteration count; process startup and one-time preparation are not per-call costs.

For device execution, invoke `runArchitectureValidation(mode: "replacement")` in the disposable host described in CONTRIBUTING. The native fixture uses the same replacement transport and checks authenticated IMP installation, scalar dispatch, callback capture release, cached calls after owner release, and consuming/nil initialization. It does not exercise the Swift typed callback frontend on the device. Use root package Simulator tests for that frontend, and report these execution scopes separately.

The `hooks` mode exercises the public typed Swift frontend in a signed host: two callbacks enter Objective-C dispatch, a saved implementation follows removal, and the saved entry remains callable after both tokens are invalidated. Run this separately from `replacement`, which checks the lower-level transport and initializer boundary.

The `initializers` mode uses the public initializer hook with a compiler-authored Objective-C factory. It checks transformed arguments, mutation of the actual initialized object, nil results, and pass-through after invalidation.

The `native-hooks` mode runs the public C++/Objective-C++ wrappers on the signed host, including saved authenticated IMPs and dedicated initializer phases.

The `coordinated-hooks` mode checks public Swift/C++ request arrays, ordinary and initializer registration, preflight failure details, and logical invalidation.

The `import-hooks` mode registers typed Swift and C++ callbacks on a compiler-created mutable import pointer. It checks cross-language order, the captured predecessor and independent logical invalidation, then verifies asynchronous monitor application to that loaded image and pass-through after invalidation. Its volatile pointer read deliberately preserves import dispatch under optimization; direct/devirtualized calls remain outside this mechanism. Subsequent-load monitoring and constructor cancellation are covered by the isolated macOS native consumers.

## Imported-function replacement probe

The `import-replacement` mode locates its own compiled `getppid` import with MachOKit, retaining the original chained-fixup metadata from the matching executable file. It checks a compiled replacement, invocation of the captured predecessor, restoration of the original pointer bits, and preservation of current/maximum page protections. A separate allocated read-only page exercises address-diversified pointer signing when compiled for arm64e. These fixture-only routines are not a public rebinding API.

TPRO-protected imports can reject `vm_protect` even when their maximum protection includes WRITE. The report distinguishes `replacement and captured predecessor passed` from `kernel refused TPRO mutation`; refusal is accepted only for the observed TPRO flag and `KERN_PROTECTION_FAILURE`, with the original state verified unchanged. A completed probe does not necessarily mean its import was writable. The allocated control must actually complete replacement and restoration.

For a comparison with legacy lazy binding, run from the repository root:

```sh
swift run --package-path Tests/ArchitectureValidation --scratch-path .build/architecture-validation -Xlinker -no_fixup_chains ArchitectureProbe import-replacement
```

The linker flag changes only the comparison fixture's binding format; it is not a consumer requirement or a way to establish support for protected imports. M5 Pro / macOS 26.6.2 runs observed refusal for the normal chained import and successful replacement for the legacy import. The signed device host can run the same mode; authenticated execution must be reported separately from macOS arm64 results.

The probe now uses the internal pointer-slot mutation transport for publication and restoration, with an independent compiler/authentication oracle. The read-only control checks unsigned storage and all four PAC keys with address diversity. An iPhone Air / iOS 27.0 arm64e host passed this control and reported unchanged TPRO-protected import storage after the expected kernel refusal. The root `PointerSlotMutationTests` additionally exercise same-page concurrency, inaccessible/executable storage, copy-on-write maximum-protection restoration, and injected VM failures through the same internal mutation sequence.

## C++ virtual-entry mutation

The `virtual-replacement` mode uses compiler-generated primary and secondary tables with receiver-adjustment and covariant-return thunks. Separate translation units preserve genuine virtual dispatch under optimization; qualified/final-class calls provide the direct-call control. The fixture compares `__builtin_get_vtable_pointer` with explicit vptr authentication, captures each predecessor using the introducing declaration's slot discriminator, and verifies shared-table scope, neighboring entries, RTTI headers and page protections after publication/restoration or refusal.

`VirtualMutationConsumer` is an optimized, test-only executable linked with `-no_data_const`. It requires successful replacement and restoration for all three cases. Ordinary architecture builds retain their normal protections and report a write refusal separately; a readable table with writable maximum protection does not establish that TPRO allows mutation. The writable control is not a package setting or a recommendation to weaken consumer protections.

The compiler probe checks inherited vptr schemas and original-declaration slot signatures for arm64/arm64e, and optionally arm64e.x1. These fixtures cover fully constructed, quiescent objects with known absolute table bounds. They do not validate construction/destruction tables, arbitrary private layouts, relative tables, or per-object shadow tables.

On iPhone Air / iOS 27.0 / arm64e, the ordinary signed host preserved all three predecessors and reported `KERN_PROTECTION_FAILURE` without publishing a pointer (TPRO flag present, protections `1/3`). A separate test-only host build with `-no_data_const` successfully replaced and restored all three entries with pointer authentication still enabled (TPRO flag absent, protections `3/3`). The host setting was restored after producing that control build. arm64e.x1 has compilation/code-generation evidence only.

The `virtual-hooks` mode exercises the internal managed transport on the same compiler tables. It covers callback order, independent and in-flight invalidation, secondary/covariant predecessors, saved callable entries, external displacement, failed preparation cleanup, and a caller-supplied keepalive joining an existing borrowed entry. `ManagedVirtualConsumer` requires a writable control and additionally combines imported and explicit virtual registrations on one C-compatible dispatch slot. Public operation-specific frontends are a separate interface layer.

The `virtual-entries` mode resolves primary, secondary and covariant entries by their source-level implementation declarations and invokes them with the original fixup authentication schema. It runs against compiler-emitted tables with normal page protections. An iPhone Air / iOS 27.0 / arm64e run passed the three named selections and their captured calls. arm64e.x1 runtime behavior remains unverified.

The `virtual-public` mode exercises the public Swift and C/C++ shared-entry APIs, including mixed registrations, secondary/covariant continuations and captured dispatchers after invalidation. On iPhone Air / iOS 27.0 / arm64e, the normal host reported TPRO refusal without mutation, and a disposable `-no_data_const` control passed all callback checks. Production link settings remain unchanged. The native consumer suite also covers the public C and Objective-C++ interfaces, including ARC capture release.

The arm64e iPhone Air writable control passed these managed cases, including allocator-backed storage with a logical pointer tag. VM region/protection operations use an untagged address; actual loads and atomic stores keep the caller's pointer tag. Normal signed-host registration reports TPRO refusal and releases its callback without changing dispatch. Published entries retain their storage/code dependencies for process lifetime; explicit keepalives supplied by later registrations can add retained owners, independently of callback capture cleanup.

## Compiled Swift replacements

`SwiftReplacementTests` runs in the Debug test harness because it inspects internal indexes; it builds optimized provider and caller dylibs from the `SwiftReplacementFixtures` and `SwiftReplacementCaller` sources. It resolves declarations through ABIBridge's source-name indexes, replaces compatible compiler-generated Swift entries through the pointer-slot transport, and restores each original representation before releasing its images. It does not install a C callback at a Swift entry point or reinterpret a capturing Swift closure as code.

| Path | Validation |
| --- | --- |
| External functions and struct methods | Separate caller/provider images; scalar, heap-backed String and 40-byte indirect results; struct receiver representation; original implementation still callable; restoration |
| Same-image functions | Ordinary linking has no replaceable import for the selected call; the `-interposable` fixture goes through a replaceable reference |
| Class metadata dispatch | Ordinary methods on one concrete nongeneric root class; declaration-to-descriptor selection; scalar, String and indirect results; captured original calls; restoration |
| Direct calls | Final methods and optimized calls on a statically known concrete instance remain outside the metadata replacement |
| Compiler dynamic replacement | A separately compiled `@_dynamicReplacement` implementation affects an instrumented `dynamic` entry, including a previously captured pointer to that entry |

The normal macOS import fixture preserves default protections and records successful restoration or TPRO refusal without mutation. Its separate `-no_data_const` control requires actual replacement. These linker options apply only to disposable fixture libraries. The test does not establish that arbitrary framework imports are writable.

The `swift-replacement` architecture mode uses the same provider/caller declarations with normal link protections. It interprets only the fixture's nongeneric, nonresilient root-class descriptor, obtains the table offset and method count from that descriptor, and selects each implementation by its source declaration. For authenticated targets, the method descriptor's extra discriminator is combined with the slot address using instruction key A. The code-generation script compares this against both the emitted metadata and the actual caller's authentication, including the hidden Swift receiver and indirect result convention.

An iPhone Air / iOS 27.0 / arm64e run passed compiled class-method replacement and restoration for scalar, String and indirect results with pointer authentication enabled and normal protections. The captured original and final-method control also passed. Xcode 26.6 code generation passed for arm64/arm64e; Xcode 27.0 additionally passed arm64e.x1 generation. These are separate observations: arm64e.x1 runtime replacement and native Swift import replacement on a device remain unverified.

This establishes a bounded candidate for compiled replacement APIs, not a general native Swift hook API. The fixture owns the object and both code images throughout mutation and restoration, and serializes mutation with its callers. Arbitrary inherited/generic/resilient/specialized metadata, consuming or coroutine signatures, async/throws, generated Swift callbacks and concurrent external writers need separate contracts. Source names and ordinary function metatypes alone do not prove identical physical calling convention or ownership. Compiler dynamic replacement requires instrumentation in the original declaration and is not a fallback for uninstrumented functions. Capturing a pointer to such an instrumented entry does not bypass that instrumentation.
