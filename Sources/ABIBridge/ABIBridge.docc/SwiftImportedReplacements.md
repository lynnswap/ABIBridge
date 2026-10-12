# Replacing compiled Swift imports

Replace selected importing references with another compiled Swift implementation, preserving typed access to the previous entries and explicit restoration.

For a capturing closure with typed arguments and a scoped `proceed` continuation, use <doc:SwiftFunctionHooks>.

## Prepare before publishing

Resolve the original declaration and its compiled replacement using ordinary Swift function types:

```swift
let original = try await runtime.resolveSwiftFunction(
    named: "Rendering.transform(_:)", as: ((String) -> String).self
)
let replacement = try await runtime.resolveSwiftFunction(
    named: "Rendering.debugTransform(_:)", as: ((String) -> String).self
)
let plan = try await unsafe original.prepareImportedReplacement(
    with: replacement, in: .framework(named: "PreviewClient")
)

let previous = plan.slots.compactMap(\.original)
// Initialize any state the compiled replacement needs, using these entries.
try unsafe plan.install()
// ...
try plan.restore()
```

Preparation retains the selected loaded importers and captures their pointers without changing dispatch. Each slot's `original` calls its captured entry with the supplied ABI. An earlier interposer can make that entry differ from the directly resolved function; a null weak reference yields nil.

Calls may enter the new implementation as soon as the first pointer is written. Prepare and synchronize replacement-owned state before installation. ABIBridge synchronizes its own operations, not globals accessed by the compiled replacement. Multiple pointers cannot be published atomically as a group.

## Preserve the native contract

The replacement must be a compiler-generated entry with the same physical calling convention, context, ownership, argument and result lowering, and isolation requirements. Equal Swift function-type metatypes do not prove the full native contract. Capturing closures use a separate representation and cannot be passed as compiled entries.

`NativeSwiftMethod.prepareImportedReplacement` provides the corresponding operation for references to a concrete member. Its captured originals support `unsafeInvoke(on:_:)` with the original receiver plan, including selected mutation and ownership. This operation changes importing references; it does not modify a class's metadata table.

Direct, inlined and specialized calls that bypass the selected pointers are unaffected. Same-image calls need suitable interposable linking to have replaceable references. The optional provider filter matches the dependency recorded in the binding, including reexport facades. It does not match the address of the currently installed implementation. No importing images are loaded automatically.

For a nullable captured member, unwrap the handle before invoking it:

```swift
if let previous = plan.slots.first?.original {
    try unsafe previous.unsafeInvoke(on: receiver, argument)
}
```

Swift 6.3.3 Debug code generation can over-release a reference receiver when optional chaining a member that forwards a parameter pack. A local unwrapped handle avoids that compiler issue. This was reproduced without ABIBridge; see [the minimal reproduction](https://github.com/lynnswap/ABIBridge/issues/157). The concrete virtual-method API returns a nonoptional predecessor.

## Restore and inspect partial effects

Keep the plan and call `restore()` explicitly. Releasing it leaves dispatch changes in place. A plan that has only been prepared needs no restoration.

Installation failure attempts to restore earlier writes. ``NativeSwiftReplacementError`` identifies the failed publication and rollback indexes. Inspect `slots` for pointer mutation, restoration, and protection recovery. Retry outstanding recovery; restoration is incomplete while page-protection repair remains.

Restoration compares the current representation before writing, leaving another writer's different pointer unchanged. A reference already restored to the captured bits needs no additional pointer write. Coordinate other writers and page-protection changes; raw pointer comparisons cannot detect ABA changes. TPRO-protected references may reject installation without any write, even when their maximum protection includes WRITE.

Published replacement and predecessor images remain pinned for process lifetime, including after restoration, so saved pointers remain callable. For code outside loader images, supply `retaining` or maintain its lifetime yourself. Supplied owners also become process-lived. The caller still manages mutable state accessed by those implementations.

## Verification and dispatch limits

Separately compiled fixtures check scalar, String, indirect-result, and value-member calls. Protected normal imports can reject mutation; writable controls separately check replacement and restoration. Device configurations are recorded in the [architecture validation guide](https://github.com/lynnswap/ABIBridge/blob/main/Tests/ArchitectureValidation/README.md). arm64e.x1 execution remains unverified, and signatures retain the invocation API's representation limits.

Captured compiler-instrumented `dynamic` entries may still consult Swift's dynamic-replacement machinery. Capturing their pointer does not bypass that instrumentation.
