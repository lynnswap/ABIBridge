# Contributing

Use Xcode with Swift 6.3 or later. Keep changes on a topic branch and open a pull request against `main`.

## Validation

Check the package manifest and whitespace:

```sh
swift package dump-package
git diff --check
```

Run tests on macOS:

```sh
xcodebuild test \
  -scheme ABIBridge \
  -destination 'platform=macOS,arch=arm64'
```

CI runs the package in three independent processes. Use the same selections locally:

```sh
bash scripts/test-package.sh core
bash scripts/test-package.sh invocation
bash scripts/test-package.sh hooks
```

Each command has a separate default build directory under `.build/package-tests`, so they can run concurrently. `ABI_TEST_BUILD_DIR` selects a cache location; do not share it between simultaneous builds. Additional arguments are forwarded to `xcodebuild`. Use `all` for the full suite.

The core shard is the complement of the explicit invocation/hook suite lists, so new or otherwise unassigned tests remain covered automatically. Keep those lists disjoint when moving suites. Existing suite serialization and intentional concurrency inside tests are preserved. CI retains failing shard test logs and result bundles for seven days; the test step has its own timeout so diagnostic upload can run before the job limit.

Verify the native bridge in an optimized build as well:

```sh
xcodebuild test \
  -configuration Release \
  -scheme ABIBridge \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ABIBridgeTests/NativeRuntimeTests
```

This checks that the C entry points remain externally linkable after Xcode combines the optimized package objects. CI runs the same check.

The symbol tests compile temporary C++ libraries with the installed Xcode toolchain. They test real symbol lookup, image retention, and unload/reload behavior. Objective-C invocation tests use Swift and Objective-C fixtures to check typed arguments, forwarding, caller isolation, returned-object ownership, initializer behavior, and signature failures. Typed C/C++ invocation tests additionally cover standard C value layouts, twelve mixed arguments, optional pointers, concurrent handle reuse, and invocation after the original loader reference is released. Swift invocation tests compare normal calls with dynamically resolved calls for mixed register/stack arguments, ownership, integer-field coalescing, four-register results, and indirect results. Guarded argument/result pages verify that coalesced registers do not read or write beyond an odd-sized value's allocation. Native value tests cover custom wrappers, runtime signatures, borrowed/adopted ownership, failed conversions, field views, unaligned reads, and invalid layouts.

Debug-only `ImportIndexTests` cover the internal read-only import index with compiled C/C++ and Swift references, legacy/chained metadata, weak and lazy slots, reexports, addends, zero-fill file/VM offset differences, universal slices, missing/replaced metadata, and retained image generations. Name lookup and file parsing do not establish a signature, a currently resolved lazy target, or writable memory. Optimized shared-cache metadata, threaded bind opcodes, and multi-start overflow chains that the current parser cannot recover return metadata errors; indirect-table-only records retain an unknown authentication schema.

`ImportedFunctionHookTests` cover typed imported callbacks, cross-owner ordering, scoped continuations, original Swift errors, side-effect-preserving recovery, saved callable entries, in-flight invalidation, external displacement and partial rollback/retry. The C/C++ and Objective-C++ import consumers exercise the same registry through public headers. The isolated C++ import consumer also verifies import-selection retention after cache clearing, final image release, and fresh metadata after reloading into a new generation. The architecture fixture's `import-hooks` mode checks the public Swift/native frontends on an arm64e device; `import-replacement` separately measures TPRO refusal and authenticated pointer mutation.

`ImageObservationTests` exercise the internal asynchronous catalog boundary: initial snapshots, unload/reload generations without image retention, loader/catalog reentry, self-invalidation, constructor cancellation during an in-flight callback, and context release. Notifications are coalesced current-state snapshots; they do not establish interception before image initializers run.

`ImportedFunctionMonitorTests` cover current/future application, per-image failures, inactive monitors and in-flight callback/error lifetimes. The isolated C++ and Objective-C++ monitor consumers verify that no-match generations can unload/reload without accumulating state, and that a constructor can reenter the catalog and cancel monitoring while another thread loads its image.

Memory tests verify owned copies, region bounds, unaligned reads, zero-length requests, inaccessible source addresses, and readable prefixes before protected pages. The C, C++, and Objective-C++ consumers exercise the shared reader, including owner release and ARC/MRC builds. Runtime evidence is from macOS; other Apple platforms compile in CI.

The internal pointer-slot tests verify atomic expected-value replacement, preservation of competing writers, data-page protection restoration, copy-on-write maximum protections and shared-page serialization. A VM fixture injects publication and cleanup failures into the production mutation sequence and checks that both restoration errors and partial effects remain observable. This is an internal prerequisite for managed rebinding; it does not own callback/code lifetimes or synchronize with external VM operations.

Pointer discovery tests cover shifted fields, cached-offset revalidation, aliases versus distinct targets, incomplete scans, packed slots, explicit vptr offsets, retained owners, and feeding a selected receiver to existing C++ invocation. Native consumers additionally exercise guarded source slots and PAC-bearing data in plain arm64 builds. Compile the scanner for arm64e as well; this is not a physical-device authenticated-dispatch test.

Run the native backend fixtures to verify linking and ABI behavior through the `ABIBridge` product:

```sh
bash scripts/test-native-consumer.sh
```

The C and Objective-C++ inspection consumers include only the public inspection header and verify source-level vtable/data resolution, snapshot paths, independent loader leases, owned errors, and symbol lifetime after releasing the original loader and runtime references. The script also checks the C consumer as strict C11. The C++ inspection consumer exercises wrapper copy/move, independent leases, copied snapshot descriptions, owned exceptions, and shared-runtime access. The hook consumers additionally cover C11, pure C++, ARC/MRC Objective-C++, and mixed Swift/C registration on shared method/initializer chains, including context cleanup, failure recovery, handle copies, and live invalidation. Coordinated-installation fixtures also trigger an external IMP writer during activation to check partial rollback and preservation of earlier owners. Two Objective-C++ inspection consumers verify C++ handle destruction in ARC and manual-reference-counted objects. The remaining backend fixtures check C/C++ calls, instance methods, receiver ownership, multiple-inheritance subobjects, reference arguments, non-trivial and indirect results, register/stack argument passing, concurrent resolution, and image retention after the original loader reference is released. Objective-C++ consumers additionally check selector signatures, ARC and manual-reference-counting lifetimes, initializer ownership, and block arguments/results. The dynamic C consumer checks libffi-backed calls with zero and twelve arguments, narrow scalar results, pointers, nested aggregate layouts and returns, retained type descriptions, and concurrent preparation/invocation. Separate Swift consumers link the public product and verify initializer-hook argument transformation, nil/result ownership, absence of uninitialized-self retains with an MRC fixture, C/C++ calls, custom values, direct/virtual receiver calls, and image retention after releasing the original loader reference. C++ object tests cover explicit secondary-subobject views, borrowed result lifetime, nontrivial-value adapters, and bounded vtable access. Authentication code is additionally compiled for arm64e and compared with fixture-generated discriminators; this does not replace PAC runtime testing on a device. The Swift function and member consumers build a separate Swift library and call it after releasing the original loader reference. Member tests cover nominal metadata caching, generic metadata rejection, class/value/enum receivers, inherited implementations, initializer/setter ownership, static properties, and writeback after conversion failures. CI runs these consumers after the macOS package tests.

Build for another Apple platform by changing the generic destination:

```sh
xcodebuild build \
  -scheme ABIBridge \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

For watchOS, add `WATCHOS_DEPLOYMENT_TARGET=11.4` so dependencies also build within the supported deployment range. CI uses Xcode 26.6 on `macos-26` for macOS tests and iOS, visionOS, watchOS, and tvOS builds. Three package test shards, optimized bridge tests, native consumers, and architecture validation run as six independent macOS jobs. Each owns its build directories; PR and release validation require every job to succeed. Release targets that predate the shard script run the original full package suite in the core job.

## Managed Swift value prototype

`ManagedSwiftValueTests` uses the public C frontend and NativeValue storage with separately compiled Swift adapters. The fixture module enables library evolution; the adapter module imports it, so resilient calls exercise a real cross-module boundary. The fixtures cover managed structs, value Optionals, copied/moved storage, runtime-only handles, and failed conversions. Neither fixture target is part of the ABIBridge product.

Run the runtime checks in both configurations:

```sh
xcodebuild test -scheme ABIBridge -destination 'platform=macOS,arch=arm64' \
  -only-testing:ABIBridgeTests/ManagedSwiftValueTests
xcodebuild test -scheme ABIBridge -destination 'platform=macOS,arch=arm64' \
  -configuration Release -only-testing:ABIBridgeTests/ManagedSwiftValueTests
python3 scripts/check-managed-swift-codegen.py
```

The compiler probe emits LLVM IR and a report under `.build/managed-swift-codegen`. It compares direct frozen/Optional results with resilient indirect results and compiler-generated value operations on arm64, x86_64, arm64e, and arm64_32. The native-consumer CI job runs this probe; the invocation shard runs the runtime tests. A compilation check does not establish runtime support on that target. See the managed Swift values DocC guide for the supported adapter contract.

## Swift generic metadata prototype

`SwiftGenericMetadataTests` verifies the compiler-adapter route for a known generic nominal declaration and existing protocol conformances. It checks canonical metadata identity, conditional conformance success/failure, managed/resilient substitutions, generic result ownership, and untouched output on rejection. Run this suite in Debug and Release with the same scheme/destination above. `scripts/check-swift-generic-codegen.py` records hidden metadata and witness arguments plus indirect value lowering on four architectures. `SwiftGenericConsumer` loads separate provider/adapter libraries without importing their types and destroys the value after the lookup runtime and original loader reference end. These fixtures do not enable general direct generic invocation; see the generic Swift values DocC guide.

## Swift closure ABI fixtures

`SwiftClosureABITests` compares concrete Swift calls with compiler-authored C adapters using the same managed fixture modules. It covers noncapturing/capturing inputs, nonescaping use, a callback retained by its native callee, returned callbacks after their output storage is released, and explicit Sendable/MainActor signatures.

```sh
xcodebuild test -scheme ABIBridge -destination 'platform=macOS,arch=arm64' \
  -only-testing:ABIBridgeTests/SwiftClosureABITests
xcodebuild test -scheme ABIBridge -destination 'platform=macOS,arch=arm64' \
  -configuration Release -only-testing:ABIBridgeTests/SwiftClosureABITests
python3 scripts/check-swift-closure-codegen.py
```

The compiler probe records SIL and LLVM IR under `.build/swift-closure-codegen` for the same four architecture targets as the managed-value probe. An unoptimized build preserves the concrete-to-generic and generic-to-concrete reabstraction boundaries for inspection. It verifies the native closure's two-word result and the generic callback's indirect argument/result plus hidden context. The invocation shard and native-consumer CI job run the runtime and compiler checks respectively.

These fixtures establish the compiler-adapter boundary. `NativeSwiftClosureTests` additionally verifies the public closure-value bridge, built-in value roundtrips, type discriminators against compiler-generated arm64e calls, escaping/returned ownership, and failed conversions. `SwiftClosureConsumer` exercises the public product after releasing its lookup runtime, factory handles, and original loader reference. A C-only image with the compiler fixture's Swift calling convention verifies that an escaping native copy retains its code image and that final release permits unloading. The `swift-closures` architecture mode covers signed-device execution. A generic function value's two words cannot be copied into a concrete callback parameter without establishing its invocation convention. Likewise, a C symbol does not carry an actor or Sendable contract: the MainActor fixture is invoked from an explicitly isolated test, and no actor hop is inferred from lookup.

## Architecture validation

`SwiftIndirectValueTests` covers explicit opaque Swift conventions for small resilient values, their members/initializers, and concrete generic callback identities across integer, floating, and managed substitutions. Nested and Unicode nominal names are exercised without caller-written mangling. `scripts/check-indirect-swift-value-codegen.py` verifies the same conventions on four architectures. The architecture package's separate `SwiftValueFixtures` target enables library evolution so the device caller crosses a real resilient boundary without changing the existing replacement fixtures' ABI. The `swift-closures` mode validates authenticated resilient and generic callbacks and returned closures.

`SwiftExplicitValueTests` checks compiler-managed fixed struct/enum layouts through `ABIBridgeSwiftValue`, including reference/floating components, tagged payloads, indirect large values, returned callbacks, and member ownership. `scripts/check-explicit-swift-value-codegen.py` compares lowering on four architectures; enum payloads split into pointer-width integer components on arm64_32. Swift storage size/alignment remains separate from the component descriptor, so natural C tail padding is not transferred as live Swift bytes. The external `SwiftExplicitValueConsumer` and signed `swift-closures` mode exercise the public conformance and native callbacks.

`SwiftCollectionValueTests` covers direct Array and optional String/Array calls, members and initializers, copy-on-write, element ownership, later conversion failure, and capturing/returned callbacks. Array element storage can contain types outside the direct-call subset. The closure authentication test compares these nominal identities with arm64e compiler calls. `scripts/check-swift-collection-codegen.py` records the physical argument/result lowering for arm64, x86_64, arm64e, and arm64_32; the native-consumer script runs it and exercises collection callbacks from an external package. The `swift-closures` device mode includes authenticated Array and optional String/Array calls.

Run the focused consumer fixtures on macOS:

```sh
cd Tests/ArchitectureValidation
xcodebuild test -scheme ArchitectureValidation-Package -destination 'platform=macOS,arch=arm64'
```

From the repository root, compare compiler-generated calls with the Swift trampoline:

```sh
python3 scripts/check-architecture-codegen.py
```

The default checks arm64 and arm64e with the selected Xcode. With Xcode 27, add `--architectures arm64 arm64e arm64e.x1`. Objects, disassembly, and a report preserving raw CPU subtype bits are written under `.build/architecture-codegen`; no cross-compiled code is executed. CI runs the baseline checks with Xcode 26.6.

For device tests, open `ABIBridge.xcworkspace`. The shared `ABIBridge` and `ArchitectureValidation` schemes run package tests; `ArchitectureTestHost` builds the iOS app in `Tools/ArchitectureTestHost` with the local `ArchitectureValidation` product. Select your development team on the app target and a connected device, then Run. The host runs in Release, matching the optimized device probes; the package test schemes retain Debug. The project contains no development team or provisioning profile. Choose a probe in the app; the JSON result is saved to `Documents/architecture-<mode>.json` and can be shared from the result view. In Edit Scheme → Run → Arguments, `--probe swift-callback` runs that probe on launch. Use separate launches when comparing probe results.

For a specific device ABI, use the build helper so the architecture applies to the app **and every package dependency**:

```sh
bash scripts/build-device-validation.sh arm64e \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates
```

It accepts `arm64`, `arm64e`, and `arm64e.x1`, plus additional `xcodebuild` options. Select a toolchain that supports the requested architecture with `DEVELOPER_DIR`; arm64e.x1 requires Xcode 27 or later and the Swift build-service fix tracked in #103. Use `ABI_VALIDATION_CONFIGURATION=Debug` for an unoptimized diagnostic build. The `swift-lookup` probe measures cold and repeated Swift descriptor/member resolution. `native-lookup` measures C/C++ function/member and missing-name searches. Compare their reports from Debug and Release in fresh app launches. For compilation without signing, pass `CODE_SIGNING_ALLOWED=NO`. Products are under `.build/device-validation/<architecture>/Build/Products/Release-iphoneos`; build output and Xcode user settings are ignored. A successful build does not establish execution on matching hardware. Use an arm64e.x1-capable device for its runtime checks, and enable Enhanced Security/hardware memory tagging with a compatible provisioning profile when testing that environment. The standard host does not request those capabilities.

The app reuses the standalone architecture probes, including `native`, `swift`, `ffi`, `memory`, and the hook/replacement checks documented below. Reports preserve the loaded fixture image's raw CPU type/subtype, pointer-authentication compilation mode, completed checks, and observed allocation tag. The app writes a start marker before entering the probe and replaces it with the completed report or failure; a crash leaves only the start marker. TPRO refusal can be an expected, explicitly reported outcome and must not be described as successful mutation. Device builds also compile and embed three small Swift provider/caller frameworks without linking them; `swift-function-hooks`, `swift-import-replacement`, `swift-method-hooks`, and `swift-value-hooks` use those fixtures. Only the caller control is linked with `-no_data_const`. These modes are omitted from the Simulator picker. The host's fixture build phase compiles and signs the frameworks using Xcode's current architecture and identity; user-script sandboxing is disabled on this development host so the compiler and signing tools can access their SDK caches and signing services.

The `tamper` mode is deliberately absent from the picker. Run it with `--probe tamper` as a separate launch, after `native` has passed its unmodified-pointer control with `pacCompiled: true` in the same build. Both controls use the same call path and the compiler's discriminator for `void(void)`. Tamper mode intentionally corrupts a signature; success requires a crash report showing an authentication failure in the expected helper. A generic crash, a returned error, or lack of a completion marker is not sufficient. On a build without pointer authentication the control reports that it is unavailable. Keep credentials, provisioning profiles, and device identifiers out of the repository.

The host executable is also available with `swift run --package-path Tests/ArchitectureValidation --scratch-path .build/architecture-validation ArchitectureProbe <mode>`. The public architecture guide in DocC records execution evidence separately from compilation and outstanding hardware validation.

The `replacement` mode validates the internal Objective-C callback entry and initializer ownership, including saved signed IMPs after callback-owner release. The [architecture validation guide](Tests/ArchitectureValidation/README.md) documents this boundary and the root package's typed callback tests; the `hooks` mode additionally tests public typed Swift registration, chaining, and saved-implementation lifetime. The `initializers` mode checks public initializer argument transformation, actual-result mutation, nil results, and invalidation.

The `virtual-replacement` mode checks bounded C++ primary/secondary entries, receiver-adjustment and covariant-return thunks, compiler vptr authentication, and pointer/page restoration. Normal architecture builds report protected-table refusal separately from successful mutation. The native consumer suite includes an optimized `VirtualMutationConsumer` linked as a writable test control; this link setting applies only to that test executable. The code-generation script compares vptr and slot discriminators with compiler-emitted authentication for arm64, arm64e and optional arm64e.x1.

The `virtual-hooks` mode tests the internal managed-entry transport, including shared callback order, secondary/covariant predecessors, in-flight invalidation, saved entries, external displacement, and caller-owned storage lifetimes. `ManagedVirtualConsumer` requires writable-control success and verifies that imported and explicit virtual registrations share one physical chain. Tagged-address regression coverage keeps VM metadata addresses separate from the original pointer used for memory access.

The `virtual-entries` mode resolves primary, secondary and covariant entries by their source-level implementation declarations and invokes them with the original fixup authentication schema. It runs against compiler-emitted tables with normal page protections. An iPhone Air / iOS 27.0 / arm64e run passed the three named selections and their captured calls. arm64e.x1 runtime behavior remains unverified.

The `virtual-public` mode exercises the public Swift and C/C++ shared-entry APIs, including mixed registrations, secondary/covariant continuations and captured dispatchers after invalidation. On iPhone Air / iOS 27.0 / arm64e, the normal host reported TPRO refusal without mutation, and a disposable `-no_data_const` control passed all callback checks. Production link settings remain unchanged. The native consumer suite also covers the public C and Objective-C++ interfaces, including ARC capture release.

For automatic-loading validation on a device, build the standalone `ABIBridgeLoadingFixture` dynamic product from the same package and embed/sign `ABIBridgeLoadingFixture.framework` in a separately configured host's `Frameworks` directory without linking it. Call `runImageLoadingValidation()` in a fresh process. This extra embedded-fixture mode is separate from the standard host picker. It checks the unloaded starting state, loaded-only behavior, framework acquisition, constructor execution, absolute-path/install-name identity, and retained calls after cache clearing. This host links ABIBridge into the app image or its adjacent debug dylib, so the test's `@loader_path/Frameworks` spelling has a defined base. An iPhone Air / iOS 27.0 arm64e run with Enhanced Security passed these checks; this does not establish the same runtime permissions for other devices or libraries.

The native consumer script includes a separate `@rpath` fixture that reenters the resolver from its constructor and performs concurrent acquisitions. macOS package fixtures also verify missing-dependency failures, retries, framework-name ambiguity, local symbols, Swift metadata, and refreshed batch scopes. The C symbol-resolution functions now take a loading-policy argument; update direct C calls along with the `ABISymbolRequest` layout when building against the new headers.

The `swift-replacement` architecture mode validates compiled native Swift class replacements, including authenticated metadata slots and owned/indirect results. Root `SwiftReplacementTests` additionally cover separate-image imports, same-image interposable controls, direct/devirtualized boundaries and compiler dynamic replacement. See the [architecture validation guide](Tests/ArchitectureValidation/README.md#compiled-swift-replacements) for the tested subset and platform evidence.

## Documentation

The supported consumer interfaces are the Swift `ABIBridge` module and the native headers documented in the DocC consumer guides, all linked through the `ABIBridge` product. Other native headers remain implementation details. SwiftPM may make transitive modules importable; that does not make their entire contents supported public API.

Describe public Swift API contracts in DocC comments. Put guides in the DocC catalog and keep the README at installation and quick-start level. Write prose without manual line wrapping.

Build the same static site that is published by CI:

```sh
bash scripts/build-documentation.sh
```

The default output is `.build/documentation`. Optional arguments select the output directory and hosting base path. The script validates ABIBridge's catalog with DocC warnings treated as errors, while dependency documentation warnings remain separate.

Pushes to `main` build and deploy the site to GitHub Pages. Pull requests run the package CI without a documentation job.

## Releases

The Release workflow validates an approved commit with the same CI used for pull requests, then publishes its draft automatically. Failed or cancelled validation leaves the draft unpublished. This Swift package is distributed through its Git tag and GitHub's source archives; there are no separately uploaded binary assets.

After reviewing the version, title, notes, full target commit SHA, and automatic publication plan, use Python 3, Git, and an authenticated GitHub CLI:

```sh
python3 scripts/release.py start v0.1.0 \
  --repo lynnswap/ABIBridge \
  --target <full-40-character-commit-sha> \
  --notes-file /path/to/release-notes.md
```

Replace the example version and target with the approved values. The title defaults to the version; use `--title` to set it explicitly or `--prerelease` for a prerelease. Authentication needs permission to create releases and dispatch workflows. The Release workflow must already exist on `main`. Merely saving a draft in the GitHub UI does not start Actions.

The command creates a draft pinned to the full SHA, or reuses an existing draft only when its target and content match. It then dispatches `release.yml` from main with the draft ID, target SHA, and content fingerprint. It reports the draft URL and dispatch acceptance; it does not wait for publication. The workflow checks out the target SHA for package tests and all four device-platform builds. Only the final job has publication permission, and it executes the release script from the workflow's main commit.

The publish job uses the repository's `GITHUB_TOKEN` by default. For arbitrary historical commits, configure the optional Actions secret `RELEASE_TOKEN` with a fine-grained PAT scoped to this repository and **Contents: write** plus **Workflows: write** (or a classic token with `repo` and `workflow`). GitHub can reject tag creation with the default token when the target's workflow files differ from current branch tips. The custom credential is used only in the publish step; tests receive no release secret. If that permission restriction occurs, the draft remains unpublished: configure the credential and rerun the failed publish job, keeping the same approved SHA. Repository tag rules still apply. See [GitHub's reference-creation permissions](https://docs.github.com/en/rest/git/refs#create-a-reference).

Do not edit the draft, upload assets, or move its tag while checks run. The workflow rejects uploaded assets and verifies the title, notes, prerelease state, tag name, and target again before publication. The publication request explicitly supplies those approved fields, so an intervening draft edit cannot substitute different release metadata. GitHub does not provide a transaction spanning tag references, release assets, and release publication; maintainers must serialize those external operations. A missing tag is created at the tested SHA only after checks pass; an existing lightweight or annotated tag must resolve to that SHA. Publication preserves the supplied notes and prerelease state. Stable releases use GitHub's legacy latest-release selection; prereleases are not marked latest.

If dispatch fails or its response is uncertain, inspect the Actions page before rerunning the same command, since GitHub may already have accepted it. Repeating the command reuses a matching draft. For a failed workflow, use GitHub's re-run controls after addressing the failure. A failed publication can leave the correct tag alongside a draft; rerunning the failed publish job resumes without moving the tag. A retry after successful publication is a no-op. Changed draft content needs a newly reviewed command matching that content; old workflow runs will not publish it.

Run the release protocol tests locally without creating any GitHub resources:

```sh
python3 -m unittest discover -s scripts -p 'test_release.py' -v
actionlint
```

## Pull requests

Keep each pull request independently buildable and link its issue. Include the behavior changed, relevant validation, and any unverified runtime behavior.
