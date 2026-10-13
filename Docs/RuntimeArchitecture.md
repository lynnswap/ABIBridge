# Runtime boundaries and CI coverage

`ABIBridgeRuntime` owns runtime interpretation so environment-dependent contracts can be tested separately from the public API. Consumers use the `ABIBridge` and optional `ABIBridgeSwiftUI` products.

## Module responsibilities

```text
ABIBridgeSwiftUI
       |
   ABIBridge                 public API, formal binding, typed value adapters
       |
ABIBridgeRuntime             image lookup, metadata layouts, physical call plans
   |              |
ABIBridgeCore   ABIBridgeObjCXX
   ^              |
   +--------------+
```

`ABIBridge` also imports the native targets to submit value storage and callbacks. `ABIBridgeRuntime` does not depend on the public Swift target.

| Target | Owns |
| --- | --- |
| `ABIBridgeCore` | C/C++ and assembly call machinery, Swift runtime entry points, pointer authentication, memory access, and native image handles |
| `ABIBridgeObjCXX` | Objective-C invocation, replacement, and hook machinery |
| `ABIBridgeRuntime` | Image leases and indexes, Mach-O/shared-cache lookup, raw Swift metadata and descriptor interpretation, physical value layouts and call interfaces, native callback entry owners, and C inspection exports |
| `ABIBridge` | Public declarations and errors, formal generic binding and member selection, typed values and signatures, callback bodies, and public operation lifetimes |
| `ABIBridgeSwiftUI` | SwiftUI adapters built on the public API |

MachOKit and ObjCDump are implementation dependencies of `ABIBridgeRuntime`. Internal records and owners use `package` access; public types are declared in `ABIBridge`. The runtime target has no public product.

## Data flow and ownership

The public layer converts declaration requests to runtime records. The runtime resolves images and symbols, interprets metadata, and prepares physical call interfaces. Public adapters bind formal types and transfer Swift values through those interfaces. The runtime owns raw metadata offsets, class vtable addresses, and closure authentication discriminators.

A `RuntimeSymbolResolver` owns each resolver's indexes and image leases. `ABIRuntime` delegates lookup to it and caches typed Swift handles. Physical call interfaces and closure authentication values use bounded shared runtime caches. Public call wrappers retain the physical owners.

Async resolution, including symbols, image enumeration, C/C++ functions, Swift types and members, Objective-C messages, and named virtual entries, schedules search and call preparation on a worker while the caller suspends. Synchronous `AndWait` variants use the same indexes and call-interface caches. Neither requires `prepare`; both join only the work they need when earlier preparation is still running. Bound receivers, explicit code owners, and invocation stay in the caller's required isolation domain. Receiver-specific Objective-C dynamic resolution and forwarding-signature callbacks also stay with the caller; image acquisition and call-interface preparation run on the worker.

Compiled virtual and imported replacements offer async `prepare…` and synchronous `prepare…AndWait` planning. Both use shared lookup and capture owners without changing native pointers; publication and restoration remain explicit synchronous operations.

The public layer owns typed callback bodies; native entries retain their implementation and storage. Published code retains its native owner after cache eviction or release of a temporary public wrapper. Native registrations handle hook publication and retirement.

Conversion to `ABIResolutionError` preserves the runtime error's category and associated data. The public APIs define mutation, cleanup, and partial-failure reporting contracts.

## Tests by contract

| Target or fixture | Contract | Routine CI |
| --- | --- | --- |
| `ABIBridgeCoreTests` | Pointer mutation, partial memory reads, native resolution outcomes, Objective-C dispatch and object ownership | Four environment entries |
| `ABIBridgeRuntimeTests` | Image/symbol interpretation, metadata, physical call plans, callback allocation and ownership | The same four entries, in the same jobs |
| `ABIBridgeTests` | Public API combinations, formal binding and selection, value conversion, errors, and handle lifetimes | macOS with Xcode 27 |
| Selected `Tests/NativeConsumer` clients | External imports, C/C++/Objective-C++ headers, optimized C linkage, compiler-sensitive generic and async public entry points | macOS with both Xcodes |
| `SwiftUIConsumer` and its contract check | Public SwiftUI construction, plugin views, and ownership | macOS with Xcode 27 |
| `ABIBridgeLocalTests` | Hook timing loops and 10,000 closure handoffs | Local only |
| Full native consumers, architecture probes, and runtime benchmarks | Exhaustive combinations, generated-code checks, timing, and device-specific behavior | Local only |

See [What CI runs](../CONTRIBUTING.md#what-ci-runs) for the environment matrix. Those jobs sample compiler/OS combinations without isolating compiler changes from OS changes or covering every supported OS release. Host-compiled temporary libraries run only on macOS. SwiftUI platform builds check compilation; runtime tests do not cover its Simulator behavior or device pointer authentication.

### Compiler and runtime oracles

Runtime tests compare native calls with separately compiled Swift and Objective-C fixtures. They cover register/stack overflow arguments, direct and indirect results, managed and resilient values, typed errors, suspension, generic metadata and witnesses, class dispatch, callback entry-page expansion, and native closure retention after call-cache eviction. Metadata tests compare offsets and type identities with compiler-created values.

Focused external consumers exercise generic public declarations with explicit-value and async clients, synchronous/throwing/async hooks, and Release C inspection linkage. Both CI toolchains check public compiler workarounds.

### Functional assertions and local workloads

The Runtime and public API schemes run each bundle's tests serially because temporary library loading changes the process-wide image catalog. A concurrent image load can legitimately make a negative lookup return `imageUnavailable` while another test expects `declarationNotFound`. Serial execution keeps those fixture assumptions stable. Tests that create concurrent calls or mutations internally retain that coverage.

Public applicability tests reuse a runtime across their input cases when cache construction is not their subject. Dedicated cache and image tests retain cold lookup, invalidation, and unload/reload coverage.

The normal closure handoff test checks context identity across successive handoffs in Debug, the invocation result, and final capture release. The local suite runs 10,000 handoffs. Callback allocation tests cross a native entry-page boundary, so their allocation count is part of the contract.

Objective-C hook timing loops live in `ABIBridgeLocalTests` and run through `benchmark-runtime.sh hooks`. Short result and ownership tests belong to the public suite. The `calls` and `search` benchmarks use `Tools/RuntimeBenchmarks`.

## Commands and validation limits

Run `bash scripts/test-package.sh all` for all three package schemes, including local workloads. Use `runtime`, `api`, or `local` to select a boundary. The [contributor guide](../CONTRIBUTING.md) lists Simulator, consumer, architecture, and device commands.

Measure build time, test time, and runner minutes separately when evaluating CI cost. Local timings do not establish hosted-runner latency. Preserve a complete consumer and architecture run for changes to native conventions even though routine CI uses a focused subset.
