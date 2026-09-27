# Hooking Swift methods

Inspect a Swift method's receiver, edit object properties or arguments, and transform the result through a scoped capturing closure.

## Select virtual dispatch or imported calls

Resolve the class and method using source names and an ordinary Swift function type:

```swift
let renderer = try await runtime.swiftType(named: "Rendering.Renderer")
let render = try await renderer.method(
    named: "render(_:)", as: ((String) -> String).self
)
let hook = try await unsafe render.hookVirtualCalls(
    onFailure: { error in print(error) }
) { call, text in
    let receiver = try call.receiver(as: AnyObject.self)
    print(type(of: receiver), call.declaration, call.signature)
    let result = try call.proceed(text + " edited")
    return result + " inspected"
}
// Keep the registration for as long as the callback is needed.
hook.invalidate()
```

When the receiver type is importable, `call.receiver(as: Renderer.self)` returns the same instance and permits ordinary property access before or after `proceed`. For a private type, prepare getter/setter handles before installing the hook, then call their synchronous `unsafeInvoke(on:)` operations using the receiver. These handles call their captured implementation rather than redispatching through the hooked entry.

Use `method.hookImportedCalls(in:using:onFailure:body:)` to intercept references to a concrete member implementation in loaded callers. A final method has no virtual table entry, but can still have importing references. An ordinary virtual call does not necessarily use an import reference. Value methods use importing references; they do not acquire a class metadata table. Import selection follows the loaded-image, provider-filter and protection contracts in <doc:SwiftFunctionHooks>.

## Inspect value receivers

Imported-member hooks also accept the concrete value representation selected during type lookup. For a native counter whose fixed storage is one `Int64`:

```swift
let counter = try await runtime.swiftType(
    named: "Rendering.Counter", as: Int64.self
)
let increment = try await counter.method(
    named: "increment(_:)", as: ((Int64) -> Int64).self,
    mutating: true
)
let hook = try await unsafe increment.hookImportedCalls(
    in: .framework(named: "PreviewClient"),
    onFailure: { error in print(error) }
) { call, delta in
    let before = try call.receiver(as: Int64.self)
    let result = try call.proceed(delta + 1)
    let after = try call.receiver(as: Int64.self)
    print(before, after)
    return result
}
```

Value reads return snapshots in the supplied representation. Changing that local copy does not replace native self. Reference fields keep their normal identity and pointer adapters keep their own lifetime rules. A mutating method proceeds with the original caller's receiver address, so native writes remain visible to the caller and later snapshots even if the hook throws afterward. Nonmutating small values retain their trailing-argument position; larger established values use their native indirect context.

Select `consuming: true` only when the native member consumes self. Each continuation gets an independent owned copy using the selected codec, and the unused incoming ownership is disposed of once. This covers known String/reference representations and fixed trivial adapters; it does not infer destruction for arbitrary nontrivial foreign layouts. Ordinary setters consume their explicit value independently of a borrowing receiver. Registrations sharing a slot must agree on receiver representation and ownership.

## Understand the scope

Virtual selection uses the lookup type's metadata and the introducing declaration descriptor. Inherited and overridden methods select the copied entry belonging to that type. Already separate superclass and sibling entries are unchanged; subclasses initialized later can copy the installed dispatcher. Such copies and saved dispatcher pointers share its callback chain, including registrations added after earlier callbacks were invalidated.

The callback applies to every receiver reaching that dispatcher. It is not filtered to a single object. Direct, final, devirtualized or inlined calls and previously captured original implementations can bypass virtual dispatch. If an import reference and a selected metadata entry identify the same physical storage and authentication schema, the two operations share one chain rather than publishing competing dispatchers.

Later registrations wrap earlier ones. Each `proceed` follows the captured snapshot and then its predecessor using the actual incoming receiver. It does not look the method up again. An earlier interposer can be that predecessor.

## Preserve ownership and isolation

Receiver reads and continuations are valid only on the entering thread while their callback is active. Escaped or cross-thread access throws `NativeSwiftHookInvocationError`. A copied class reference or managed value snapshot has its normal Swift ownership and can outlive the callback; a pointer adapter keeps its declared pointee-lifetime obligations. Saving the invocation itself does not retain the receiver instance or callback captures after return.

A method resolved with `consuming: true` gets an independent owned receiver reference for each continuation. The bridge disposes of the unused incoming ownership if the closure skips the native implementation. Getter results and setter arguments keep their Swift ownership conventions; resolve a setter using `setter(named:as:)` so its consumed argument contract is established.

Ordinary callbacks stay on the incoming thread. `hookMainActorVirtualCalls` and `hookMainActorImportedCalls` express a caller-supplied MainActor contract. They report background entry and bypass that callback before decoding its arguments or receiver. There is no executor hop, and the error observer must be thread-safe.

Callback/conversion failures follow <doc:SwiftFunctionHooks>: before a completed continuation, the current arguments pass to the remaining chain; after a continuation, its latest completed result survives without replaying native side effects. Object property mutations already performed by the callback or native implementation are not rolled back.

## Invalidate and inspect failures

`NativeSwiftVirtualHook` exposes the selected address, current status, mutation, rollback and protection-recovery observations. Imported methods return the same multiple-reference registration as imported functions. Invalidation releases callback captures after in-flight snapshots finish and leaves stable pass-through code installed. Published code and required metadata/image owners remain process-lived; the registration does not retain particular receiver instances.

Preparation failures publish nothing. A failed virtual installation throws `NativeSwiftVirtualHookInstallationError` with an invalidated registration; imported installation uses `NativeSwiftHookInstallationError`. Inspect the registration and call `recoverFailedInstallation()` to retry owned pointer/protection cleanup. External writers and page protections can prevent mutation or recovery. Pointer comparisons preserve a different writer's value but cannot detect ABA changes; callers must coordinate those writers.

## Supported boundary

This interface requires initialized instances and a known synchronous, nonthrowing Swift calling convention. Initializers, deinitializers, yielding accessors and unestablished class metadata layouts require separate support. Known asynchronous virtual descriptors are rejected. Property getter names and ordinary getter descriptors do not encode throwing effects, so a source name and metatype cannot establish that a getter is nonthrowing; the caller must know that contract.

The class interface preserves the selected method's receiver representation and requires a compatible class for typed receiver reads. Native async/throws/generic effects, unestablished resilient/nontrivial value layouts, and SwiftUI-specific work remain separate workstreams. The low-level compiled replacement interfaces remain available for separately established ABI contracts.

## Validation boundary

Compiled macOS fixtures verify class scope and receiver identity, mutable property access, getter/setter ownership, repeated consuming continuations, MainActor/background entry, escaped views, and shared imported/virtual selection. An arm64e iPhone run passed 16 checks, including authentication on the same inherited entry selected through both APIs. arm64e.x1 compilation is validated separately; matching-device execution remains outstanding.

Value-receiver fixtures additionally cover original-address mutation, consuming String/reference ownership, large indirect receivers/results, nonmutating setters and trailing self after stack arguments. An arm64e iPhone run passed 12 value-hook checks with pointer authentication enabled. These tests establish the supplied concrete layouts; they do not establish arbitrary nontrivial or resilient value representations.
