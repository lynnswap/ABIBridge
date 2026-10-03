# Passing and calling Swift closures

Use ``NativeSwiftClosure`` to pass a capturing callback to a concrete Swift declaration or call a closure returned by native code.

## Pass a callback

For a loaded module declaring `func apply(_ callback: (Int64) -> Int64, value: Int64) -> Int64`:

```swift
let callback = try NativeSwiftClosure { (value: Int64) in value + 7 }
let apply = try await ABIRuntime.shared.swiftFunction(
    named: "Example.apply(_:value:)",
    as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
)
let result = try unsafe apply.unsafeInvoke(callback, 35)
```

The generic parameter is the complete native function type, including its arguments, result, declared errors, and async isolation convention. Function and member signatures accept this wrapper in place of the native Swift closure type. There is no fixed argument-count limit.

The synchronous initializer accepts a nonisolated `@Sendable` body matching the signature's arguments, result, and declared error type. Its captures must be safe for the native caller's thread and concurrent calls. The generated entry translates the concrete native arguments into the compiler's generic Swift representation before calling the body. The callback may be passed to a nonescaping parameter or retained by an escaping native callee.

A retained native callback owns the Swift context that keeps its generated entry and body alive. Releasing the original wrapper does not invalidate a copy held by the callee. The last native context release releases the body and its captures; there is no separate invalidate or close operation.

Simple existential arguments and results, including Any, protocol compositions, class constraints, and Error, use their compiler-established container and authentication conventions; see <doc:SwiftExistentialValues>.

## Call a returned closure

For a loaded module declaring `func makeAdder(_ bias: Int64) -> (Int64) -> Int64`:

```swift
let factory = try await ABIRuntime.shared.swiftFunction(
    named: "Example.makeAdder(_:)",
    as: ((Int64) -> NativeSwiftClosure<(Int64) -> Int64>).self
)
let addSeven = try unsafe factory.unsafeInvoke(7)
let result = try unsafe addSeven.unsafeInvoke(35)
```

The returned wrapper adopts the native closure's owned context and retains the declaring/type images, explicit implementation code owner, and the closure entry's containing image when available. Temporary receiver and argument storage stays with the call; returning a closure does not add a receiver capture. A concrete forwarding context carries those owners into native escaping copies as well. Entries already owned by the closure allocator keep their existing context, so repeated identity handoffs do not add forwarding layers. The original context is released while its code owners are still alive. Additional native resources or code images referenced indirectly by a foreign capture must obey their original lifetime contract.

Calling stays on the caller's executor. The caller must satisfy the returned closure's actor, thread, and argument requirements. The wrapper is not Sendable: an arbitrary returned context may contain isolated or otherwise non-Sendable state.

## Runtime value arguments and returned closures

When the resolved declaration identifies a native argument type, use `NativeSwiftBorrowedValue` in the callback signature to inspect it during the body. The view expires when the body finishes. An async body may suspend while the native caller preserves that borrow, and must finish every operation using the view before returning. Use `NativeSwiftValue` when the body needs an independent owned copy of a Copyable, Escapable input. A noncopyable input can still use the borrowed view.

A returned closure can accept and return `NativeSwiftValue` through the same argument and result conversion as an ordinary native function. Borrowing an owned noncopyable argument does not copy or consume it. Each owned result has its own value-witness destruction and code-image lifetime. Type mismatches and consumed arguments throw before native entry, including when the native closure itself is nonthrowing.

For `func makeProducer<Value>(_ value: Value) -> () -> Value`:

```swift
let factory = try await ABIRuntime.shared.swiftFunction(
    named: "Example.makeProducer<A>(A) -> () -> A",
    as: ((String) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
    genericArguments: [.type(String.self)]
)
let produce = try unsafe factory.unsafeInvoke("captured")
let value = try unsafe produce.unsafeInvoke()
let text = try value.take(as: String.self)
```

The returned closure can be passed back through a resolved callback declaration with matching native value types. Its original native parameter layout is retained, including parameter packs; a new caller's lowering is adapted before forwarding. `NativeSwiftValue` bound as the actual native generic type remains an ordinary class reference, distinct from a handle used to represent another native type.

A host callback can return `NativeSwiftValue` to a native caller whose callback type uses `throws(any Error)`. Successful conversion moves the native payload out of the returned handle, including noncopyable values. Return `try value.copy()` when the handle must remain usable. A wrong type, consumed handle, or conflicting access throws through the native error channel; a failed transfer leaves the value in its existing owner. The same contract applies after an async body suspends. Native code can catch the conversion error directly; a subsequent bridge invocation surfaces it in `NativeSwiftError`.

For `func produce<Value: ~Copyable>(_ body: () throws -> Value) rethrows -> Value`, a runtime-only value uses the ordinary closure type:

```swift
let produce = try await ABIRuntime.shared.swiftFunction(
    named: "Example.produce<A where A: ~Swift.Copyable>(() throws -> A) throws -> A",
    as: ((NativeSwiftClosure<() throws -> NativeSwiftValue>) throws -> NativeSwiftValue).self,
    genericArguments: [.type(value.type)]
)
```

Prepare a Sendable body that obtains an owned value and returns it, then pass that callback to `produce.unsafeInvoke`. A host callback returning a runtime handle cannot use a nonthrowing or narrower typed-error native declaration: those channels cannot represent handle conversion failures. This restriction does not apply to calling a returned native closure, where `unsafeInvoke` already has a bridge-error channel.

## Throwing callbacks and returned closures

Include `throws` or `throws(Failure)` in the ``NativeSwiftClosure`` signature. `Failure` can be a concrete Swift error, `any Error`, or `Never`; `throws(Never)` is equivalent to a nonthrowing signature.

```swift
let callback = try NativeSwiftClosure<(Bool) throws -> String> { fail in
    if fail { throw ExampleError.unavailable }
    return "ready"
}
let apply = try await ABIRuntime.shared.swiftFunction(
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

With Swift 6.3.3, give a closure expression its concrete function type before passing it to the initializer, as above. Passing an async closure expression directly into the parameter-pack initializer can crash that compiler during SIL generation or reuse a previous capture context under `NonisolatedNonsendingByDefault`. Bind the expression to a variable with the complete function type before constructing the wrapper, or pass a function reference. The [compiler-only reproduction](https://github.com/lynnswap/ABIBridge/issues/285#issuecomment-5952463646) records the capture case and its working control.

A caller-isolated signature carries the native caller's hidden isolation argument. A concurrent signature enters the generic executor before running its body; the body can perform its own actor hops. Both preserve the original Task, including task-local values, cooperative cancellation, and executor preferences. Calling `unsafeInvoke` restores the Swift caller's executor after native completion.

Pass the appropriate wrapper in an async function's metatype just as with synchronous closures:

```swift
let apply = try await ABIRuntime.shared.swiftFunction(
    named: "Example.apply(_:_:)",
    as: (@concurrent (NativeSwiftClosure<@Sendable @concurrent (Int64) async -> Int64>, Int64) async -> Int64).self
)
```

For a native factory returning a closure, put the wrapper in the factory's result type. Its descriptor, implementation image, arguments, result storage, and captured context remain alive across suspension. Native escaping copies carry the same code leases, including after repeated handoffs. Native errors use ``NativeSwiftError`` and retain their code dependencies without keeping unrelated callback captures alive.

Label-only lookup preserves the signature's `@Sendable` and async attributes. The callback initializer always requires a Sendable body, even when the native parameter accepts an ordinary closure. The wrapper itself is not Sendable: a returned foreign capture still carries its original actor and ownership requirements. Neither choosing the physical calling convention nor resolving a symbol establishes those requirements.

## Repeated callback preparation

Released callback entries can reuse one idle code/configuration page pair. Additional pages are released when they become empty. This applies to synchronous and async callbacks; the idle storage retains no callback bodies or captures.

Synchronous call preparation shares up to 64 immutable native ABI interfaces, compared by storage layout, formal indirection and error convention. Authentication hashing retains up to 128 signature descriptions. These caches contain no Swift metatypes or provider-image owners, and custom layouts are evaluated for each new preparation. Eviction does not invalidate live handles.

A prepared generic function also retains its callback's indirect-result interface. Each invocation still creates an independent forwarding context so escaping native copies retain their own captures and code owners. Reuse a callback when its capture lifetime permits it; page and interface reuse do not extend that lifetime.

## Supported signatures

The synchronous and async wrappers support ordinary guaranteed arguments and owned results:

| Family | Accepted representations |
| --- | --- |
| Scalars | Bool; signed/unsigned 8-, 16-, 32-, and 64-bit integers; Int, UInt, Float, Double, CGFloat |
| Managed values | String, Array<Element>, and their single-level optional forms; class references and AnyObject, including optional references |
| Pointer values | UnsafePointer, UnsafeMutablePointer, UnsafeRawPointer, UnsafeMutableRawPointer, OpaquePointer, Selector, and their optional forms |
| Standard value layouts | CGPoint, CGSize, CGRect, NSRange |
| Explicit Swift layouts | ABIBridgeSwiftValue conformances with established fixed or formally indirect lowering, including concrete generic nominal values |
| Empty values | Zero arguments, explicit empty-tuple arguments, and Void results |

An array's element type can itself be a managed struct, enum, optional, or another array without requiring direct-call support for that element. The compiler manages elements through the buffer's value operations. This does not make a standalone element value a supported callback argument. String and Array optionals preserve nil separately from empty payloads; nested optional containers still require an adapter.

`ABIBridgeSwiftValue` conformances use compiler-owned value operations and can therefore pass actual managed Swift values without custom conversion callbacks; see <doc:ExplicitSwiftValues>.

Custom `ABIBridgeValue` conversions describe foreign representations rather than the callback's actual Swift value types, so they remain outside this callback path. Nested closures, value Optionals without an established direct representation, generic shapes outside <doc:GenericSwiftValues>, and explicit inout/consuming callback conventions require a compiler adapter. <doc:BorrowedSwiftValues> provides a separate scoped callback for a runtime-only resilient argument.

Incoming closure-valued hook arguments are outside this subset: a native nonescaping callback can carry a stack context that cannot be retained as an owned wrapper. Hook preparation rejects that representation before installing an entry.

Label-only lookup uses the wrapper's complete function type. Use the source declaration's callback attributes and establish its isolation and Sendable contract separately. Neither a source name nor a function pointer establishes that contract.

## Ownership and failures

Preparing an unsupported signature or allocating callback entry storage can throw before the callback is published. The captured body is released if preparation fails.

Each encoded argument owns a context reference through the native call. A later argument-conversion failure releases that reference without entering native code. Ordinary calls borrow their encoded arguments; supported initializers transfer their encoded owned copies according to their existing invocation contract. Decoding an owned returned closure transfers its context into the wrapper, including cleanup if entry preparation fails.

A native caller must use the declared Swift ABI. Invalid function pointers, incompatible argument types, and violated isolation or ownership contracts are unsafe-call errors and can corrupt memory. Only a declared throwing callback can return a native Swift error. Foreign exceptions are outside both callback contracts.

## ABI and verification

A thick closure has a function pointer and a Swift capture context. The context can use closure-capture metadata rather than ordinary class metadata. The bridge uses the Swift runtime's context retain/release operations and preserves arm64e's type-dependent function-pointer authentication.

Those two words are not interchangeable across every Swift representation. A concrete callback and a function value passed through generic storage can require different argument/result lowering and authentication discriminators. The bridge creates a concrete entry for the supported signature; it does not copy an ordinary generic function value into a native callback parameter.

Compiler fixtures compare both reabstraction directions and the native result representation. Runtime checks cover capturing and noncapturing callbacks, escaping storage, owned returned contexts, zero/stack arguments, managed results, and failure cleanup. The `swift-closures` architecture mode exercises the public API against a separately compiled provider, including authenticated arm64e calls on an iPhone Air. Compilation-only coverage for other targets remains distinct from runtime execution.

See <doc:SwiftFunctionInvocation>, <doc:SwiftMemberInvocation>, and <doc:ManagedSwiftValues> for the surrounding call and storage contracts.

For a caller-isolated body passed to a native nonescaping parameter, use ``NativeSwiftClosure/withUnsafeNonescaping(_:_:)-4ragm``. The body and native invocation stay synchronous on the current executor, and neither the native callee nor the use body may save the callback.
