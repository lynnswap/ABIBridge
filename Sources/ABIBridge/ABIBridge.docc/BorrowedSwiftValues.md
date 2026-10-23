# Borrowing runtime-only Swift values

Receive a runtime-only value in a native callback and call its members using its actual runtime type, without importing that type or substituting another Swift value.

## Prepare the type and members

Resolve the nominal type and prepare ordinary getter or method handles; `resolveAndWait` selects synchronous lookup. The same member handle accepts an owned ``NativeSwiftValue`` or an active ``NativeSwiftBorrowedValue``.

Supply `receiverABI` when the receiver's passing convention is unavailable from its representation, its generic declaration, or the convention inferred from its metadata; see <doc:SwiftFunctionInvocation#Infer-struct-and-enum-conventions>. Use `.opaque` for formally indirect self and established components for a direct value.

For an independently compiled module with a resilient `Record`, a `text: String` getter and `func visit(_ body: (Record) -> Void)`, a consumer can prepare everything before native callback entry:

```swift
nonisolated(nonsending) func visitRecords(
    onValue: @escaping @Sendable (String) -> Void,
    onFailure: @escaping @Sendable (any Error) -> Void
) async throws {
    let runtime = ABIRuntime.shared
    let type = try await runtime.resolveSwiftType(named: "Example.Record")
    let text = try await type.resolve(.getter("text", as: (() -> String).self, receiverABI: .opaque(named: type.name)))
    let visit = try await runtime.resolve(.function(
        "Example.visit((Example.Record) -> ()) -> ()",
        as: ((NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void>) -> Void).self,
        valueABIs: [type: .opaque(named: type.name)]
    ))
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

A complete source declaration identifies the callback's native argument type. `valueABIs` supplies the passing convention for a closed nominal value unavailable to the host when ABIBridge cannot infer it. Here `.opaque` means formally indirect passing; metadata provides dimensions and value operations. A fixed value with established direct components can use `NativeType.structure`.

The map applies to this lookup, including nested callbacks and member arguments/results. Generic archetypes keep the original declaration's lowering.

## Keep the borrow inside each callback

``NativeSwiftBorrowedValue`` grants scoped access to an initialized native value without transferring ownership of the caller's value. The bridge retains any storage needed to present that view until callback completion. A member checks actual metadata identity before dispatch. Managed getter and method results retain their ordinary Swift result ownership and can outlive the borrowed receiver.

The callback may escape and run repeatedly, retaining its body, types, and code. Each invocation receives a separate borrow that expires when the body returns. Saving a view preserves type diagnostics but does not extend value access. Later access throws `expiredBorrow`; synchronous access from another thread throws `wrongThread`. The view is not Sendable.

The synchronous callback above executes on the native caller's thread. Prepare member handles before entry, and satisfy the declaration's actor or thread requirements at the calling boundary. No task or actor hop is introduced. A nonthrowing callback must handle member-invocation errors within its body, as the example reports them through `onFailure`.

Call `copy()` on an active view to create an independent owner that can outlive the callback. The payload must be Copyable and Escapable; otherwise copying throws `NativeSwiftValueError.noncopyableType` or `ABIResolutionError.unsupportedDeclaration`. ``NativeSwiftValue/withBorrowedValue(_:)`` provides a scoped view of an owned value.

## Borrow across suspension

A synchronous native callback's borrow cannot begin an async member call: it throws `NativeSwiftBorrowError.synchronousBorrow`, because the caller may release storage when the callback returns. An owned-value borrow can start an async member call while active; that operation retains read access through completion. The view itself still expires at scope exit.

Async callbacks may borrow across suspension. Await every operation using a native input before the body returns; its views then expire. Multiple inputs, generic packs, and tuple fields use the same lifetime. Use a borrowed-value handle for runtime fields and ``NativeSwiftClosure`` for closure fields; see <doc:SwiftClosureValues>.

## Mutate or consume a value

An ordinary view is read-only. A native `inout` callback input grants exclusive mutation access until completion, including when the payload is noncopyable. It cannot be consumed.

An owned value supports mutating and consuming members, including async methods. Access lasts through native completion. Mutation remains in its storage even if the method throws. Consumption marks all aliases consumed once native code takes the payload; a failure before entry leaves it owned. Conflicting access through another alias throws `NativeSwiftValueError.valueInUse`. See <doc:SwiftOpaqueResults> for owned-value transfers and <doc:SwiftArgumentConventions> for inout buffers.

## Verification

Tests use a separately compiled resilient provider to check member results, borrow expiry, thread checks, and reference release on macOS arm64 in Debug and Release. An external consumer imports only ABIBridge and uses the runtime value after the original lookup and loader reference end. Swift's runtime may also keep provider images loaded independently.

Device callback/member checks and cross-architecture compiler probes are recorded in the [architecture validation guide](https://github.com/lynnswap/ABIBridge/blob/main/Tests/ArchitectureValidation/README.md). For the earlier borrowing-closure API, see <doc:SwiftAPIMigration>.
