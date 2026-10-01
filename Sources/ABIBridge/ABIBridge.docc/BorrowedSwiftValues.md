# Borrowing runtime-only Swift values

Receive a resilient value in a synchronous callback and call its members using its actual runtime type, without importing that type or substituting another Swift value.

## Prepare the type and members

Resolve a nongeneric nominal type with `ABIRuntime.swiftType(named:in:loading:)`. Use `borrowedGetter(named:as:)` or `borrowedMethod(named:as:)` to prepare its synchronous, nonthrowing, nonmutating and nonconsuming members. These APIs explicitly select formally indirect self. The target declaration must actually use that convention; metadata size and alignment alone do not establish it.

For an independently compiled module with a resilient `Record`, a `text: String` getter and `func visit(_ body: (Record) -> Void)`, a consumer can prepare everything before native callback entry:

```swift
nonisolated(nonsending) func visitRecords(
    onValue: @escaping @Sendable (String) -> Void,
    onFailure: @escaping @Sendable (any Error) -> Void
) async throws {
    let runtime = ABIRuntime.shared
    let type = try await runtime.swiftType(named: "Example.Record")
    let text = try await type.borrowedGetter(named: "text", as: String.self)
    let visit = try await runtime.swiftFunction(
        named: "Example.visit((Example.Record) -> ()) -> ()",
        as: ((NativeSwiftBorrowingClosure<Void>) -> Void).self
    )
    let callback = try NativeSwiftBorrowingClosure(borrowing: type) { record in
        do {
            onValue(try unsafe text.unsafeInvoke(on: record))
        } catch {
            onFailure(error)
        }
    }
    try unsafe visit.unsafeInvoke(callback)
}
```

A complete source-level declaration supplies the runtime callback argument's name. Ordinary function-type inference cannot recover that name from `NativeSwiftBorrowingClosure<Void>`. The native callback must receive the exact supplied type as one formally indirect, guaranteed argument. Its concrete result can use the representations supported by ``NativeSwiftClosure``.

## Keep the borrow inside each callback

``NativeSwiftBorrowedValue`` refers to the caller's original initialized storage. The bridge does not copy or destroy it, including when invoking a member. A member checks actual metadata identity before dispatch. Managed getter and method results retain their ordinary Swift result ownership and can outlive the borrowed receiver.

The callback itself may escape and be called repeatedly; its native capture context retains its body, type and code owners. Each invocation receives a separate borrow which expires when that body returns. Saving the handle does not extend the storage lifetime. Later access throws `expiredBorrow`, and access from another thread throws `wrongThread`. The value is not Sendable. Type diagnostics may be retained after return, but do not make value access valid.

Callbacks execute synchronously on the native caller's thread. Prepare member handles before entry, and satisfy the declaration's actor or thread requirements at the calling boundary. No task or actor hop is introduced. A nonthrowing callback must handle member-invocation errors within its body, as the example reports them through `onFailure`.

The initial subset excludes mutating/consuming self, arbitrary inferred by-value layouts, owned copies escaping the borrow, and returned runtime-typed closures. Use <doc:ManagedSwiftValues> for existing compiler-adapter ownership operations. Generic outer entry points can use the explicit substitutions in <doc:GenericSwiftValues> with this borrowed callback as a concrete parameter.

## Verification boundary

`SwiftBorrowedValueTests` uses a separately compiled library-evolution provider, covering a managed payload, String and object getters, nonmutating methods, repeated and retained callbacks, expired/wrong-thread borrows, and reference release. `SwiftRuntimeValueConsumer` imports only ABIBridge and calls the same runtime-only type after its lookup runtime and original loader reference end. It also combines the borrow with a generic outer function. These are macOS arm64 runtime checks in Debug and Release; Swift's own runtime may keep provider images loaded independently.

`check-swift-generic-call-codegen.py` records formally indirect parameters, generic results and member self on arm64, x86_64, arm64e and arm64_32, and checks arm64e callback authentication discriminators against compiler-emitted calls. This compilation evidence does not establish execution coverage or authenticated runtime support for those other architectures.
