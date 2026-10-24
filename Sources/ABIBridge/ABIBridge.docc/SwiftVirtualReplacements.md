# Replacing compiled Swift virtual methods

Select a class method by its source declaration and replace the entry in that class's Swift metadata with an ABI-compatible compiled method.

## Prepare and publish

```swift
let type = try runtime.resolveSwiftTypeAndWait(named: "Rendering.Renderer")
let method = try type.resolveAndWait(.swift(.method(
    "render(_:)", as: ((String) -> String).self
)))
let replacement = try type.resolveAndWait(.swift(.method(
    "debugRender(_:)", as: ((String) -> String).self
)))
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

## Replace class members

A `class func`, and a `class var`'s or `class subscript`'s getter and setter, receive their class's metatype as `self` and dispatch through entries of the class's metadata. Resolve them with `staticMethod`, `staticGetter`, or `staticSetter` requests, and prepare the replacement on the returned `NativeSwiftFunction`:

```swift
let scale = try type.resolveAndWait(.swift(.staticMethod(
    "scale(for:)", as: ((Double) -> Double).self
)))
let replacement = try type.resolveAndWait(.swift(.staticMethod(
    "debugScale(for:)", as: ((Double) -> Double).self
)))
let plan = try unsafe scale.prepareVirtualReplacementAndWait(with: replacement)
try unsafe plan.install()
// The predecessor runs with the lookup type's metatype as self.
let previous = try unsafe plan.original.unsafeInvoke(2.0)
try plan.restore()
```

Selection, class scope, and restoration follow the rules for methods. The replacement may receive a metatype as `self`, as another class member does, or ignore it, as a free function does; its arguments and result must pass as the original's do. A `static` or `final class` member has no entry, and preparation throws ``ABIResolutionError/unsupportedDeclaration(_:)`` for it, as for free functions and the static members of structs and enums.

## Understand the class scope

The type that resolves the member's request determines the metadata to change. Looking up an inherited method on `PreviewRenderer` changes the copy in `PreviewRenderer` metadata, including when the symbol itself belongs to its superclass. An override uses the original introducing method descriptor to find the inherited slot and its pointer-authentication discriminator. ABIBridge names that descriptor by the same member of each ancestor class, which the remangler spells from the declaration's own symbol, and the declaring class's override table must reference it; an unrelated same-named method in a superclass is not sufficient.

Existing superclass, sibling and subclass metadata copies are unchanged. A subclass initialized after installation can inherit a modified entry; restoration of the selected class does not rewrite copies made elsewhere. Coordinate metadata initialization if this boundary matters to the application.

Only calls that read the changed metadata entry are affected. Direct, inlined, specialized or devirtualized calls and previously captured implementations can bypass it. The original `NativeSwiftMethod` remains a direct implementation handle. A compiler-instrumented `dynamic` method can independently consult Swift's dynamic-replacement machinery.

Compiled virtual replacement supports synchronous instance and class methods and ordinary getters/setters on concrete nongeneric classes, including initialized resilient-superclass bounds. Selection requires an introducing descriptor available to symbol lookup with a matching signature. Generic class layouts, stripped descriptors, initializer/coroutine entries, and differently lowered overrides fail selection. This class path changes the selected Swift metadata slot. Protocol-qualified requirements use conformance entries described below; Objective-C selectors and function bodies use separate mechanisms.

## Inspect and restore

Use `status`, `mutation`, `restoration` and `protectionRecovery` to inspect the pointer and partial effects. Installation can fail because the platform protects a metadata page. No writable-linker option is required or applied by ABIBridge. `NativeSwiftReplacementError` uses index zero for this single entry.

Call `restore()` explicitly. It preserves a different pointer installed by another writer and permits retrying incomplete pointer or page-protection restoration. Raw comparisons cannot detect ABA changes. Releasing the plan leaves dispatch unchanged, avoiding hidden cleanup whose failure could not be returned.

Published code images and captured predecessor images remain pinned for process lifetime, so native code pointers saved by other callers remain valid after restoration or plan release. Additional code owners passed through `retaining` have that same lifetime. State accessed by the compiled replacement still needs application-owned synchronization and lifetime management.

## Protocol conformance entries

A protocol-qualified method or accessor selects the lookup type's actual witness table. Static and initializer requirements use the corresponding `NativeSwiftFunction` handles. Preparation captures the slot's current predecessor, including an installed hook chain; `original` calls it with the prepared receiver/metatype and conformance context. Restoration preserves other writers and reports partial pointer/protection failures through the existing plan state.

Generic and conditional conformances can share a table. A compiled replacement must accept every Self and generic binding reaching that physical slot; it does not filter calls as a typed callback does. Other conformance tables remain unchanged, and publication always uses the actual conformance table. Swift can return a shared canonical pattern directly when instantiation is unnecessary. Slot identity requires requirement descriptors or UUID-matched original fixups and unambiguous local witness symbols; stripping or folded identities can make preparation unavailable. See <doc:SwiftMethodHooks> for conformance scope and callback alternatives.
