# Borrowing runtime-only Swift values

Receive a runtime-only value in a native callback and call its members using its actual runtime type, without importing that type or substituting another Swift value.

## Prepare the type and members

Resolve the nominal type with `ABIRuntime.swiftType(named:in:loading:)` and prepare ordinary `getter` or `method` handles. The same handle accepts an owned NativeSwiftValue or an active NativeSwiftBorrowedValue. Supply an opaque `receiverABI` for formally indirect self, or established fixed components for a direct value. Metadata supplies storage dimensions; it cannot establish the declaration's passing convention. Generic member planning supplies self conventions encoded by its formal declaration.

For an independently compiled module with a resilient `Record`, a `text: String` getter and `func visit(_ body: (Record) -> Void)`, a consumer can prepare everything before native callback entry:

```swift
nonisolated(nonsending) func visitRecords(
    onValue: @escaping @Sendable (String) -> Void,
    onFailure: @escaping @Sendable (any Error) -> Void
) async throws {
    let runtime = ABIRuntime.shared
    let type = try await runtime.swiftType(named: "Example.Record")
    let text = try await type.getter(named: "text", as: (() -> String).self, receiverABI: .opaque(named: type.name))
    let visit = try await runtime.swiftFunction(
        named: "Example.visit((Example.Record) -> ()) -> ()",
        as: ((NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void>) -> Void).self,
        valueABIs: [type: .opaque(named: type.name)]
    )
    let callback = try NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void> { record in
        do {
            onValue(try unsafe text.unsafeInvoke(on: record))
        } catch {
            onFailure(error)
        }
    }
    try unsafe visit.unsafeInvoke(callback)
}
```

A complete source-level declaration supplies the runtime callback argument's name. `valueABIs` supplies the formal passing convention for a closed nominal value whose ABI is unavailable to the host. In this example `.opaque` declares formally indirect passing; metadata provides storage dimensions and value witnesses. A frozen value with established direct components can use a `NativeType.structure` instead. The map belongs to this lookup and also applies to nested callbacks and member argument/result preparation. Generic archetype lowering continues to follow the native declaration. Metadata size alone does not establish this contract.

## Keep the borrow inside each callback

``NativeSwiftBorrowedValue`` refers to the caller's original initialized storage. The bridge does not copy or destroy it, including when invoking a member. A member checks actual metadata identity before dispatch. Managed getter and method results retain their ordinary Swift result ownership and can outlive the borrowed receiver.

The callback itself may escape and be called repeatedly; its native capture context retains its body, type and code owners. Each invocation receives a separate borrow which expires when that body returns. Saving the handle does not extend the storage lifetime. Later access throws `expiredBorrow`; a synchronous borrow accessed from another thread throws `wrongThread`. The value is not Sendable. Type diagnostics may be retained after return, but do not make value access valid.

The synchronous callback above executes on the native caller's thread. Prepare member handles before entry, and satisfy the declaration's actor or thread requirements at the calling boundary. No task or actor hop is introduced. A nonthrowing callback must handle member-invocation errors within its body, as the example reports them through `onFailure`.

Call `copy()` on an active borrowed view to create an independent NativeSwiftValue. Copying requires a copyable native type; otherwise it throws NativeSwiftValueError.noncopyableType. An owned copy also requires Escapable: a nonescapable type reports ABIResolutionError.unsupportedDeclaration instead of escaping its native scope. The owner can outlive the callback and uses the same prepared member handles. NativeSwiftValue.withBorrowedValue provides the reverse path, a scoped view of an owned value.

A borrowed view from a synchronous native callback cannot begin an async member call: it throws NativeSwiftBorrowError.synchronousBorrow because the native caller can release that storage when the callback returns. An owned-value borrow can begin an async member call while active; the operation retains read access until native completion. The view still expires when its scope ends, and saving the view alone never prolongs access.

An ordinary borrowed view cannot mutate or consume its native value. A native `inout` callback parameter provides a view with exclusive mutation access; it still cannot consume the value, and the view expires at callback completion. An owned value supports mutating and consuming members, including async methods: access remains active through native completion. Mutation updates the owned storage even when the native method throws. Consumption marks the owner consumed after the native call takes its value; a failure before invocation leaves it owned. Copying, borrowing, or consuming through another alias during exclusive access throws NativeSwiftValueError.valueInUse.

Async callback signatures can borrow across suspension. The body must await operations using those native inputs before returning; saved views still expire at completion. Multiple runtime inputs, mixed known types, native errors, and generic packs share the same closure API. Generic outer entry points use explicit type arguments in <doc:GenericSwiftValues>.

## Verification boundary

`SwiftBorrowedValueTests` uses a separately compiled library-evolution provider, covering a managed payload, String and object getters, nonmutating methods, repeated and retained callbacks, expired/wrong-thread borrows, and reference release. `SwiftRuntimeValueConsumer` imports only ABIBridge and calls the same runtime-only type after its lookup runtime and original loader reference end. It also combines the borrow with a generic outer function. These checks run on macOS arm64 in Debug and Release. The `swift-generic-borrows` device probe passed all 49 checks with the common closure API on iPhone Air with iOS 27.0.1 (24A446), Xcode 27.0 / Swift 6.4, Release arm64e with pointer authentication enabled. Swift's own runtime may keep provider images loaded independently.

`check-swift-generic-call-codegen.py` records formally indirect parameters, generic results and member self on arm64, x86_64, arm64e and arm64_32, and checks arm64e callback authentication discriminators against compiler-emitted calls. Compilation evidence does not establish execution coverage on x86_64 or arm64_32; the iPhone Air run separately verifies the arm64e callback and member paths.

The former `NativeSwiftBorrowingClosure(borrowing:)` API is replaced by `NativeSwiftClosure` with a `NativeSwiftBorrowedValue` parameter and `valueABIs` on the lookup. The same handle supports multiple arguments, owned values, native errors, async calls, and nested or returned closures; see <doc:SwiftClosureValues>.
