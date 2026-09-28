# Passing and calling Swift closures

Use ``NativeSwiftClosure`` to pass a capturing callback to a concrete Swift declaration or call a closure returned by native code.

## Pass a callback

For a loaded module declaring `func apply(_ callback: (Int64) -> Int64, value: Int64) -> Int64`:

```swift
let callback = try NativeSwiftClosure { (value: Int64) in value + 7 }
let apply = try await ABIRuntime.shared.swiftFunction(
    named: "Example.apply(_:value:)",
    as: ((NativeSwiftClosure<Int64, Int64>, Int64) -> Int64).self
)
let result = try unsafe apply.unsafeInvoke(callback, 35)
```

The first generic parameter is the result; the remaining parameters are the callback arguments, matching ``NativeSwiftFunction``. Function and member signatures accept this wrapper in place of the native Swift closure type. There is no fixed argument-count limit.

The initializer accepts a nonisolated, synchronous, nonthrowing `@Sendable` body. Its captures must be safe for the native caller's thread and concurrent calls. The generated entry translates the concrete native arguments into the compiler's generic Swift representation before calling the body. The callback may be passed to a nonescaping parameter or retained by an escaping native callee.

A retained native callback owns the Swift context that keeps its generated entry and body alive. Releasing the original wrapper does not invalidate a copy held by the callee. The last native context release releases the body and its captures; there is no separate invalidate or close operation.

## Call a returned closure

For a loaded module declaring `func makeAdder(_ bias: Int64) -> (Int64) -> Int64`:

```swift
let factory = try await ABIRuntime.shared.swiftFunction(
    named: "Example.makeAdder(_:)",
    as: ((Int64) -> NativeSwiftClosure<Int64, Int64>).self
)
let addSeven = try unsafe factory.unsafeInvoke(7)
let result = try unsafe addSeven.unsafeInvoke(35)
```

The returned wrapper adopts the native closure's owned context and retains the declaring/type images, explicit implementation code owner, and the closure entry's containing image when available. Temporary receiver and argument storage stays with the call; returning a closure does not add a receiver capture. A concrete forwarding context carries those owners into native escaping copies as well. Entries already owned by the closure allocator keep their existing context, so repeated identity handoffs do not add forwarding layers. The original context is released while its code owners are still alive. Additional native resources or code images referenced indirectly by a foreign capture must obey their original lifetime contract.

Calling stays on the caller's executor. The caller must satisfy the returned closure's actor, thread, and argument requirements. The wrapper is not Sendable: an arbitrary returned context may contain isolated or otherwise non-Sendable state.

## Supported signatures

The initial subset supports synchronous, nonthrowing closures with ordinary guaranteed arguments and owned results:

| Family | Accepted representations |
| --- | --- |
| Scalars | Bool; signed/unsigned 8-, 16-, 32-, and 64-bit integers; Int, UInt, Float, Double, CGFloat |
| Managed values | String; class references and AnyObject, including optional references |
| Pointer values | UnsafePointer, UnsafeMutablePointer, UnsafeRawPointer, UnsafeMutableRawPointer, OpaquePointer, Selector, and their optional forms |
| Standard value layouts | CGPoint, CGSize, CGRect, NSRange |
| Empty values | Zero arguments, explicit empty-tuple arguments, and Void results |

Custom `ABIBridgeValue` conversions can throw, while a nonthrowing native callback has no error-result channel. They are therefore outside this callback subset. Nested closures, value Optionals without an established direct representation, generic declarations, async/throwing callbacks, and explicit inout/consuming callback conventions require a compiler adapter.

Incoming closure-valued hook arguments are outside this subset: a native nonescaping callback can carry a stack context that cannot be retained as an owned wrapper. Hook preparation rejects that representation before installing an entry.

Label-only lookup uses an ordinary Swift function type for this wrapper. If the native declaration spells additional callback-type attributes, use its full source-level declaration and establish the corresponding isolation and Sendable contract separately. Neither a source name nor a function pointer establishes that contract.

## Ownership and failures

Preparing an unsupported signature or allocating callback entry storage can throw before the callback is published. The captured body is released if preparation fails.

Each encoded argument owns a context reference through the native call. A later argument-conversion failure releases that reference without entering native code. Ordinary calls borrow their encoded arguments; supported initializers transfer their encoded owned copies according to their existing invocation contract. Decoding an owned returned closure transfers its context into the wrapper, including cleanup if entry preparation fails.

A native caller must use the declared Swift ABI. Invalid function pointers, incompatible argument types, and violated isolation or ownership contracts are unsafe-call errors and can corrupt memory. Native Swift errors and foreign exceptions cannot cross this nonthrowing callback boundary.

## ABI and verification

A thick closure has a function pointer and a Swift capture context. The context can use closure-capture metadata rather than ordinary class metadata. The bridge uses the Swift runtime's context retain/release operations and preserves arm64e's type-dependent function-pointer authentication.

Those two words are not interchangeable across every Swift representation. A concrete callback and a function value passed through generic storage can require different argument/result lowering and authentication discriminators. The bridge creates a concrete entry for the supported signature; it does not copy an ordinary generic function value into a native callback parameter.

Compiler fixtures compare both reabstraction directions and the native result representation. Runtime checks cover capturing and noncapturing callbacks, escaping storage, owned returned contexts, zero/stack arguments, managed results, and failure cleanup. The `swift-closures` architecture mode exercises the public API against a separately compiled provider, including authenticated arm64e calls on an iPhone Air. Compilation-only coverage for other targets remains distinct from runtime execution.

See <doc:SwiftFunctionInvocation>, <doc:SwiftMemberInvocation>, and <doc:ManagedSwiftValues> for the surrounding call and storage contracts.
