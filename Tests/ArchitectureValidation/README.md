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
