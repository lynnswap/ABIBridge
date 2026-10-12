# Replacing compiled Swift virtual methods

Select a class method by its source declaration and replace the entry in that class's Swift metadata with an ABI-compatible compiled method.

## Prepare and publish

```swift
let type = try runtime.resolveSwiftTypeAndWait(named: "Rendering.Renderer")
let method = try type.resolveMethodAndWait(
    named: "render(_:)", as: ((String) -> String).self
)
let replacement = try type.resolveMethodAndWait(
    named: "debugRender(_:)", as: ((String) -> String).self
)
let plan = try unsafe method.prepareVirtualReplacement(with: replacement)
let previous = plan.original
// Initialize any state needed by debugRender before publishing its pointer.
try unsafe plan.install()

// Invoke the captured predecessor directly, without virtual redispatch.
let result = try unsafe previous.unsafeInvoke(on: renderer, "Preview")
try plan.restore()
```

Preparation changes no pointers. `original` captures the current nonnull entry, including an earlier interposer, as a nonoptional handle.

Selection locates the introducing method descriptor by its source declaration and class layout. It does not compare code addresses, which optimizers may share between unrelated methods. Earlier replacement therefore does not prevent selecting the declaration again.

The compiled replacement must match receiver, argument/result lowering, ownership, and isolation, and accept every receiver reaching the slot. Equal function types do not prove that contract. For capturing closures, use <doc:SwiftMethodHooks>.

## Understand the class scope

The type used for `resolveMethod` or `resolveMethodAndWait` determines the metadata to change. Looking up an inherited method on `PreviewRenderer` changes the copy in `PreviewRenderer` metadata, including when the symbol itself belongs to its superclass. An override uses the original introducing method descriptor to find the inherited slot and its pointer-authentication discriminator. The declaring class's override table must reference that descriptor; an unrelated same-named method in a superclass is not sufficient.

Existing superclass, sibling and subclass metadata copies are unchanged. A subclass initialized after installation can inherit a modified entry; restoration of the selected class does not rewrite copies made elsewhere. Coordinate metadata initialization if this boundary matters to the application.

Only calls that read the changed metadata entry are affected. Direct, inlined, specialized or devirtualized calls and previously captured implementations can bypass it. The original `NativeSwiftMethod` remains a direct implementation handle. A compiler-instrumented `dynamic` method can independently consult Swift's dynamic-replacement machinery.

Compiled virtual replacement supports synchronous instance methods and ordinary getters/setters on concrete nongeneric classes, including initialized resilient-superclass bounds. Selection requires an introducing descriptor available to symbol lookup with a matching signature. Generic class layouts, stripped descriptors, initializer/coroutine entries, and differently lowered overrides fail selection. The operation changes the selected Swift metadata slot; Objective-C selectors, protocol witness tables, and function bodies use separate mechanisms.

## Inspect and restore

Use `status`, `mutation`, `restoration` and `protectionRecovery` to inspect the pointer and partial effects. Installation can fail because the platform protects a metadata page. No writable-linker option is required or applied by ABIBridge. `NativeSwiftReplacementError` uses index zero for this single entry.

Call `restore()` explicitly. It preserves a different pointer installed by another writer and permits retrying incomplete pointer or page-protection restoration. Raw comparisons cannot detect ABA changes. Releasing the plan leaves dispatch unchanged, avoiding hidden cleanup whose failure could not be returned.

Published code images and captured predecessor images remain pinned for process lifetime, so native code pointers saved by other callers remain valid after restoration or plan release. Additional code owners passed through `retaining` have that same lifetime. State accessed by the compiled replacement still needs application-owned synchronization and lifetime management.
