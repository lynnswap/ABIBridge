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
let plan = try unsafe method.prepareVirtualReplacementAndWait(with: replacement)
let previous = plan.original
// Initialize any state needed by debugRender before publishing its pointer.
try unsafe plan.install()

// Invoke the captured predecessor directly, without virtual redispatch.
let result = try unsafe previous.unsafeInvoke(on: renderer, "Preview")
try plan.restore()
```

`prepareVirtualReplacementAndWait` searches and captures the predecessor synchronously. Await `prepareVirtualReplacement` to perform that work on a worker without blocking the caller's executor:

```swift
let plan = try unsafe await method.prepareVirtualReplacement(with: replacement)
```

Both forms reuse the method's runtime indexes and join any required preparation already in progress. Neither requires an earlier `ABIRuntime.prepare` call. They create an uninstalled plan; `install()` and `restore()` remain explicit synchronous operations on the caller's thread.

Preparation changes no pointers. `original` captures the current nonnull entry, including an earlier interposer, as a nonoptional handle.

Selection locates the introducing method descriptor from the declaration that lookup selected, the same slot whose code a call of a member exported only through its dispatch thunk runs. It does not compare code addresses, which optimizers may share between unrelated methods. Earlier replacement therefore does not prevent selecting the declaration again.

Preparation compares the replacement's declaration with the original's. Each argument and the result must pass in the same registers, or by address with the same storage; arguments with ownership keep their convention; and `self`, generic metadata, and witness tables pass alike. Otherwise preparation throws ``ABIResolutionError/signatureMismatch(_:)`` naming the position, even when the two handles share their Swift function type, as `NativeSwiftValue` arguments or generic methods can. The replacement must still match isolation and accept every receiver reaching the slot, which lowering does not show. For capturing closures, use <doc:SwiftMethodHooks>.

## Understand the class scope

The type used for `resolveMethod` or `resolveMethodAndWait` determines the metadata to change. Looking up an inherited method on `PreviewRenderer` changes the copy in `PreviewRenderer` metadata, including when the symbol itself belongs to its superclass. An override uses the original introducing method descriptor to find the inherited slot and its pointer-authentication discriminator. ABIBridge names that descriptor by the same member of each ancestor class, which the remangler spells from the declaration's own symbol, and the declaring class's override table must reference it; an unrelated same-named method in a superclass is not sufficient.

Existing superclass, sibling and subclass metadata copies are unchanged. A subclass initialized after installation can inherit a modified entry; restoration of the selected class does not rewrite copies made elsewhere. Coordinate metadata initialization if this boundary matters to the application.

Only calls that read the changed metadata entry are affected. Direct, inlined, specialized or devirtualized calls and previously captured implementations can bypass it. The original `NativeSwiftMethod` remains a direct implementation handle. A compiler-instrumented `dynamic` method can independently consult Swift's dynamic-replacement machinery.

Compiled virtual replacement supports synchronous instance methods and ordinary getters/setters on concrete nongeneric classes, including initialized resilient-superclass bounds. Selection requires an introducing descriptor available to symbol lookup with a matching signature. Generic class layouts, stripped descriptors, initializer/coroutine entries, and differently lowered overrides fail selection. The operation changes the selected Swift metadata slot; Objective-C selectors, protocol witness tables, and function bodies use separate mechanisms, so a protocol requirement fails with ``ABIResolutionError/unsupportedDeclaration(_:)``.

## Inspect and restore

Use `status`, `mutation`, `restoration` and `protectionRecovery` to inspect the pointer and partial effects. Installation can fail because the platform protects a metadata page. No writable-linker option is required or applied by ABIBridge. `NativeSwiftReplacementError` uses index zero for this single entry.

Call `restore()` explicitly. It preserves a different pointer installed by another writer and permits retrying incomplete pointer or page-protection restoration. Raw comparisons cannot detect ABA changes. Releasing the plan leaves dispatch unchanged, avoiding hidden cleanup whose failure could not be returned.

Published code images and captured predecessor images remain pinned for process lifetime, so native code pointers saved by other callers remain valid after restoration or plan release. Additional code owners passed through `retaining` have that same lifetime. State accessed by the compiled replacement still needs application-owned synchronization and lifetime management.
