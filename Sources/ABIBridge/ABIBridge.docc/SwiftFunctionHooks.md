# Hooking Swift functions

Use a capturing Swift closure to intercept imports of a Swift function, edit its arguments, and call the previous implementation through a scoped continuation.

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

`NativeSwiftFunctionInvocation<Signature>` preserves the complete argument, result, and error signature. `declaration`, `signature`, and `description` identify the registration request and supplied types. They remain usable after return. `proceed` is valid until that callback returns. Synchronous continuations stay on the entering thread; asynchronous continuations stay on the same Swift task. An expired, cross-thread, or cross-task use throws `NativeSwiftHookInvocationError`. It calls the captured chain rather than looking up the declaration again. A prior interposer can therefore be the predecessor.

## Await an asynchronous predecessor

Resolve an async function with its complete isolation and error signature, then use the same registration and invocation types:

```swift
let transform = try await runtime.swiftFunction(
    named: "Rendering.transformAsync(_:)",
    as: (nonisolated(nonsending) (String) async throws -> String).self
)
let hook = try await unsafe transform.hookImportedCalls(
    in: .framework(named: "PreviewClient"),
    onFailure: { error in print(error) }
) { call, text in
    let result = try await call.proceed(text + " edited")
    return result + " inspected"
}
```

The callback and `proceed` run on the native task. They preserve cancellation and task-local values across suspension. A caller-isolated signature preserves the caller's isolation payload; use `@concurrent` for a native entry with the concurrent convention. `hookMainActorImportedCalls` also accepts async callbacks for a native MainActor entry. It checks entry before scheduling the body, and the callback resumes on MainActor after each await.

Each entered call keeps its argument storage, metadata, callback snapshot, code owners, and completed result or error until it returns. Invalidation releases those captures after the active async calls finish. It does not cancel or replay them. A saved continuation cannot start work from another task or extend an incoming borrow beyond the callback's completion.

## Ordering and failure recovery

Later registrations wrap earlier registrations. A call keeps its callback snapshot while it runs, including when a registration is invalidated concurrently or from inside a callback. Each continuation has independent result storage; repeated `proceed` calls release superseded owned results.

A declaration with `throws(any Error)` returns callback and conversion errors through its native error channel. A typed `throws(Failure)` declaration returns errors of that type. `proceed` exposes a native failure as `NativeSwiftError`; rethrowing that wrapper preserves the underlying native error.

An error that the native declaration cannot represent reaches `onFailure`. If that callback has not completed a continuation, its incoming arguments continue through the remaining chain. Once a continuation completes, recovery preserves its latest result or native failure without repeating native side effects. Registration and installation failures still throw from `hookImportedCalls`.

Synchronous callbacks stay on the incoming thread. When the native function's contract requires MainActor entry, use `hookMainActorImportedCalls`. It synchronously enters the actor-isolated closure after checking the thread. A background call reports `wrongThread` and bypasses that callback before decoding its Swift arguments. The failure observer must be thread-safe in both interfaces; the bridge does not dispatch native calls to another executor.

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

## Runtime values and ownership

Use NativeSwiftValue for an owned runtime value and NativeSwiftBorrowedValue for an incoming scoped borrow. Explicit NativeSwiftConsuming and NativeSwiftInout arguments follow the native declaration, including generic bindings. Converted tuple fields and nested closure values use the same plans as ordinary calls. Borrowed views expire after the callback; independently owned copies keep their normal lifetime.

For a provider declaring `consume<T: Readable & ~Copyable>(_ value: consuming T) -> Int64`, prepare its binding and any member handles before registration:

```swift
let consume = try await runtime.swiftFunction(
    named: "Provider.consume(_:)",
    as: ((NativeSwiftConsuming<NativeSwiftValue>) -> Int64).self,
    genericArguments: [.type(ticketType)]
)
let hook = try await unsafe consume.hookImportedCalls(
    in: callerImage, onFailure: { error in report(error) }
) { call, incoming in
    let number = try unsafe readNumber.unsafeInvoke(on: incoming.value)
    return try call.proceed(incoming) + number
}
```

When recovery needs a noncopyable incoming value or completed result, the callback reserves its ownership. Reads and valid inout operations remain available. An independent `take(as:)` or consuming native call throws NativeSwiftValueError.valueInUse before transferring that value. `proceed` and final result publication perform the authorized transfer. A declaration with `throws(any Error)` can report every bridge error through its native channel and requires no recovery reservation.

Saved handles share one ownership state. Forwarding an incoming value or publishing a returned value leaves all its aliases consumed; saving a result from `proceed` does not create another native copy. If the callback keeps an input without forwarding it, the saved owner becomes available for independent consumption after the callback ends. A failure after native continuation uses the latest completed result or error and executes no additional native effects.

These rules also apply across an async callback's suspension. The shared continuation completes argument writeback on success and failure, and transfers consumed arguments only after the predecessor has run. Supply the established receiver and value ABI overrides where the declaration does not establish a native layout.

## Lifetime and partial installation

Keep the returned `NativeSwiftImportedFunctionHook` to retain its behavior. `invalidate()` is idempotent and releases its closure captures after in-flight snapshots finish. Releasing the registration also invalidates it. Published dispatcher code, importing/provider images, and explicit generated-code owners remain retained for process lifetime so saved native pointers remain callable. Logical invalidation leaves a stable pass-through entry and does not overwrite another writer's pointer.

Inspect `slots` for current displacement and per-registration publication outcomes. Installation across multiple imports is not atomic. A failed installation invalidates the new callback and attempts to undo its own new pointer writes. `NativeSwiftHookInstallationError` preserves the original failure, failed slot index, and a registration with mutation, rollback, and protection-recovery results. Call `registration.recoverFailedInstallation()` to retry outstanding recovery owned by that failed installation. A restored pointer alone does not mean page protections were restored.

## Native contract

The declared ABI, ownership, and isolation must match the native entry. Source names and Swift metatypes do not prove those contracts. Hooks accept synchronous and asynchronous signatures using scalars, pointers, object references, String, tuples with native representations, returned concrete closures, and established Swift value adapters. Generic substitutions use the original declaration's argument and result conventions.

Runtime-only values, converted tuples, nested closures, and borrowing, consuming, and inout arguments use the shared declaration and callback plans. These interfaces do not publish a callback when its value plan cannot represent the declaration. Yielding accessors require their separate native convention.

For an opaque result whose concrete payload is known, resolve its full `-> some` declaration with a matching `declaredAs:` signature and the concrete payload in `as:`. The hook and `proceed` preserve that declaration's return convention, including indirect results for scalar and String payloads.

This interface operates on function imports. Swift receiver and metadata-dispatch hooks are described in <doc:SwiftMethodHooks>. Use <doc:SwiftImportedReplacements> when the replacement itself is compiler-generated code and explicit physical restoration is required.

## Validation boundary

The compiled macOS tests cover typed object mutation, scalar and owned String chains, zero/stack arguments, Void and indirect results, returned-closure ownership, native errors, multiple generic bindings and pack shapes, callback recovery, MainActor/background entry, concurrent invalidation, saved entries, and failed-installation recovery. The external public-product consumer also exercises generic selection and typed-error recovery in an optimized build. On October 3, 2026, the signed `swift-function-hooks` fixture passed 22 checks on iPhone Air / iOS 27.0.1 (24A446), using Xcode 27.0 (27A266a) / Swift 6.4 and Release arm64e. The checks cover concrete and generic imports, indirect class substitutions, unmatched generic forwarding, returned generic closures with pointer authentication, typed native and callback errors, and invalidation. arm64e.x1 runtime execution still requires matching hardware.

Async fixtures additionally cover generic mismatch pass-through, typed errors and indirect results, MainActor and caller-isolated resumption, concurrent and reentrant calls, task-local values, cancellation, and capture release after invalidation. The optimized external consumer exercises async import chains and virtual descriptor pass-through with owned String results.

On October 4, 2026, the expanded signed fixture passed all 44 checks on the same iPhone Air configuration. Runtime ownership cases additionally cover noncopyable input/result aliases, recovery without replayed effects, authenticated virtual continuations, failed inout conversion, and consuming runtime closures with capture release across sync and async calls. The same build passed all 83 opaque-result checks. Both newly written completed reports recorded `pacCompiled: true` and CPU subtype `0x80000002`.
