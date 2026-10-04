# Runtime boundaries and CI coverage

The runtime and test boundaries below define the migration approved for this package.

## Goal

Run environment-dependent contracts across the supported compiler and OS combinations, while testing higher-level behavior once on macOS. Preserve the public `ABIBridge` and `ABIBridgeSwiftUI` products and their source-level APIs. Keep exhaustive device, stress, and performance checks available locally.

The test boundary must follow the code that interprets a runtime or compiler convention. A test is not platform-independent merely because it lives outside a target named `Core`.

## Current boundaries

`ABIBridgeCore` implements the native call machinery, Swift runtime entry points, pointer authentication, memory access, and image ownership in C/C++ and assembly. `ABIBridgeObjCXX` adds Objective-C invocation and hooks.

The Swift `ABIBridge` target also contains environment-dependent code:

- `SymbolResolver`, `SymbolIndex`, and `SharedCacheSymbols` interpret loaded images, Mach-O data, and shared caches.
- `SwiftClassDispatch`, `SwiftNominalDescriptor`, and the metadata helpers read runtime layouts.
- `SwiftCall`, `SwiftAsyncCall`, and their plans implement physical argument, result, error, and closure conventions.
- Public generic entry points contain Swift 6.3 compiler workarounds. Those entry points still need a small compatibility check even after the runtime implementation moves.

All package tests currently share one target. The `core`, `invocation`, and `hooks` script selections are test groups, not module boundaries. Simulator CI runs the whole portable suite, and the Xcode matrix repeats both that suite and the external consumers. This does not distinguish environment contracts from API behavior or measurement workloads.

## Target structure

Keep one Swift package and the two existing library products. Add one internal Swift target, `ABIBridgeRuntime`, to own the Swift implementation of the runtime boundary.

```text
ABIBridgeSwiftUI
       |
   ABIBridge                 public Swift API and typed value adapters
       |
ABIBridgeRuntime             lookup, metadata interpretation, physical call plans
   |              |
ABIBridgeCore   ABIBridgeObjCXX
   ^              |
   +--------------+
```

`ABIBridgeRuntime` also owns the implementation dependencies on MachOKit and ObjCDump. The native targets retain their existing C/C++ headers and libffi dependency. Consumers continue selecting `ABIBridge` or `ABIBridgeSwiftUI`; the runtime target is not a new product.

Keeping these owners inside the existing Swift target would avoid an internal interface, but would not enforce the dependency direction or let runtime tests build independently of the upper test target. A separate runtime target is justified by those two requirements. Separate packages and independently versioned components are unnecessary.

### What crosses the boundary

The runtime layer accepts declaration descriptions, formal type information, and storage requirements. It returns retained image/symbol handles, metadata descriptions, and prepared call interfaces. Reuse the existing native handles and ownership helpers where possible.

The public layer adapts Swift values to those contracts and exposes the existing typed operations. It does not read metadata offsets, choose authentication discriminators, walk Mach-O data, or infer register and stack layouts.

Keep public types declared in their existing modules. Do not move them to a new module and recreate the old API with broad re-exports or aliases. Where a file combines public adapters and runtime interpretation, separate those responsibilities instead of moving the whole file. Internal declarations shared between targets use `package` access.

Runtime failures must retain their categories and associated data when mapped to public errors. Image identity, generation, retained code, and partial mutation or cleanup failures remain part of the contract.

### State and lifetime ownership

- The runtime layer owns image/symbol indexes, metadata caches, and prepared physical call interfaces. Each independent runtime has one cache owner.
- The existing public `ABIRuntime` actor delegates to that owner. It does not keep a second copy of runtime indexes.
- Public handles retain the lower-layer owners they need. Releasing a wrapper must not unload code or destroy storage still used by another handle or an in-flight call.
- Hook registration and callback lifetimes stay with the component that publishes and retires the native entry. Moving files must not create a second registration path.

### Public use remains unchanged

```swift
import ABIBridge

let decorate = try await ABIRuntime.shared.swiftFunction(
    named: "Example.decorate(_:)",
    as: ((String) -> String).self
)
let message = try unsafe decorate.unsafeInvoke("Hello")
```

The existing package in `Tests/NativeConsumer` verifies public imports and linking from outside this package. It remains the consumer fixture; no new public runtime API is required for tests.

## Tests by contract

Create separate test targets and schemes so a runtime-only run does not compile the entire API test bundle. Assign cases individually when an existing suite mixes responsibilities.

| Test target or fixture | Contract | Routine CI |
| --- | --- | --- |
| `ABIBridgeCoreTests` | Native storage, dispatch, memory, image ownership, and native callback entry behavior | macOS and iOS on the 26/27 environment pairs |
| `ABIBridgeRuntimeTests` | Swift metadata, symbol/image interpretation, physical ABI plans, runtime errors and ownership | macOS and iOS on the 26/27 environment pairs |
| `ABIBridgeTests` | Public API combinations, selection policy, value adapters, error mapping, and handle lifetimes using established runtime contracts | macOS with Xcode 27 once |
| `ABIBridgeSwiftUITests` | SwiftUI wrapper behavior and ownership | macOS with Xcode 27 once; retain a small UIKit-host integration check where macOS cannot exercise the contract |
| Selected existing external consumers | Public product imports, C/C++ header linkage, optimized entry-point linkage, and compiler-sensitive generic entry thunks | Focused checks with both Xcodes |
| Existing benchmarks and expanded architecture probes | Timing, long repetition, full integration combinations, and physical-device authentication | Local validation, outside routine CI |

Both lower test targets run together in one job per environment. They do not each get a separate runner. The intended matrix has four entries: macOS/Xcode 26.6, iOS Simulator/Xcode 26.6, macOS/Xcode 27.0, and iOS Simulator/Xcode 27.0. Run the upper tests in the macOS/Xcode 27 job after the lower contracts, reusing build products. Keep device-SDK compilation for iOS, visionOS, watchOS, and tvOS on one toolchain.

This matrix samples OS and toolchain combinations; it does not independently isolate compiler changes from OS changes, validate every supported OS release, or verify physical-device PAC behavior. Cross-compilation probes and matching-device tests keep their separate roles.

### Runtime cases

Preserve compiler-authored oracles for each implemented signature family: register/stack boundaries, direct/indirect results, managed and resilient values, generic metadata and witnesses, synchronous/throwing/async calls, closures, and receiver conventions. Preserve platform-specific image acquisition and runtime permission/failure cases.

Check the compiler-sensitive public thunks in the small external consumer set. The runtime layer cannot absorb every compiler code-generation difference in a generic public declaration, so removing all upper-layer checks from the older compiler would leave a gap.

A large case count alone is not a coverage criterion. Each matrix case must identify the environment-sensitive contract and the incorrect result, ownership change, or failure it would detect.

### Upper-layer cases

Use fixed, compiled fixtures for tests of selection, conversion, and error propagation. Reuse setup within a test when independent caches are not the behavior under test. Keep cache invalidation, unload/reload, and unrestricted discovery in dedicated integration cases.

For example, `mismatchedConstraintsRemainAbsent` constructs a new `ABIRuntime` for each of six inputs; `dependentConstraintsUseRuntimeConformancesAndSubstitution` does the same for four inputs. Their assertion concerns generic applicability, not rebuilding indexes for every input. Preserve those input combinations while separating the cold-lookup checks.

Use the real lower layer for integration checks. Where a pure policy test needs controlled input, replace the lower symbol/image source or use immutable fixture metadata; do not introduce a second implementation of the public data flow.

### Stress and performance cases

Move timing loops such as `managedEntryBenchmark` and `replacementEntryBenchmark` to the existing benchmark tooling. Keep their ownership and result assertions as short functional tests.

Keep allocation-boundary cases where the count has a purpose. For example, the callback-page expansion test deliberately crosses an entry-page boundary. Do not replace it with a small arbitrary count. Long closure handoff tests should preserve a direct check that forwarding does not accumulate wrappers; larger repetitions can remain local stress checks.

The slow iOS cases already inspected are largely ordinary lookup/constraint tests, so moving benchmark loops alone will not solve the CI cost. Measure setup, resolution, invocation, and teardown separately before claiming a speedup.

## Migration and removal

1. Extract image/symbol and metadata interpretation into the runtime target, keeping one owner for caches and leases. Move the corresponding contract tests at the same time.
2. Separate physical call plans from public typed adapters. Migrate native and Swift runtime checks, and retain focused public-consumer checks for the generic compiler boundary.
3. Divide the remaining tests by contract, move timing/stress workloads out of routine CI, and update the workflow and contributor commands.

Each migration unit must build and pass its focused tests before the next unit starts. Remove the moved implementation from its old location in the same unit. Replace the current broad `core`/`invocation`/`hooks` CI selections with the new test targets once every existing case has a destination. Preserve an explicit local command for the complete suite.

Do not add a legacy implementation, duplicate caches, or a generic shared context that lets the upper layer reach back into the old state. Keep native ABI and public Swift names stable within the required source contract.

## Acceptance checks

- Public usage, errors, ownership, callback cleanup, and partial-failure behavior remain equivalent.
- The runtime target has no dependency on the public `ABIBridge` target. Upper code no longer interprets the runtime layouts assigned to the lower layer.
- Every existing test is retained, replaced by a more direct assertion of the same contract, or moved to an explicit local suite with a stated reason.
- `xcodebuild test` uses a named scheme and destination for each test target. Separate schemes avoid rebuilding the whole API test target for a runtime-only run.
- Validate the product graph with `swift package dump-package` and run existing external consumers, including the optimized linkage check.
- Compare runner minutes, build time, test time, and the longest individual cases against the current workflow. Local timings explain behavior but do not establish hosted-runner latency.
- Complete `codex-review` before publishing the implementation changes.
