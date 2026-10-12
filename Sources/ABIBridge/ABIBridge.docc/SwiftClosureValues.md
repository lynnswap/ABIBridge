# Passing and calling Swift closures

Use ``NativeSwiftClosure`` to pass a capturing callback to a concrete Swift declaration or call a closure returned by native code.

## Pass a callback

For a loaded module declaring `func apply(_ callback: (Int64) -> Int64, value: Int64) -> Int64`:

```swift
let callback = try NativeSwiftClosure { (value: Int64) in value + 7 }
let apply = try ABIRuntime.shared.resolveSwiftFunctionAndWait(
    named: "Example.apply(_:value:)",
    as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
)
let result = try unsafe apply.unsafeInvoke(callback, 35)
```

The generic parameter is the complete native function type, including its arguments, result, declared errors, and async isolation convention. Function and member signatures accept this wrapper in place of the native Swift closure type. There is no fixed argument-count limit.

The synchronous initializer accepts a nonisolated `@Sendable` body matching the signature. Captures must be safe on the native caller's thread, including concurrent calls. Native code can borrow the callback for a call or retain its context for later use.

Construction validates function metadata. The first invocation or publication prepares the native layout and entry, reporting failures before native code runs. Subsequent calls reuse that preparation. Native context copies keep the entry, body, and captures alive after the original wrapper is released. The final context release ends that lifetime.

For a caller-isolated body passed to a synchronous native nonescaping parameter, use ``NativeSwiftClosure/withUnsafeNonescaping(_:_:)-4ragm``. The body and invocation stay on the current executor. Neither native code nor the use body may save or return the callback.

Simple existential arguments and results, including Any, protocol compositions, class constraints, and Error, use their compiler-established container and authentication conventions; see <doc:SwiftExistentialValues>.

## Call a returned closure

For a loaded module declaring `func makeAdder(_ bias: Int64) -> (Int64) -> Int64`:

```swift
let factory = try ABIRuntime.shared.resolveSwiftFunctionAndWait(
    named: "Example.makeAdder(_:)",
    as: ((Int64) -> NativeSwiftClosure<(Int64) -> Int64>).self
)
let addSeven = try unsafe factory.unsafeInvoke(7)
let result = try unsafe addSeven.unsafeInvoke(35)
```

The returned wrapper adopts the native context and retains its declaration, type, and entry images when available, plus any explicit code owner. Escaping native copies carry those owners too, and the context is destroyed while its code remains loaded. Repeated handoffs reuse compatible entries.

Returning a closure does not capture temporary receiver or argument storage. Resources and code referenced indirectly by foreign captures keep their original lifetime contract.

Calling stays on the caller's executor. The caller must satisfy the returned closure's actor, thread, and argument requirements. The wrapper is not Sendable: an arbitrary returned context may contain isolated or otherwise non-Sendable state.

## Resolve a closure stored in a runtime value

Use `resolveClosure(as:)` when a ``NativeSwiftValue`` already owns the native function value, including a closure extracted from an enum or tuple with the APIs in <doc:SwiftOpaqueResults>. Owned runtime values use the maximally abstracted function convention; enum payload resolution adapts concrete function fields to that convention before returning. The native function metadata supplies its parameter and result types. `NativeSwiftValue` in the requested signature represents the actual native argument or result, including a runtime-only type.

```swift
@MainActor
func makeBody(from closureValue: NativeSwiftValue) async throws -> NativeSwiftValue {
    let make = try await closureValue.resolveClosure(
        as: (@MainActor () -> NativeSwiftValue).self
    )
    return try unsafe make.unsafeInvoke()
}
```

The async resolver prepares on a worker while the caller suspends. `resolveClosureAndWait(as:)` performs the same preparation synchronously and can block its caller. Neither requires an explicit `prepare`; existing preparation for a required stage is shared. Resolving copies the context without consuming the original value, and the returned handle keeps its captures and code alive independently.

Include the native sync or async effect, declared error type, parameter ownership, and MainActor isolation in the signature. A MainActor signature uses a MainActor-isolated `unsafeInvoke`. For an async native body, use `(@MainActor () async -> NativeSwiftValue).self` and call `try unsafe await make.unsafeInvoke()`. Awaiting resolution does not make a synchronous native body asynchronous.

The unsupported `any Error & AnyObject` storage composition described in <doc:SwiftExistentialValues> also throws during resolution when it appears in a native argument or result, including a `NativeSwiftValue` marker.

An existential containing a closure first needs `copyUnderlyingValue()`. A non-function value or incompatible signature throws before native invocation. Values and closure contexts remain non-Sendable in the caller's isolation domain; only preparation information crosses to the worker.

## Nested closure inputs and results

Use `NativeSwiftClosure` inside the callback's signature for a native closure parameter. For `func visit(_ body: ((Int64) -> Int64) throws -> Int64) rethrows -> Int64`:

```swift
let callback = try NativeSwiftClosure<(NativeSwiftClosure<(Int64) -> Int64>) throws -> Int64> { value in
    try unsafe value.unsafeInvoke(42)
}
let visit = try ABIRuntime.shared.resolveSwiftFunctionAndWait(
    named: "Example.visit(_:)",
    as: ((NativeSwiftClosure<(NativeSwiftClosure<(Int64) -> Int64>) throws -> Int64>) throws -> Int64).self
)
let result = try unsafe visit.unsafeInvoke(callback)
```

The incoming handle is borrowed because a nonescaping native closure may hold a stack context. Saving it does not retain that context; later access throws `NativeSwiftBorrowError.expiredBorrow`.

Synchronous borrows stay on the native caller's thread. They can be forwarded synchronously, but passing one to an async call throws `NativeSwiftBorrowError.synchronousBorrow` before entry. An async callback may await operations using a borrowed closure and must finish them before returning. This rule applies whether the nested closure itself is synchronous or async.

For a native `@escaping` input, call `try input.copy()` while the borrow is active to retain its context and code beyond callback completion. Copying a nonescaping input fails; copying an expired input throws `NativeSwiftBorrowError.expiredBorrow`. Owned copies share capture state and reuse the prepared entry.

Passing a borrowed handle through `NativeSwiftConsuming` obtains the same owned copy before native entry. This requires an active borrow from a native `@escaping` parameter. Initializers borrow their nonescaping closure arguments and consume their escaping closure arguments; an ordinary nonescaping initializer can therefore accept a stack borrow without copying it.

Native closures can also be passed back to declarations with different generic lowering. Preparation creates the necessary adapters for inner arguments and results, including parameter packs and async functions. Each native context retains its own captures; adapters with the same native ABI reuse the existing owned entry across repeated handoffs.

A host callback returning an owned `NativeSwiftClosure` uses `throws(any Error)` so invalid ownership or conversion can reach the native caller. The result transfers a context reference that native code can retain. A borrowed nonescaping input cannot be returned as an owned closure. Ordinary callbacks without nested closure values retain their existing native error contract.

## Runtime value arguments and returned closures

Use ``NativeSwiftBorrowedValue`` to inspect an argument whose type comes from the resolved declaration. The view expires at body completion; async bodies must await all operations using it before returning. Use ``NativeSwiftValue`` to receive an independent copy of a Copyable, Escapable input. Noncopyable inputs can be borrowed. See <doc:BorrowedSwiftValues> for member access and borrow failures.

A returned closure can accept and return `NativeSwiftValue` through the same argument and result conversion as an ordinary native function. Borrowing an owned noncopyable argument does not copy or consume it. Each owned result has its own value-witness destruction and code-image lifetime. Type mismatches and consumed arguments throw before native entry, including when the native closure itself is nonthrowing.

For `func makeProducer<Value>(_ value: Value) -> () -> Value`:

```swift
let factory = try ABIRuntime.shared.resolveSwiftFunctionAndWait(
    named: "Example.makeProducer<A>(A) -> () -> A",
    as: ((String) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
    genericArguments: [.type(String.self)]
)
let produce = try unsafe factory.unsafeInvoke("captured")
let value = try unsafe produce.unsafeInvoke()
let text = try value.take(as: String.self)
```

The returned closure can be passed back through a resolved callback declaration with matching native value types. Its original native parameter layout is retained, including parameter packs; a new caller's lowering is adapted before forwarding. `NativeSwiftValue` bound as the actual native generic type remains an ordinary class reference, distinct from a handle used to represent another native type.

Nongeneric functions and members use the same declaration planning. For a free function whose callback contains erased runtime values, supply its complete native declaration, such as `Example.makeCopy() -> (Swift.String) -> Swift.String`; no generic argument is needed. Member lookup can bind the requested signature against the retained type's declarations.

A `consuming` input uses `NativeSwiftConsuming<Value>`. With `NativeSwiftValue`, it moves the payload into an independent owner without copying, including noncopyable values. That owner may outlive the callback; otherwise its payload is destroyed once on success or failure. This input conversion does not require a throwing callback.

A `consuming @escaping` closure input uses `NativeSwiftConsuming<NativeSwiftClosure<Signature>>`. Its `value` adopts the context and code lifetime. If preparation fails, the context is released and later invocation, copying, or forwarding throws that preparation error, even when the receiving callback cannot throw.

```swift
let count = try NativeSwiftClosure<(NativeSwiftConsuming<String>) -> Int> { incoming in
    incoming.value.count
}
```

Explicit `NativeSwiftBorrowing<NativeSwiftBorrowedValue>` inputs keep the same scoped lifetime as an ordinary borrowed input; adding an ownership marker does not extend a borrow across callback return. `NativeSwiftConsuming` also works when invoking a returned native closure.

For a known `inout Value`, use ``NativeSwiftInout``. The body receives an owned local buffer and writes its final value back on completion, including throwing or async completion. Saved buffers remain independent. Converted closures and tuples require `throws(any Error)` for writeback failures; see <doc:SwiftArgumentConventions> for buffer state and failure handling.

For runtime-only `inout T`, use ``NativeSwiftBorrowedValue``. The declaration grants exclusive mutation access, including for noncopyable payloads. Invoke a mutating member or pass `NativeSwiftInout(view)` to a prepared function. The view cannot be consumed; overlapping access throws `NativeSwiftValueError.valueInUse`. Native mutations remain visible if the body throws, and the view expires at completion.

A host callback returning ``NativeSwiftValue`` requires `throws(any Error)`. Conversion moves its payload, including noncopyable values; return `try value.copy()` to keep the original usable. A wrong type, consumed handle, or conflicting access throws through the native channel and leaves an unsuccessful transfer in its owner. This also applies after suspension. Native code sees the original conversion error; a bridge invocation wraps native failure in ``NativeSwiftError``.

For `func produce<Value: ~Copyable>(_ body: () throws -> Value) rethrows -> Value`, a runtime-only value uses the ordinary closure type:

```swift
let produce = try ABIRuntime.shared.resolveSwiftFunctionAndWait(
    named: "Example.produce<A where A: ~Swift.Copyable>(() throws -> A) throws -> A",
    as: ((NativeSwiftClosure<() throws -> NativeSwiftValue>) throws -> NativeSwiftValue).self,
    genericArguments: [.type(value.type)]
)
```

Prepare a Sendable body that obtains an owned value and returns it, then pass that callback to `produce.unsafeInvoke`. A host callback returning a runtime handle cannot use a nonthrowing or narrower typed-error native declaration: those channels cannot represent handle conversion failures. This restriction does not apply to calling a returned native closure, where `unsafeInvoke` already has a bridge-error channel.

## Combine closures and runtime values in tuples

Use an ordinary Swift tuple for a native tuple argument or result. Its elements can include `NativeSwiftValue`, `NativeSwiftBorrowedValue` in a callback scope, and `NativeSwiftClosure<Signature>`, including inside nested tuples. Each element follows the same ownership contract as a standalone value.

A single `NativeSwiftValue` can also carry the whole native tuple. Its copies preserve ordinary Swift value semantics, including stored functions. Use `take(as:)` when the exact native tuple type is available to your code, retaining its type handle as described in <doc:BorrowedSwiftValues>.

For a provider with a resilient `Record` and `func makeSnapshot() -> (record: Record, callback: (Int64) -> Int64)`:

```swift
let runtime = ABIRuntime.shared
let recordType = try runtime.resolveSwiftTypeAndWait(named: "Example.Record")
typealias Callback = NativeSwiftClosure<(Int64) -> Int64>
typealias Snapshot = (record: NativeSwiftValue, callback: Callback)

let makeSnapshot = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.makeSnapshot() -> (record: Example.Record, callback: (Swift.Int64) -> Swift.Int64)",
    as: (() -> Snapshot).self,
    valueABIs: [recordType: .opaque(named: recordType.name)]
)
let snapshot = try unsafe makeSnapshot.unsafeInvoke()
let result = try unsafe snapshot.callback.unsafeInvoke(35)
```

The complete native declaration identifies `Record`, whose name differs from the host handle's name. Preserve the tuple's labels and element order in `as:`. `declaredAs:` supplies preparation details after symbol lookup; it cannot supply a missing native name during lookup. This example uses `.opaque` because `Record` is passed indirectly. A fixed-layout value needs its established native components, as described in <doc:BorrowedSwiftValues>.

The returned fields own their values and code dependencies. A callback input can instead use ``NativeSwiftBorrowedValue`` for the record field; borrowed fields expire together at callback completion. Consuming tuple arguments transfer their runtime payloads and closure contexts.

A host callback returning converted runtime-value or closure fields uses `throws(any Error)` so field-conversion failures can reach the native caller. Result ownership transfers only after all fields are prepared successfully. Ordinary tuples containing only native Swift values keep their declared nonthrowing or typed-error contract. Function and member calls use the same tuple representations; <doc:SwiftArgumentConventions> describes mutable tuple and closure buffers.

## Throwing callbacks and returned closures

Include `throws` or `throws(Failure)` in the ``NativeSwiftClosure`` signature. `Failure` can be a concrete Swift error, `any Error`, or `Never`; `throws(Never)` is equivalent to a nonthrowing signature.

```swift
let callback = try NativeSwiftClosure<(Bool) throws -> String> { fail in
    if fail { throw ExampleError.unavailable }
    return "ready"
}
let apply = try ABIRuntime.shared.resolveSwiftFunctionAndWait(
    named: "Example.apply(_:_:)",
    as: ((NativeSwiftClosure<(Bool) throws -> String>, Bool) throws -> String).self
)
let result = try unsafe apply.unsafeInvoke(callback, false)
```

The native caller receives the body's original error, so it can catch that error directly. Calling a returned wrapper from Swift uses `unsafeInvoke`; a native failure becomes ``NativeSwiftError``, consistent with ordinary throwing function invocation. Its retained code owners do not retain unrelated callback captures.

Concrete errors use their actual Swift representation through ``ABIBridgeSwiftValue`` or a supported class/error reference. Direct integer carriers, floating/large indirect errors, and independent indirect success/error buffers share the function-invocation machinery. The same capture and code-image lifetime rules apply to throwing closures, including native escaping storage.

## Async callbacks and returned closures

Use an async function type as the ``NativeSwiftClosure`` signature. Include `nonisolated(nonsending)` for a hidden caller-isolation argument or `@concurrent` for the concurrent convention. Include `@Sendable` when it belongs to the native declaration's closure type, and include `throws` or `throws(Failure)` for native errors.

```swift
let body: (nonisolated(nonsending) @Sendable (Int64) async -> Int64) = { value in
    await Task.yield()
    return value + 7
}
let callback = try NativeSwiftClosure<nonisolated(nonsending) @Sendable (Int64) async -> Int64>(body)
let result = try unsafe await callback.unsafeInvoke(35)
```

With Swift 6.3.3, bind an async closure expression to a variable with its complete function type before constructing the wrapper, as above, or pass a function reference. Passing the expression directly to the parameter-pack initializer can crash SIL generation or reuse a previous capture context under `NonisolatedNonsendingByDefault`. See the [compiler reproduction](https://github.com/lynnswap/ABIBridge/issues/285#issuecomment-5952463646).

A caller-isolated signature carries the native caller's hidden isolation argument. A concurrent signature enters the generic executor before running its body; the body can perform its own actor hops. Both preserve the original Task, including task-local values, cooperative cancellation, and executor preferences. Calling `unsafeInvoke` restores the Swift caller's executor after native completion.

Pass the appropriate wrapper in an async function's metatype just as with synchronous closures:

```swift
let apply = try ABIRuntime.shared.resolveSwiftFunctionAndWait(
    named: "Example.apply(_:_:)",
    as: (@concurrent (NativeSwiftClosure<@Sendable @concurrent (Int64) async -> Int64>, Int64) async -> Int64).self
)
```

For a native factory returning a closure, put the wrapper in the factory's result type. Its descriptor, implementation image, arguments, result storage, and captured context remain alive across suspension. Native escaping copies carry the same code leases, including after repeated handoffs. Native errors use ``NativeSwiftError`` and retain their code dependencies without keeping unrelated callback captures alive.

Label-only lookup preserves `@Sendable` and async attributes. The initializer requires a Sendable body even for an ordinary native closure parameter. Returned contexts keep their actor and ownership requirements, so the wrapper itself is not Sendable.

## Reuse a callback

Reuse a prepared callback when its capture lifetime permits it. Each native context owns its body and code independently; preparation-cache eviction does not invalidate live handles. Idle entry storage retains no bodies or captures.

## Supported signatures

Synchronous and async closures use the scalar, pointer, managed, explicit-layout, existential, and tuple representations in <doc:SwiftFunctionInvocation>, together with the runtime-value and nested-closure forms above. They support zero arguments, empty-tuple arguments, and Void results.

Array elements use compiler-owned storage and need no direct-call conformance. A standalone element still needs a supported representation. Nested optional containers require an adapter.

Custom ``ABIBridgeValue`` conversions are outside this callback path: the callback uses actual Swift values. Unsupported value Optionals and generic shapes need a compiler adapter. Runtime-only nominal values can supply an established ABI through `valueABIs`; see <doc:BorrowedSwiftValues>.

Incoming closure-valued hook arguments use the same scoped borrow as ordinary callback inputs. A nonescaping input remains usable during the hook body and expires afterward. Copying an input requires the native declaration to grant escaping ownership. See <doc:SwiftFunctionHooks> and <doc:SwiftMethodHooks> for continuation and failure recovery.

## Ownership and failures

Preparing an unsupported signature or allocating callback entry storage can throw before the callback is published. The captured body is released if preparation fails.

Each encoded argument owns a context reference through the native call. A later argument-conversion failure releases that reference without entering native code. Ordinary calls borrow their encoded arguments; supported initializers transfer their encoded owned copies according to their existing invocation contract. Decoding an owned returned closure transfers its context into the wrapper, including cleanup if entry preparation fails.

A native caller must use the declared Swift ABI. Invalid function pointers, incompatible argument types, and violated isolation or ownership contracts are unsafe-call errors and can corrupt memory. Only a declared throwing callback can return a native Swift error. Foreign exceptions are outside both callback contracts.

## ABI and verification

A thick closure has a function pointer and a Swift capture context. The context can use closure-capture metadata rather than ordinary class metadata. The bridge uses the Swift runtime's context retain/release operations and preserves arm64e's type-dependent function-pointer authentication.

Those two words are not interchangeable across every Swift representation. A concrete callback and a function value passed through generic storage can require different argument/result lowering and authentication discriminators. The bridge creates a concrete entry for the supported signature; it does not copy an ordinary generic function value into a native callback parameter.

Compiler fixtures compare both reabstraction directions and native results. Runtime checks separately cover capture lifetime, escaping storage, returned contexts, stack arguments, managed results, and failure cleanup. The [architecture validation guide](https://github.com/lynnswap/ABIBridge/blob/main/Tests/ArchitectureValidation/README.md) records device execution and compiler-only coverage.

See <doc:SwiftFunctionInvocation>, <doc:SwiftMemberInvocation>, and <doc:ManagedSwiftValues> for the surrounding call and storage contracts.
