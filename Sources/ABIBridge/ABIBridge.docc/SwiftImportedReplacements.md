# Replacing compiled Swift imports

Replace selected importing references with another compiled Swift implementation, preserving typed access to the previous entries and explicit restoration.

For a capturing closure with typed arguments and a scoped `proceed` continuation, use <doc:SwiftFunctionHooks>.

## Prepare before publishing

Resolve the original declaration and its compiled replacement using ordinary Swift function types:

```swift
let original = try await runtime.swiftFunction(
    named: "Rendering.transform(_:)", as: ((String) -> String).self
)
let replacement = try await runtime.swiftFunction(
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

Preparation reads and retains the selected loaded importing images and captures their current code pointers. It changes no dispatch. Each slot's `original` calls that captured entry using the supplied Swift ABI; it can differ from the directly resolved `original` handle if another writer already interposed the slot. A null weak reference has a nil captured implementation.

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

Keep the plan to call `restore()` explicitly. Releasing it does not undo dispatch changes or run hidden cleanup that could fail. Preparation is reversible without any restoration because it publishes nothing.

An installation failure attempts to restore earlier writes. `NativeSwiftReplacementError` identifies the failed publication and any failed rollback indexes. Inspect `slots` for the original mutation, restoration and protection-recovery results. A pointer write and its page-protection restoration can have different outcomes. Outstanding restoration and failed protection recovery can be retried; successful pointer restoration alone is not reported as complete when protection repair remains.

Restoration compares the current representation before writing, leaving another writer's different pointer unchanged. A reference already restored to the captured bits needs no additional pointer write. Coordinate other writers and page-protection changes; raw pointer comparisons cannot detect ABA changes. TPRO-protected references may reject installation without any write, even when their maximum protection includes WRITE.

Published replacement code images and captured predecessor code images remain pinned for process lifetime, including after restoration and plan release, so saved code pointers remain callable. Known image generations are shared by that keepalive. Code outside loader images needs the optional `retaining` owner, or a lifetime maintained by the caller; additional owners supplied for published code have the same process lifetime. Arbitrary mutable state used by those implementations remains the caller's responsibility.

## Validation boundary

Optimized fixtures cover scalar, heap-backed String, indirect value results and concrete struct member context. The caller and replacement are compiled separately. An iPhone Air / iOS 27.0 / arm64e run passed these same cases with authenticated calls in separately compiled, signed fixture frameworks. The normally linked caller reported TPRO refusal without mutation; the disposable `-no_data_const` caller completed replacement and restoration. That option belongs only to the validation fixture, not package or consumer settings. arm64e.x1 runtime behavior remains unverified. Generic, async, throwing and unsupported value signatures retain the invocation API's existing limitations. Previously captured instrumented `dynamic` entries can still consult compiler dynamic-replacement machinery; capturing their pointer does not bypass that instrumentation.
