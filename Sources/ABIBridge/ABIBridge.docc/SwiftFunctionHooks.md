# Hooking synchronous Swift functions

Use a capturing Swift closure to intercept imports of a synchronous Swift function, edit its arguments, and call the previous implementation through a scoped continuation.

## Edit arguments and results

Resolve the function by its source declaration and ordinary Swift function type:

```swift
let transform = try await runtime.swiftFunction(
    named: "Rendering.transform(_:)", as: ((String) -> String).self
)
let hook = try await unsafe transform.hookImportedCalls(
    in: .framework(named: "PreviewClient"),
    onFailure: { error in print(error) }
) { call, text in
    print(call.declaration, call.signature)
    let result = try call.proceed(text + " edited")
    return result + " inspected"
}
// Keep the registration while its callback is needed.
hook.invalidate()
```

The importer selects loaded callers containing references to the function. An optional `from:` filter matches the dependency recorded in the binding, including reexports. Neither selector loads images. Direct, inlined, specialized, or previously copied code pointers that bypass those imports are unaffected. Unresolved lazy references must first be called normally, and TPRO-protected references can reject publication.

The closure receives ordinary Swift arguments. Reference arguments keep their identity, so mutating a property before `proceed` changes what the next callback or native implementation observes. Changes after `proceed` remain visible to the original caller. Replacing a value argument requires passing the replacement explicitly to `proceed`. The continuation accepts the function's argument pack, including zero arguments and arguments passed on the stack.

`NativeSwiftFunctionInvocation<Signature>` preserves the complete argument, result, and error signature. `declaration`, `signature`, and `description` identify the registration request and supplied types. They remain usable after return. `proceed` is valid only on the entering thread and until that callback returns; an escaped or cross-thread use throws `NativeSwiftHookInvocationError`. It calls the captured chain rather than looking up the declaration again. A prior interposer can therefore be the predecessor.

## Ordering and failure recovery

Later registrations wrap earlier registrations. A call keeps its callback snapshot while it runs, including when a registration is invalidated concurrently or from inside a callback. Each continuation has independent result storage; repeated `proceed` calls release superseded owned results.

A declaration with `throws(any Error)` returns callback and conversion errors through its native error channel. A typed `throws(Failure)` declaration returns errors of that type. `proceed` exposes a native failure as `NativeSwiftError`; rethrowing that wrapper preserves the underlying native error.

An error that the native declaration cannot represent reaches `onFailure`. If that callback has not completed a continuation, its incoming arguments continue through the remaining chain. Once a continuation completes, recovery preserves its latest result or native failure without repeating native side effects. Registration and installation failures still throw from `hookImportedCalls`.

Ordinary callbacks stay on the incoming thread. When the native function's contract requires MainActor entry, use `hookMainActorImportedCalls`. It synchronously enters the actor-isolated closure after checking the thread. A background call reports `wrongThread` and bypasses that callback before decoding its Swift arguments. The failure observer must be thread-safe in both interfaces; the bridge does not dispatch native calls to another executor.

## Bind generic functions

Resolve the native declaration with explicit generic arguments before registering a hook:

```swift
let echo = try await runtime.swiftFunction(
    named: "Rendering.echo(_:)", as: ((String) -> String).self,
    genericArguments: [.type(String.self)]
)
let hook = try await unsafe echo.hookImportedCalls(
    in: .framework(named: "PreviewClient"),
    onFailure: { error in print(error) }
) { call, value in
    try call.proceed(value + " inspected")
}
```

Each registration applies to its bound native types. Registrations for different substitutions can share an import. Incoming metadata, pack shapes, and types supplied by class arguments or receivers select the matching callbacks before any bound value storage is read. Other substitutions continue through the original native entry. `proceed` preserves the caller's conformance witnesses.

## Lifetime and partial installation

Keep the returned `NativeSwiftImportedFunctionHook` to retain its behavior. `invalidate()` is idempotent and releases its closure captures after in-flight snapshots finish. Releasing the registration also invalidates it. Published dispatcher code, importing/provider images, and explicit generated-code owners remain retained for process lifetime so saved native pointers remain callable. Logical invalidation leaves a stable pass-through entry and does not overwrite another writer's pointer.

Inspect `slots` for current displacement and per-registration publication outcomes. Installation across multiple imports is not atomic. A failed installation invalidates the new callback and attempts to undo its own new pointer writes. `NativeSwiftHookInstallationError` preserves the original failure, failed slot index, and a registration with mutation, rollback, and protection-recovery results. Call `registration.recoverFailedInstallation()` to retry outstanding recovery owned by that failed installation. A restored pointer alone does not mean page protections were restored.

## Native contract

The declared ABI, ownership, and isolation must match the native entry. Source names and Swift metatypes do not prove those contracts. Hooks accept synchronous signatures using scalars, pointers, object references, String, tuples with native representations, returned concrete closures, and established Swift value adapters. Generic substitutions use the original declaration's argument and result conventions.

Runtime-only values, converted tuple elements, incoming closure arguments, explicit argument ownership wrappers, and noncopyable recovery need the shared callback conversion work tracked in [#296](https://github.com/lynnswap/ABIBridge/issues/296). Async hooks are tracked in [#297](https://github.com/lynnswap/ABIBridge/issues/297). These interfaces do not publish a callback when its value plan cannot represent the declaration. Yielding accessors require their separate native convention.

For an opaque result whose concrete payload is known, resolve its full `-> some` declaration with a matching `declaredAs:` signature and the concrete payload in `as:`. The hook and `proceed` preserve that declaration's return convention, including indirect results for scalar and String payloads.

This interface operates on function imports. Swift receiver and metadata-dispatch hooks are described in <doc:SwiftMethodHooks>. Use <doc:SwiftImportedReplacements> when the replacement itself is compiler-generated code and explicit physical restoration is required.

## Validation boundary

The compiled macOS tests cover typed object mutation, scalar and owned String chains, zero/stack arguments, Void and indirect results, returned-closure ownership, native errors, multiple generic bindings and pack shapes, callback recovery, MainActor/background entry, concurrent invalidation, saved entries, and failed-installation recovery. The external public-product consumer also exercises generic selection and typed-error recovery in an optimized build. On October 3, 2026, the signed `swift-function-hooks` fixture passed 22 checks on iPhone Air / iOS 27.0.1 (24A446), using Xcode 27.0 (27A266a) / Swift 6.4 and Release arm64e. The checks cover concrete and generic imports, indirect class substitutions, unmatched generic forwarding, returned generic closures with pointer authentication, typed native and callback errors, and invalidation. arm64e.x1 runtime execution still requires matching hardware.
