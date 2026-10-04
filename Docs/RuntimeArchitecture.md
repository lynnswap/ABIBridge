# Runtime boundaries and CI coverage

ABIBridge keeps runtime interpretation in an internal Swift target so its environment-dependent contracts can be tested without building the public API test bundle. Consumers still select the `ABIBridge` and `ABIBridgeSwiftUI` products and import the same public modules.

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

The native targets retain their existing C/C++ headers. `ABIBridge` also imports these targets where its adapters submit storage or callbacks through the native interfaces. The diagram shows responsibility and dependency direction; the runtime target does not depend on the public Swift target.

| Target | Owns |
| --- | --- |
| `ABIBridgeCore` | C/C++ and assembly call machinery, Swift runtime entry points, pointer authentication, memory access, and native image handles |
| `ABIBridgeObjCXX` | Objective-C invocation, replacement, and hook machinery |
| `ABIBridgeRuntime` | Image leases and indexes, Mach-O/shared-cache lookup, raw Swift metadata and descriptor interpretation, physical value layouts and call interfaces, native callback entry owners, and C inspection exports |
| `ABIBridge` | Public declarations and errors, formal generic binding and member selection, typed values and signatures, callback bodies, and public operation lifetimes |
| `ABIBridgeSwiftUI` | SwiftUI adapters built on the public API |

MachOKit and ObjCDump are implementation dependencies of `ABIBridgeRuntime`. Internal Swift records and owners cross the boundary with `package` access. Public types remain declared in `ABIBridge`; the package does not expose a new runtime product or recreate public types through re-exports.

## Data flow and ownership

The public layer converts declaration requests to runtime records. The runtime resolves retained images and symbols, interprets metadata, and prepares physical call interfaces. Public adapters bind formal types and transfer typed Swift values through those interfaces. Raw metadata offsets, class vtable addressing, and closure authentication discriminators belong to the runtime layer.

A `RuntimeSymbolResolver` owns each resolver's indexes and image leases. `ABIRuntime` delegates lookup to that owner and keeps its separate cache of typed Swift handles. Physical Swift call interfaces and closure authentication values use bounded shared caches in the runtime target. Upper call wrappers retain those physical owners; they do not duplicate the physical interface cache.

Native callback entries retain the implementation and storage they need. The public layer supplies the callback functions and owns their typed bodies. Published native code continues to retain its lower owner after cache eviction or release of a temporary public wrapper. Hook publication and retirement keep their existing native registration path.

Runtime errors preserve their category and associated data when the public layer converts them to `ABIResolutionError`. Mutation, cleanup, and partial-failure reporting keep their existing contracts.

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

The four runtime entries are macOS and iOS Simulator with Xcode 26.6, and macOS and iOS Simulator with Xcode 27.0. Core and Runtime run together under the `ABIBridgeRuntime` scheme. The macOS/Xcode 27 job then runs the `ABIBridge` scheme in the same build directory. Device-SDK builds for iOS, visionOS, watchOS, and tvOS run once with Xcode 27.

These entries sample compiler/OS combinations. They do not isolate compiler changes from OS changes, cover every supported OS release, or verify physical-device pointer authentication. Host-compiled temporary libraries run only in the macOS runtime suite. SwiftUI Simulator behavior is not covered by a runtime test; its Apple platform builds check compilation.

### Compiler and runtime oracles

Runtime tests compare native calls with separately compiled Swift and Objective-C fixtures. They cover register/stack overflow arguments, direct and indirect results, managed and resilient values, typed errors, suspension, generic metadata and witnesses, class dispatch, callback entry-page expansion, and native closure retention after call-cache eviction. Metadata tests compare offsets and type identities with compiler-created values.

The focused external consumers retain the checks that cannot move below a generic public declaration. They compile Swift explicit-value and async clients, run generic synchronous/throwing/async hooks, and link C inspection code in Release. Public compiler workarounds therefore remain exercised by both toolchains.

### Functional assertions and local workloads

The Runtime and public API schemes run each bundle's tests serially because temporary library loading changes the process-wide image catalog. A concurrent image load can legitimately make a negative lookup return `imageUnavailable` while another test expects `declarationNotFound`. Serial execution keeps those fixture assumptions stable. Tests that create concurrent calls or mutations internally retain that coverage.

Public applicability tests reuse a runtime across their input cases when cache construction is not their subject. Dedicated cache and image tests retain cold lookup, invalidation, and unload/reload coverage.

The normal closure handoff test checks context identity across successive handoffs in Debug, the invocation result, and final capture release. The local suite retains the original 10,000-handoff stress case. Callback allocation tests still cross a native entry-page boundary; their allocation count is part of the contract.

Objective-C hook timing loops live in `ABIBridgeLocalTests` and run through `benchmark-runtime.sh hooks`. Short result and ownership tests remain in the public suite. The `calls` and `search` benchmark modes continue using `Tools/RuntimeBenchmarks`.

## Commands and validation limits

Run `bash scripts/test-package.sh all` for all three package schemes, including local workloads. Use `runtime`, `api`, or `local` to select a boundary. The [contributor guide](../CONTRIBUTING.md) lists Simulator, consumer, architecture, and device commands.

Measure build time, test time, and runner minutes separately when evaluating CI cost. Local timings do not establish hosted-runner latency. Preserve a complete consumer and architecture run for changes to native conventions even though routine CI uses a focused subset.
