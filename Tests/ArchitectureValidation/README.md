# Architecture and replacement validation

This package compares compiler-generated calls with ABIBridge's invocation machinery. ABIBridge supports only arm64, arm64e, and arm64_32, so the probes and recorded runs cover those architectures. Use the [contributor guide](../../CONTRIBUTING.md) to run tests and device probes. The `replacement` mode checks the internal Objective-C callback boundary on a signed device host; public hook APIs have separate probes below.

## Full iPhone Air validation

All 38 normal device modes passed on iPhone Air with 396 reported checks. The configuration was iOS 27.0.1 (24A446), Xcode 27.0 (27A266a) / Swift 6.4, Release arm64e, CPU subtype `0x80000002`, and `pacCompiled: true`. Each mode ran in a separate launch with a newly written completed report.

After the same build passed the unmodified-pointer control, the separate `tamper` probe produced `EXC_ARM_PAC_FAIL` in `ABICopyFunctionSlotTarget`, called from `invokeAuthenticatedTarget`.

The added modes cover:

- `swift-generic-borrows` (15 checks): direct generic Bool/String calls, scoped caller-isolated callbacks, actual optional-wrapper storage, runtime-only resilient borrows, getters/methods, retained callback contexts, owned results and expired borrows.
- `method-extraction` (15 checks): v0.6.0's synchronous/async Swift, Objective-C message, C++ direct/vtable, and C/Objective-C++ captured method extraction and rebinding. Checks distinguish current Objective-C dispatch from captured implementations and verify release of original receivers and preserved native errors. The Objective-C++ probe reuses the external consumer's ownership and assignment-reentry fixtures with assertions enabled in Release.
- `image-readiness` (9 checks): a monitor registered before loading a signed caller control whose constructor delays completion. It must install after initialization without a permanent failure, preserve calls through a loaded-only suffix symlink alias, avoid repeated initialization and restore ordinary dispatch on invalidation.
- `loading` (12 checks): the existing image-acquisition probe now runs in the device host with an embedded, initially unlinked native fixture.

The native mode also covers C++ `bound_method::method()` extraction and rebinding after the original owner is released. Device reports are observations of this configuration, not minimum OS/toolchain requirements. arm64e.x1 and other unexecuted configurations still need their own runtime evidence.

## Generic declaration bindings

The `swift-generic-bindings` mode covers:

- Type construction and binding: constrained nominals, retained type arguments, dependent class/value members, associated and same-type requirements, empty and mixed packs, class-fulfilled metadata, and ordinary/existential metatypes.
- Call results and ownership: generic callbacks, async suspension, typed errors, and inout writeback. Getter controls bind one concrete error type to generic and fixed error declarations to distinguish their physical conventions.
- Witness arguments: refined, independent, and concrete member constraints, plus borrowed generic members returning through an authenticated tuple callback. AnyObject, Objective-C protocol existentials, and superclass-constrained Objective-C compositions satisfy their Swift constraints.
- Candidate selection: tuple labels and Objective-C class/protocol identities remain distinct. Inapplicable associated-type requirements and unsupported opaque candidates leave usable overloads and inherited members available. Swift, C, and block callback conventions stay distinct in argument/result selection.
- Declarations and adapters: operator lookup preserves fixity aliases, complete declarations, and independent member type arguments. Complete member, initializer, and accessor declarations preserve custom adapters at concrete type positions.
- Closure ownership: borrowed and consumed arguments retain reabstraction across sync/async calls. Initializers and setters transfer captures and release them exactly once.
- Cross-module constraints: two separately compiled modules use the same superclass constraint with and without visibility of a retroactive conformance. Explicit canonical declarations preserve successful results and typed-error outputs.

Closure packs cover per-element reabstraction, empty packs, wrapper values bound as ordinary generic elements, borrowed and owned pack arguments, retained initializer captures, async suspension, and typed-error cleanup of a partially initialized result.

On October 3, 2026, the new mode passed all 79 checks on iPhone Air / iOS 27.0.1 (24A446), using Xcode 27.0 (27A266a) / Swift 6.4, Release arm64e, CPU subtype `0x80000002`, and `pacCompiled: true`. The same build passed 16 related modes: `swift`, `swift-generic-borrows`, `method-extraction`, `swift-closures`, `swift-throwing-closures`, `swift-async-closures`, `swift-callback`, `swift-errors`, `swift-async`, `swift-arguments`, `swift-existentials`, `swift-opaque`, `swift-function-hooks`, `swift-method-hooks`, `swift-value-hooks`, and `swiftui`. These 17 modes produced 306 successful checks in newly written reports from separate launches.

The architecture package also passed all 30 parameterized macOS cases with Xcode 26.6 / Swift 6.3.3. This is runtime evidence for those configurations; the compiler probes remain separate evidence for other targets.

## Concrete Swift closure values

The `swift-closures` mode calls the public `NativeSwiftClosure` API against the separately compiled `SwiftReplacementFixtures` provider. It checks generated callbacks, native escaping storage after wrapper release, final capture destruction, returned String closures, CGRect's floating registers, typed/optional pointers, and zero-argument Void callbacks.

An iPhone Air running iOS 27.0 passed all 11 checks with an arm64e Release build from Xcode 27.0 / Swift 6.4. The report recorded CPU subtype `0x80000002` and `pacCompiled: true`. macOS arm64 runs use the same validation path. Other architecture builds are separate from runtime execution evidence.

```sh
bash scripts/build-device-validation.sh arm64e -allowProvisioningUpdates DEVELOPMENT_TEAM=<team>
```

Install the resulting host and launch it with `--probe swift-closures`, or select that mode in the app. The completed result is written to `Documents/architecture-swift-closures.json`; a leftover `started` marker does not count as a completed run.

## Objective-C replacement boundary

The package-private Swift `ObjCReplacement` and internal `ABIBridgeObjCXX/Replacement.h` entry points prepare a callable implementation without mutating a method table. The root package's `ObjectiveCReplacementTests` temporarily install that implementation on dedicated compiler-authored fixture classes. Managed registration, inheritance, and multiple-hook ordering are covered by `ObjectiveCMethodHookTests` and the public [method-hook guide](../../Sources/ABIBridge/ABIBridge.docc/ObjectiveCMethodHooks.md). Public initializer hooks are covered by `ObjectiveCInitializerHookTests` and the Swift initializer consumer; the native frontend consumers exercise C, C++, ARC/MRC Objective-C++, and mixed Swift/C chains.

The boundary keeps these contracts:

- A prepared C interface is shared immutably by invocations and retained by its libffi closure. Argument decoding reads borrowed native storage; it does not copy every incoming argument into a temporary heap buffer.
- Each call has its own result and callback frame. Swift continuations are non-Sendable views with runtime expiry/thread checks. Saving a view does not extend the native frame. This implementation requires no experimental lifetime flags or consumer `@testable` import; validation uses package access.
- A callback failure before entering the next implementation passes the original native arguments through. Once a next-call result exists, failure preserves that result instead of repeating native side effects. Declared signature/ownership correctness and no foreign exception unwinding through libffi remain caller requirements.
- Ordinary results preserve Objective-C +0/+1 conventions and explicit ownership overrides. Initializer entry handles incoming +1 self without creating a Swift reference to it, calls native initialization once, and forwards the actual +1 object or nil. Replacing self and super/nested initialization are tested independently. Explicit consumed arguments transfer through the same boundary: it owns the incoming references and supplies independent references for each native continuation. Other special lifetime methods require their own contracts.
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

For device execution, invoke `runArchitectureValidation(mode: "replacement")` in `ArchitectureTestHost`. The native fixture checks authenticated IMP installation, scalar dispatch, capture release, cached calls after owner release, and consuming/nil initialization. This mode tests the transport. Use `hooks` for device execution of the public typed Swift frontend, and root package Simulator tests for its broader coverage.

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

## Instantiated generic Swift receivers

The `swift` mode compares concrete method and getter calls on existing generic class instances with compiler calls. It covers protocol-witness context from self, complete relative declarations, a generic superclass, distinct instantiated metadata, retained calls after cache removal, and final receiver release. These calls use the existing bound Swift member APIs. Same-type constrained methods and getters are compared with compiler calls through a generic superclass, while an additional protocol-witness requirement remains an adapter case.

Run `python3 scripts/check-swift-generic-receiver-codegen.py` from the repository root to compare concrete generic members with nongeneric controls for arm64, arm64e, and arm64_32. The probe also records dependent argument/result indirection and the extra metadata argument of an independently generic method. Compilation evidence does not establish runtime behavior on an untested architecture.

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

An iPhone Air / iOS 27.0 / arm64e run passed compiled class-method replacement and restoration for scalar, String and indirect results with pointer authentication enabled and normal protections. The captured original and final-method control also passed. Xcode 26.6 code generation passed for arm64/arm64e; Xcode 27.0 additionally passed arm64e.x1 generation. arm64e.x1 runtime replacement remains unverified. Device import validation is recorded separately below.

`SwiftVirtualReplacementTests` covers declaration identity, coalesced implementations, hidden superclass names, inherited/override scope, class members' metatype entries, and initialized resilient-superclass bounds. Its final iPhone Air run passed 28 checks, including cross-module override authentication.

The fixture owns the object and both code images throughout mutation and restoration, and serializes mutation with callers. Source names and ordinary function metatypes alone do not prove identical physical calling convention or ownership. These probes do not establish general function-body interception, generic/specialized metadata handling, coroutine signatures, native async/throws, or coordination with external writers. Incoming callbacks have separate validation below.

Compiler dynamic replacement requires instrumentation in the original declaration. Capturing a pointer to an instrumented entry does not bypass it.


## Public compiled Swift import replacement

`runSwiftImportReplacementValidation()` exercises the public prepared replacement API against three separately compiled frameworks. Build them with `python3 scripts/build-swift-import-fixtures.py --output <directory> --architecture arm64e`, embed them in a host's `Frameworks` directory without linking their modules, and sign them with the host's development identity. `ArchitectureTestHost` performs this build and embedding automatically for device builds; choose its `swift-import-replacement` mode. The script accepts `--sign` for framework signing; the containing app must be signed after embedding. Use a fresh process and persist the returned report as for the other device probes.

The normal `SwiftImportCaller` keeps default protections; `SwiftImportCallerControl` uses test-only `-no_data_const`. An iPhone Air / iOS 27.0 / arm64e run reported unchanged TPRO-protected imports in the normal caller and successful scalar, heap-backed String, indirect-result and struct-context replacement in the control. Each captured predecessor and restoration passed. `SwiftImportedReplacementTests` additionally cover prior interposition, displacement, failed publication/rollback, protection-only recovery, and retained code after plan release. Releasing a prepared plan does not implicitly restore a published replacement.


## Incoming native Swift callbacks

The `swift-callback` mode exercises the internal `ABIBridge/SwiftCallbacks.h` entry boundary. It reuses the outgoing Swift register/stack lowering and remaps precompiled, signed executable pages beside writable configuration pages. Callback creation writes configuration, not machine instructions. Published code owners must outlive saved native pointers; this low-level boundary does not install or permanently retain public managed hooks on its own.

Each entry has independent argument and result storage. A successful `proceed` retains the latest native result until it is superseded or returned; assigning a replacement transfers independent native ownership. Lifecycle callbacks destroy discarded nontrivial results and consumed incoming values. Failure after a completed continuation preserves that result instead of invoking the original again. Logical invalidation releases callback captures after in-flight entries finish and leaves the code callable through its retained fallback owner.

`SwiftCallbackTests` uses separately compiled Swift callers to verify class context, scalar and String edits, mixed integer/floating arguments that spill to the stack, four-register and indirect results, imported-function entry, consuming self, continuation failure, reentrant result destruction, concurrent invalidation, wrong-thread access, Swift frame expiry, and expansion/reuse of entry pages. Code-generation checks cover arm64, arm64e and arm64e.x1 page geometry and authenticated dispatch.

An iPhone Air / iOS 27.0 / arm64e run passed generated scalar and heap-backed String callbacks, repeated continuation and result disposal, logical invalidation, restoration, and a compiler-provided indirect result. Normal link protections were retained. Stack-heavy and four-register result behavior is currently evidenced by macOS arm64 execution; arm64e.x1 runtime execution still requires matching hardware.

`SwiftImportedFunctionHookTests` covers ordinary and MainActor entry, object-reference edits, String and indirect-result ownership, zero/stack arguments, shared chains, escaped frames, external displacement, concurrent snapshots, independent capture release, additive code owners, and protection-only recovery after failed publication. The macOS suites also check generic bindings and native error propagation.

The `swift-function-hooks` device mode uses separately compiled provider/caller frameworks embedded by `ArchitectureTestHost`. Its normal caller records publication or TPRO refusal; the writable control requires actual scalar/String/indirect-result hooks and pass-through after invalidation.

`SwiftAsyncHookTests` checks suspension, cancellation and task-local values on the native task, concurrent/reentrant continuations, wrong-task and expired access, indirect results and typed errors, receiver writeback, register/stack arguments, and pass-through after descriptor invalidation. The public-product consumer runs optimized async generic imports, native errors, and virtual String methods. Runtime values, nested callbacks, and ownership use the shared plans described in the [function-hook guide](../../Sources/ABIBridge/ABIBridge.docc/SwiftFunctionHooks.md).

On October 3, 2026, `swift-function-hooks` passed 31 checks on iPhone Air / iOS 27.0.1 (24A446), using Xcode 27.0 (27A266a) / Swift 6.4, Release arm64e, CPU subtype `0x80000002`, and `pacCompiled: true`. The same build passed all 8 `swift-async` and 12 `swift-async-closures` checks in separate launches.

The hook run covered concrete scalar/String/indirect-result chains, invalidation, matching/unmatched generic substitutions, indirect class values, returned generic closure authentication, and typed native/callback errors. Async cases added mismatch pass-through, owned String results, typed failures, completed-result recovery, and MainActor resumption.

Normally linked and writable-control callers both accepted publication with normal host signing and no Enhanced Security request. This does not establish writability in other processes. arm64e.x1 execution remains unverified.

On October 4, 2026, the runtime ownership follow-up passed all 44 `swift-function-hooks` checks on iPhone Air (iOS 27.0.1, 24A446), using Xcode 27.0 / Swift 6.4 in a Release arm64e build. The ownership cases cover consuming noncopyable inputs, shared result publication, recovery before/after continuation, virtual generic methods, async suspension, object cleanup, Optional adapters, failed inout conversion, and consuming runtime closures with authenticated dispatch and capture release. Newly written completed reports recorded PAC enabled and CPU subtype `0x80000002`. The same build also passed the 83-check `swift-opaque` regression probe.

## Managed Swift class receivers

The `swift-method-hooks` host mode uses the signed provider/caller frameworks to validate typed receiver identity, property edits before and after proceeding, shared class-metadata chains, imported final methods, String getter/setter ownership, repeated/omitted consuming-self continuations, and receiver release. It also selects the same inherited entry through import metadata and class metadata, requiring one authenticated dispatcher chain, and hooks a `class func` and a `class var`'s getter and setter in a base and an overriding class. An iPhone Air / iOS 27.0.1 / arm64e run passed all 21 checks with normal host signing, including async descriptor authentication, receiver identity across suspension, typed native errors, pass-through after invalidation, and final receiver release. arm64e.x1 runtime behavior remains unverified.

`SwiftClassHookTests` covers selected-class scope, class members' metatype entries, direct-call bypass, receiver casts, MainActor/background entry, escaped receiver views, post-proceed errors without duplicate effects, and compiler escaped method names that must not be confused with initialization/deinitialization. Ordinary Swift method hooks require initialized receivers and an established signature, including errors and async isolation. Async metadata entries contain descriptors whose original context size remains available after invalidation. Property getter source spellings omit throwing effects; neither a source name nor an ordinary getter descriptor proves that effect contract.

## Managed Swift value receivers

`SwiftValueHookTests` verifies register and indirect self, original-address mutation, receiver snapshots after native writes, consuming String/reference-field ownership, independent copies for repeated continuations, omitted native calls, nonmutating setter argument ownership, indirect results, stack arguments and expired views. The representations are explicitly supplied known layouts; general nontrivial layout/destruction synthesis is not inferred.

The permanent host's `swift-value-hooks` mode passed 12 checks on iPhone Air / iOS 27.0 / arm64e: register/stack self, mutating caller storage, failure after native mutation, large indirect receivers, consuming String copies and cleanup, and snapshot reads after String mutation. The mode uses the separately compiled writable caller control and the same managed implementation as the public API. arm64e.x1 builds include the host and all fixture frameworks, while matching-device execution remains unverified.

## Swift lookup performance

Run `swift-lookup` in `ArchitectureTestHost` to measure automatic nominal-descriptor lookup and direct/inherited methods. Each operation reports its first lookup and the mean of 100 repeated lookups in seconds. Resolved methods must return the compiler fixture's expected result.

The probe clears runtime indexes between operation groups while retaining type handles. "Cold" refers to those indexes, not the OS file cache. Cross-module sequences include missing-module controls and keep indexes between successive lookups. Compare Debug and Release in fresh launches with the same toolchain, architecture, signing, and linked dependencies. Timings have no hardware-dependent pass/fail threshold.

## C and C++ lookup performance

Run `native-lookup` in `ArchitectureTestHost` to compare cold C function lookup and the mean of 100 repeated lookups, C++ member lookup, a second member of the same class, and missing C/C++ names. Successful calls must match the compiler fixture; missing names must report `declarationNotFound`. The missing-name controls exercise shared-cache fallback. As with `swift-lookup`, cold means cleared runtime indexes, and timing reports have no hardware-dependent pass/fail threshold.

The `virtual-entries` report includes 1000-lookup means for the primary, secondary, and covariant fixture entries. Each repeated selection must preserve the slot index and original authentication schema.

## Prepared invocation timing

Run `invocation-timing` in `ArchitectureTestHost` to compare prepared C scalar/pointer calls, C++ receiver calls, Swift mixed/many-argument and owned-string calls, and Objective-C scalar/object dispatch. Handles are prepared before timing; every invocation checks its result. Each report contains the mean of 100,000 calls without hardware-dependent timing assertions. Compare fresh launches of the same build configuration on the same destination; these timings include Swift marshalling and result validation, not just the native call instruction.

## Throwing Swift calls

The `swift-errors` mode exercises untyped NSError, zero-valued typed errors, floating errors, resilient errors, independent large result/error storage, and mutating receiver writeback. Launch with `--probe swift-errors` and read `Documents/architecture-swift-errors.json`. NSError lifetime checks drain their autorelease pool before asserting final release.

A Release arm64e build completed all 12 checks on iPhone Air (iOS 27, build 24A435), with CPU subtype 0x80000002 and pointer authentication compiled in. This records an executed configuration rather than an additional deployment requirement.

## Runtime-described Objective-C structures

The `objc-values` mode checks normal and captured aggregate calls with CGAffineTransform. On UIKit platforms it also checks UIEdgeInsets, NSDirectionalEdgeInsets, and an aggregate managed hook. These structures use the shared runtime type-encoding path with no library-side registration.

All 12 checks passed in a Release arm64e build on iPhone Air (iOS 27, build 24A435), with pointer authentication enabled. The expanded probe includes receiver-independent messages, explicit receiver binding and release, and observation of a managed hook installed after preparing the unbound message. The report is `Documents/architecture-objc-values.json`.

## Native Swift async calls

The `swift-async` mode exercises public async functions and members through the native transport. It verifies owned String results, caller-isolation payloads and task-local state, executor restoration, cooperative cancellation, native errors, independent indirect success/error outputs, and stack arguments.

All eight checks passed in a Release arm64e build on iPhone Air (iOS 27, build 24A435), with pointer authentication enabled. The report is `Documents/architecture-swift-async.json`. macOS tests also execute the transport on arm64; arm64_32 is separately compiled.

## Throwing Swift closure values

The `swift-throwing-closures` mode checks generated typed callbacks, zero-valued errors, independent indirect success/error outputs, returned native captures, forwarding into escaping native storage, and final capture release.

All seven checks passed in a Release arm64e build on iPhone Air (iOS 27, build 24A435), with pointer authentication enabled. The report is `Documents/architecture-swift-throwing-closures.json`. macOS tests also cover untyped and Never errors and preservation of the caller's error register by nonthrowing callbacks.

## SwiftUI views

The `swiftui` mode compares rendered Text, Image, Color, and AnyView values, an imported resilient Container<Text>, a compiled generic specialization, and private opaque View composition. It also hosts three routes (compiled host, opaque view, composed opaque view), observes state 0 and 1 through SwiftUI's graph, and checks final host/model release. Its 18 checks passed on macOS in Debug/Release and on iPhone Air (iOS 27 build 24A435, Release arm64e/PAC). Image comparisons preserve dimensions and allow only one 8-bit channel level of rasterization rounding.

The public ABIBridgeSwiftUI product replaces the prototype's retaining wrapper with NativeSwiftView. Its 22-check run adds non-View diagnostics, original-value reuse after failed conversion, copied-view ownership after releasing the original opaque result, and final model release. All 22 checks passed in macOS Debug/Release and in the iOS 27 iPhone Air Simulator. The public wrapper also builds for arm64e devices and watchOS; the initial physical-device evidence above remains the 18-check prototype run. The external consumer exercises the same public API without the provider module; its compile controls enforce MainActor construction/non-Sendable values and its native-only link control excludes SwiftUI.

The host app's **Open SwiftUI demo** button exposes the same three routes for interaction; `--swiftui-demo opaque` opens it directly (`host` and `composed` select the other routes). Increment runs through a native Swift closure and changes both the counter and red/blue panel. All three routes were exercised in the iPhone Air Simulator (iOS 27). The external SwiftUIConsumer separately compiles without the provider's module and renders its private some View result; `scripts/check-swiftui-codegen.py` records arm64, arm64e, and arm64_32 compiler evidence. These fixtures do not install SwiftUI conformances in the ABIBridge product.

## Opaque Swift results

The `swift-opaque` mode verifies hidden aligned managed results, complete metadata, protocol erasure, copied-handle lifetime, cache removal, scalar/empty opaque results, throwing completion, getters, and async suspension/cancellation. It also distinguishes class-constrained direct results from unconstrained class payloads and validates cross-module extension descriptors and authenticated protocol references. All 19 checks passed in a Release arm64e build on iPhone Air (iOS 27, build 24A435), with pointer authentication enabled. Its report is `Documents/architecture-swift-opaque.json`.

The expanded probe passed all 83 checks on iPhone Air (iOS 27.0.1, build 24A446) in a Release arm64e build. The fresh report recorded `pacCompiled: true` and CPU subtype `0x80000002`. Its scoped-result cases use actual `~Copyable & ~Escapable` compiler fixtures and cover free functions, bound members, body errors, native failure, expired views, retained inputs across async body suspension, noncopyable body output, and exact native-result destruction. `Lifetimes` is enabled only for test fixtures; consumers still match the native isolation convention explicitly.

## Swift existential values

The `swift-existentials` mode verifies Any and protocol compositions, inline/out-of-line payload ownership, class-constrained layouts, generated/returned callbacks, optional class/error authentication, and async existential results. All 14 checks passed in a Release arm64e build on iPhone Air (iOS 27, build 24A435), with pointer authentication enabled. Its report is `Documents/architecture-swift-existentials.json`.

On October 3, 2026, the expanded mode passed all 23 checks on iPhone Air / iOS 27.0.1 (24A446), built with Xcode 27.0 / Swift 6.4 in Release for arm64e (`cpuSubtype: 0x80000002`, `pacCompiled: true`). The added checks cover two parameterized class protocols, a shared inherited associated type, typed and runtime-only parameterized existential metatypes, and an authenticated metatype callback. The macOS probe also passed those 23 checks with Xcode 26.6 / Swift 6.3.3.

The generic superclass follow-up passed all 27 checks on the same iPhone Air configuration. Its additional cases cover runtime-only factories, authenticated callbacks, returned closures, and typed generic superclass metadata. A fresh `architecture-swift-existentials.json` recorded `pacCompiled: true` and CPU subtype `0x80000002` for that Release build.

## Swift argument ownership

The `swift-arguments` mode verifies typed inout storage, managed/scalar writeback on success and failure, consumed indirect-value lifetimes, mixed initializer ownership, and async suspension/cancellation. All nine checks passed in a Release arm64e build on iPhone Air (iOS 27, build 24A435), with pointer authentication enabled. Its report is `Documents/architecture-swift-arguments.json`.

## Async Swift closure values

The `swift-async-closures` mode exercises caller-isolated and concurrent generated callbacks, typed direct/indirect errors, independent owned result storage, stack arguments, returned descriptors, repeated native handoffs, escaping captures and final release, and original-task cancellation.

All 12 checks passed in a Release arm64e build on iPhone Air (iOS 27, build 24A435), with pointer authentication enabled. The report is `Documents/architecture-swift-async-closures.json`. Compiler controls distinguish the hidden actor's class authentication identity from its two-word physical isolation representation and verify both compiler-stored async body conventions.

## Private Swift receiver lookup

The `swift` mode includes file-private receiver methods, inherited private owners, complete relative declarations, getter/setter calls, cache removal, and final receiver release. Compiler calls keep the fixture entries live under optimization and provide independent controls; lookup does not reconstruct methods removed by dead-code elimination. All 15 mode checks passed in a Release arm64e build on iPhone Air / iOS 27 with pointer authentication enabled.

The package regression suite additionally distinguishes same-named private classes in different files and verifies short member labels. `SwiftMemberConsumer` obtains a private object from a separately loaded library without importing its module and invokes the retained method after its loader reference and resolver cache have been released.
