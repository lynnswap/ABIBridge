# Hooking imported C and C++ functions

Change calls through selected Mach-O import slots with typed callbacks, scoped continuations and managed registration lifetime.

## Select the callers

For a library importing `int Example::Math::add(int, int)`, specify the importing image and the source declaration:

```swift
let hook = try await unsafe runtime.hookImportedFunction(
    NativeDeclaration(name: "Example::Math::add(int, int)", language: .cxx),
    as: ((Int32, Int32) -> Int32).self,
    in: .framework(named: "Renderer"),
    onFailure: { print($0) }
) { call, a, b in
    try call.proceed(a, b) + 1
}

hook.invalidate()
```

`in` identifies the currently loaded callers whose references will change. `from`, when provided, filters the dependency name recorded in the binding metadata; a reexport facade is preserved rather than replaced with its final implementation image. Framework, path and exact install-name selectors are available. These scopes do not load images. Explicit `.automatic` considers all loaded importing images and can fail when required metadata is unavailable; it does not silently omit unreadable system-cache metadata.

Names reuse ABIBridge's C/C++ resolution conventions. The function type supplies the C ABI contract; a mangled name cannot establish argument ownership or a complete signature. Supported values follow <doc:CFunctionInvocation>, with borrowed pointer arguments/results and no foreign exception unwinding. Native Swift functions, Objective-C ownership, variadics and nontrivial C++ values are separate contracts.

Only calls that read the replaced references are intercepted. Direct/inlined calls, optimized shared-cache calls that bypass imports and function pointers captured before registration are unaffected. An unresolved lazy import still pointing to its loader helper must first be called normally by its owner; ABIBridge does not invoke functions with invented arguments to resolve them.

## Callback order and lifetime

Each physical import slot has its own captured predecessor and permanent callable entry. Later registrations wrap earlier ones; `proceed` uses the current invocation's snapshot, not a new lookup of the symbol. A callback can change arguments/results, skip the predecessor, or proceed more than once where the native operation permits it. Multiple imported slots are not activated atomically.

Callbacks run synchronously on the incoming thread. Swift continuations reject use after callback return or on another thread. A Swift callback or conversion error is delivered to `onFailure` as the original Swift error. If no continuation completed, the original arguments pass through; otherwise the latest completed continuation result is preserved without repeating its native side effects.

Retain ``NativeImportedFunctionHook`` while its behavior is needed. Explicit invalidation and the last owner's destruction remove only that registration from future snapshots. In-flight snapshots keep their callbacks until completion. Ordinary invalidation leaves an empty pass-through entry rather than restoring the import pointer. Published executable storage, prepared signatures and original/importing image leases remain process-lived so saved callable entries stay valid. Callback captures are released independently.

External writers must coordinate with registration and memory protection changes. Status can report displacement without overwriting the external pointer. Generated predecessor code must remain valid independently of the token, since it may not have a loader image to retain. Callback code and all pointer pointees must satisfy the native lifetime contract.

## Partial installation failures

TPRO-protected pages can reject publication even when metadata and authentication are valid. ``NativeImportedHookInstallationError`` preserves the native error, failed slot index and an invalidated registration with per-slot publication/rollback results:

```swift
do {
    // Store the returned hook in an owner with the required lifetime.
    hooks.append(try await unsafe runtime.hookImportedFunction(
        declaration, as: ((Int32, Int32) -> Int32).self,
        in: .framework(named: "Renderer"), onFailure: reportFailure
    ) { call, a, b in try call.proceed(a, b) })
} catch let error as NativeImportedHookInstallationError {
    print(error.failedIndex as Any, error.underlyingError)
    for slot in error.registration.slots {
        print(slot.address, slot.mutation.didWrite, slot.rollback.didWrite)
        print(slot.mutation.restoreProtectionError, slot.rollback.restoreProtectionError)
    }
}
```

Preparation runs before publication where possible. A later failure removes this registration and attempts to restore only pointers newly published by this operation, using expected-value comparison. Existing registrations and later external values are preserved. Failed page-protection restoration remains reported even if the pointer was changed or subsequently restored. Physical rollback cannot undo native side effects from concurrent callers and does not make published entry storage safe to free.

## Native callers

Include `<ABIBridge/ImportedHooks.h>` for C or `<ABIBridge/ImportedHooks.hpp>` for C++20/Objective-C++. All frontends use the same registration chain:

```cpp
auto hook = abi_bridge::hook_imported_function<int32_t(int32_t, int32_t)>(
    runtime, {"Example::Math::add(int, int)"},
    abi_bridge::image_selector::framework("Renderer"),
    [](auto& call, int32_t a, int32_t b) { return call.proceed(a, b) + 1; },
    [](const abi_bridge::resolution_error& error) noexcept { report(error); }
);
```

The C++ wrapper supports scalars and borrowed pointers. Specialize `imported_hook_type<T>::make()` with an owned `ABIValueType` for a naturally laid-out, trivially copyable C aggregate. Its size/alignment must match `T`. Callback exceptions are reported and recovered within the C++ wrapper; failure handlers must be `noexcept`. C/C++ invocation views must not escape their callback.

The raw C installer takes ownership of the context when a release callback is provided, including lookup failure. Inspect the returned owner's `ABIImportedHookFailure` before treating installation as successful. The returned owner and its per-slot effects remain readable on failure and must be released. A null context-release callback is rejected without taking the context. C callback failures transfer an owned `ABIResolutionFailure`; failure-handler errors are borrowed.
