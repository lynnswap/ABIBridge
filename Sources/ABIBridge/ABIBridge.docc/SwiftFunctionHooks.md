# Hooking concrete Swift functions

Use a capturing Swift closure to intercept imports of a concrete, synchronous Swift function, edit its arguments, and call the previous implementation through a scoped continuation.

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

`declaration`, `signature`, and `description` identify the registration request and supplied types. They remain usable after return. `proceed` is valid only on the entering thread and until that callback returns; an escaped or cross-thread use throws `NativeSwiftHookInvocationError`. It calls the captured chain rather than looking up the declaration again. A prior interposer can therefore be the predecessor.

## Ordering and failure recovery

Later registrations wrap earlier registrations. A call keeps its callback snapshot while it runs, including when a registration is invalidated concurrently or from inside a callback. Each continuation has independent result storage; repeated `proceed` calls release superseded owned results.

A thrown callback or conversion error reaches `onFailure`. If that callback has not completed a continuation, its incoming arguments continue through the remaining chain. Once a continuation completes, failure preserves its latest result instead of repeating native side effects. This handles errors in the hook closure; it does not add support for a native Swift `throws` ABI.

Ordinary callbacks stay on the incoming thread. When the native function's contract requires MainActor entry, use `hookMainActorImportedCalls`. It synchronously enters the actor-isolated closure after checking the thread. A background call reports `wrongThread` and bypasses that callback before decoding its Swift arguments. The failure observer must be thread-safe in both interfaces; the bridge does not dispatch native calls to another executor.

## Lifetime and partial installation

Keep the returned `NativeSwiftImportedFunctionHook` to retain its behavior. `invalidate()` is idempotent and releases its closure captures after in-flight snapshots finish. Releasing the registration also invalidates it. Published dispatcher code, importing/provider images, and explicit generated-code owners remain retained for process lifetime so saved native pointers remain callable. Logical invalidation leaves a stable pass-through entry and does not overwrite another writer's pointer.

Inspect `slots` for current displacement and per-registration publication outcomes. Installation across multiple imports is not atomic. A failed installation invalidates the new callback and attempts to undo its own new pointer writes. `NativeSwiftHookInstallationError` preserves the original failure, failed slot index, and a registration with mutation, rollback, and protection-recovery results. Call `registration.recoverFailedInstallation()` to retry outstanding recovery owned by that failed installation. A restored pointer alone does not mean page protections were restored.

## Native contract

The declared ABI, ownership, and isolation must match the native entry. Source names and Swift metatypes do not prove those contracts. The supported value representations are those of the concrete Swift invocation API: scalars, pointers, object references, String, standard C values, and fixed trivial layouts supplied by adapters. Arbitrary nontrivial adapters, native async/throws, generic metadata or witness arguments, resilient layouts, and yielding accessors require separate support.

For an opaque result whose concrete payload is known, resolve its full `-> some` declaration with a matching `declaredAs:` signature and the concrete payload in `as:`. The hook and `proceed` preserve that declaration's return convention, including indirect results for scalar and String payloads.

This interface operates on function imports. Swift receiver and metadata-dispatch hooks are described in <doc:SwiftMethodHooks>. Use <doc:SwiftImportedReplacements> when the replacement itself is compiler-generated code and explicit physical restoration is required.

## Validation boundary

The compiled macOS consumers cover typed object mutation, scalar and owned String chains, zero/stack arguments, Void and indirect results, callback failure, MainActor/background entry, concurrent invalidation, saved entries, and failed-installation recovery. An arm64e iPhone run additionally passed imported scalar, owned String and indirect-result callbacks through separately compiled signed frameworks, including shared chains and pass-through after invalidation. arm64e.x1 runtime execution still requires matching hardware.
