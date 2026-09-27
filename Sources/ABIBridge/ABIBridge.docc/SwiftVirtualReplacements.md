# Replacing compiled Swift virtual methods

Select a class method by its source declaration and replace the entry in that class's Swift metadata with an ABI-compatible compiled method.

## Prepare and publish

```swift
let type = try await runtime.swiftType(named: "Rendering.Renderer")
let method = try await type.method(
    named: "render(_:)", as: ((String) -> String).self
)
let replacement = try await type.method(
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

`prepareVirtualReplacement(with:retaining:)` changes no pointers. Its `original` captures the current entry, including another writer's previously installed implementation. A class method entry must contain a nonnull predecessor; unlike a weak importing reference, it is returned as a nonoptional handle. Method selection resolves the introducing method descriptor by its source declaration, then locates that descriptor in its class layout. It compares neither the current slot target nor implementation code addresses, which optimizers may share between unrelated declarations. An earlier replacement therefore does not prevent selecting the same source declaration again.

The replacement is compiled Swift code with the same physical receiver, argument/result lowering, ownership and isolation contract. It must accept every receiver that reaches the selected slot. Equal Swift function types do not prove these requirements. Capturing closure hooks require an incoming Swift ABI bridge and are a separate API.

## Understand the class scope

The type used for `method(named:as:)` determines the metadata to change. Looking up an inherited method on `PreviewRenderer` changes the copy in `PreviewRenderer` metadata, including when the symbol itself belongs to its superclass. An override uses the original introducing method descriptor to find the inherited slot and its pointer-authentication discriminator.

Existing superclass, sibling and subclass metadata copies are unchanged. A subclass initialized after installation can inherit a modified entry; restoration of the selected class does not rewrite copies made elsewhere. Coordinate metadata initialization if this boundary matters to the application.

Only calls that read the changed metadata entry are affected. Direct, inlined, specialized or devirtualized calls and previously captured implementations can bypass it. The original `NativeSwiftMethod` remains a direct implementation handle. A compiler-instrumented `dynamic` method can independently consult Swift's dynamic-replacement machinery.

The reader supports concrete nongeneric class descriptors, synchronous instance methods and ordinary getter/setter entries, including initialized resilient-superclass bounds. The introducing descriptor must be available to symbol lookup with a matching source signature; stripped descriptors or differently lowered override signatures require an adapter. It reports unestablished generic layouts and unsupported initializer or coroutine descriptors instead of guessing offsets. It does not modify Objective-C selectors, protocol witness tables or arbitrary function bodies.

## Inspect and restore

Use `status`, `mutation`, `restoration` and `protectionRecovery` to inspect the pointer and partial effects. Installation can fail because the platform protects a metadata page. No writable-linker option is required or applied by ABIBridge. `NativeSwiftReplacementError` uses index zero for this single entry.

Call `restore()` explicitly. It preserves a different pointer installed by another writer and permits retrying incomplete pointer or page-protection restoration. Raw comparisons cannot detect ABA changes. Releasing the plan leaves dispatch unchanged, avoiding hidden cleanup whose failure could not be returned.

Published code images and captured predecessor images remain pinned for process lifetime, so native code pointers saved by other callers remain valid after restoration or plan release. Additional code owners passed through `retaining` have that same lifetime. State accessed by the compiled replacement still needs application-owned synchronization and lifetime management.
