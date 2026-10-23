# Hooking Swift functions

Use a capturing Swift closure to intercept imports of a Swift function, edit its arguments, and call the previous implementation through a scoped continuation.

## Edit arguments and results

Resolve the function by its source declaration and ordinary Swift function type:

```swift
let transform = try await runtime.resolve(.function(
    "Rendering.transform(_:)", as: ((String) -> String).self
))
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

The importer selects loaded callers containing references to the code that lookup selected for the declaration, and to the dispatch thunk through which other images call a library-evolution class member, such as a `class func`, or a protocol requirement. An optional `from:` filter matches the dependency recorded in the binding, including reexports. Neither selector loads images. Direct, inlined, specialized, or previously copied code pointers that bypass those imports are unaffected. Unresolved lazy references must first be called normally, and TPRO-protected references can reject publication.

A class's `class func`, `class var`, and `class subscript` members also dispatch through the class's metadata. `hookVirtualCalls` intercepts those calls at the lookup type's entry; see <doc:SwiftMethodHooks#Hook-class-members>.

The closure receives ordinary Swift arguments. Reference arguments keep their identity, so mutating a property before `proceed` changes what the next callback or native implementation observes. Changes after `proceed` remain visible to the original caller. Replacing a value argument requires passing the replacement explicitly to `proceed`. The continuation accepts the function's argument pack, including zero arguments and arguments passed on the stack.

`NativeSwiftFunctionInvocation<Signature>` preserves the complete signature. Its diagnostic properties identify the registration and remain usable after return; see <doc:HookArguments>.

`proceed` follows the captured chain, including any earlier interposer, without repeating lookup. It is valid until callback completion, on the entering thread for sync calls or the same Swift task for async calls. Expired, cross-thread, or cross-task use throws `NativeSwiftHookInvocationError`.

## Await an asynchronous predecessor

Resolve an async function with its complete isolation and error signature, then use the same registration and invocation types:

```swift
let transform = try await runtime.resolve(.function(
    "Rendering.transformAsync(_:)",
    as: (nonisolated(nonsending) (String) async throws -> String).self
))
let hook = try await unsafe transform.hookImportedCalls(
    in: .framework(named: "PreviewClient"),
    onFailure: { error in print(error) }
) { call, text in
    let result = try await call.proceed(text + " edited")
    return result + " inspected"
}
```

The callback and `proceed` run on the native task. They preserve cancellation and task-local values across suspension. A caller-isolated signature preserves the caller's isolation payload; use `@concurrent` for a native entry with the concurrent convention. `hookMainActorImportedCalls` also accepts async callbacks for a native MainActor entry. It checks entry before scheduling the body, and the callback resumes on MainActor after each await.

An entered call retains its storage, metadata, snapshot, code, and completed result/error through return. Invalidation leaves captures alive until active snapshots finish, without cancelling or replaying their calls. Saving a continuation does not extend a borrow or permit work from another task.

## Ordering and failure recovery

Later registrations wrap earlier registrations. A call keeps its callback snapshot while it runs, including when a registration is invalidated concurrently or from inside a callback. Each continuation has independent result storage; repeated `proceed` calls release superseded owned results.

A declaration with `throws(any Error)` returns callback and conversion errors through its native error channel. A typed `throws(Failure)` declaration returns errors of that type. `proceed` exposes a native failure as `NativeSwiftError`; rethrowing that wrapper preserves the underlying native error.

An error that the native declaration cannot represent reaches `onFailure`. If that callback has not completed a continuation, its incoming arguments continue through the remaining chain. Once a continuation completes, recovery preserves its latest result or native failure without repeating native side effects. Registration and installation failures still throw from `hookImportedCalls`.

Synchronous callbacks stay on the incoming thread. When the native function's contract requires MainActor entry, use `hookMainActorImportedCalls`. It synchronously enters the actor-isolated closure after checking the thread. A background call reports `wrongThread` and bypasses that callback before decoding its Swift arguments. The failure observer must be thread-safe in both interfaces; the bridge does not dispatch native calls to another executor.

## Bind generic functions

Resolve the native declaration with explicit generic arguments before registering a hook:

```swift
let echo = try await runtime.resolve(.function(
    "Rendering.echo(_:)", as: ((String) -> String).self,
    genericArguments: [.type(String.self)]
))
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
let consume = try await runtime.resolve(.function(
    "Provider.consume(_:)",
    as: ((NativeSwiftConsuming<NativeSwiftValue>) -> Int64).self,
    genericArguments: [.type(ticketType)]
))
let hook = try await unsafe consume.hookImportedCalls(
    in: callerImage, onFailure: { error in report(error) }
) { call, incoming in
    let number = try unsafe readNumber.unsafeInvoke(on: incoming.value)
    return try call.proceed(incoming) + number
}
```

Recovery reserves any noncopyable input or completed result it may need. Reads and valid inout operations remain available, but an independent `take(as:)` or consuming call throws `NativeSwiftValueError.valueInUse`. `proceed` and final publication perform the authorized transfer. A `throws(any Error)` declaration needs no reservation because its channel can report every bridge error.

Saved handles share ownership. Forwarding an input or publishing a result consumes all aliases; saving a result from `proceed` creates no copy. An input kept without forwarding becomes available for independent consumption after callback completion.

These rules also apply across an async callback's suspension. The shared continuation completes argument writeback on success and failure, and transfers consumed arguments only after the predecessor has run. Supply the established receiver and value ABI overrides where the declaration does not establish a native layout.

## Lifetime and partial installation

Keep the returned `NativeSwiftImportedFunctionHook` to retain its behavior. `invalidate()` is idempotent and releases its closure captures after in-flight snapshots finish. Releasing the registration also invalidates it. Published dispatcher code, importing/provider images, and explicit generated-code owners remain retained for process lifetime so saved native pointers remain callable. Logical invalidation leaves a stable pass-through entry and does not overwrite another writer's pointer.

Inspect `slots` for current displacement and per-registration publication outcomes. Installation across multiple imports is not atomic. A failed installation invalidates the new callback and attempts to undo its own new pointer writes. `NativeSwiftHookInstallationError` preserves the original failure, failed slot index, and a registration with mutation, rollback, and protection-recovery results. Call `registration.recoverFailedInstallation()` to retry outstanding recovery owned by that failed installation. A restored pointer alone does not mean page protections were restored.

## Native contract

The declared ABI, ownership, and isolation must match the native entry. Source names and Swift metatypes do not prove those contracts. Hooks use the value, closure, generic, and argument-ownership representations in <doc:SwiftValues>, preserving the original declaration's conventions. Unsupported plans fail before callback publication. Yielding accessors require a separate native convention.

For an opaque result whose concrete payload is known, resolve its full `-> some` declaration with a matching `declaredAs:` signature and the concrete payload in `as:`. The hook and `proceed` preserve that declaration's return convention, including indirect results for scalar and String payloads.

This interface operates on function imports. Swift receiver and metadata-dispatch hooks are described in <doc:SwiftMethodHooks>. Use <doc:SwiftImportedReplacements> when the replacement itself is compiler-generated code and explicit physical restoration is required.

## Verification

Compiled fixtures and external consumers cover generic selection, sync/async chains, ownership, error recovery, isolation, invalidation, and failed-installation cleanup. Device execution and compiler checks are recorded in the [architecture validation guide](https://github.com/lynnswap/ABIBridge/blob/main/Tests/ArchitectureValidation/README.md). arm64e.x1 execution still requires matching hardware.
