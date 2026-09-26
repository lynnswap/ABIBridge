# Hooking Objective-C from native code

Use the same managed dispatch entries and snapshots from C, C++, Objective-C++, and Swift.

## Include the native interface

Link the `ABIBridge` product. Include `<ABIBridge/ObjectiveCHooks.h>` from C or `<ABIBridge/ObjectiveCHooks.hpp>` from C++20/Objective-C++. Neither interface requires a generated Swift header. Pure C/C++ uses the Objective-C runtime's opaque `Class`, `id`, and `SEL` types; Objective-C++ additionally uses compiler encodings for typed objects, blocks, and structures.

These interfaces intercept Objective-C methods and initializers. They do not install hooks on native Swift functions, imported-symbol slots, or C++ vtables.

## Install a C++ method hook

For an existing Objective-C class exposing `valueAt:`, install a typed callback and retain its handle:

```cpp
#include <ABIBridge/ObjectiveCHooks.hpp>
#include <cstdio>

Class type = objc_getClass("Renderer");
auto hook = abi_bridge::objc_method_hook<int32_t(int32_t)>(
    type, "valueAt:",
    [](auto& call, int32_t index) {
        return call.proceed(index + 1);
    },
    [](const abi_bridge::resolution_error& error) noexcept {
        std::fprintf(stderr, "%s\n", error.what());
    }
);

hook.invalidate();
```

The invocation view exposes `receiver()` and `proceed(...)` for the current snapshot. It is noncopyable and nonmovable. Taking its address does not extend its lifetime. Use it only synchronously on the original callback thread; an escaped reference is invalid. Live cross-thread access reports `ABIFailureWrongThread`, but a dangling C/C++ pointer cannot be inspected safely to diagnose expiration.

Copies of `objc_hook_handle` share ownership. Invalidating one copy removes that registration for all copies. Releasing the last owning reference has the same logical effect; existing calls finish on their captured snapshot. `native_handle()` is borrowed, `retain()` acquires a C reference, and `adopt()` takes ownership of an existing reference. A moved-from or default handle is empty and can be tested, assigned, invalidated, or destroyed.

The C++ wrapper validates encodings and sizes before installation. Pure C++ supports scalar/pointer encodings automatically; specialize `abi_bridge::objc_hook_type<T>::encoding()` for a naturally laid-out C structure. The supplied type must be trivially copyable, and its actual size/alignment must agree with the encoding and target method. Objective-C++ uses `@encode(T)` and supports retainable Objective-C pointer types under ARC and MRC. Nontrivial values, packed structures, unions, arrays, bitfields, and extended scalar representations require separate adapters.

## Objective-C++ object scope and values

`objc_object_hook<Signature>(object, selector, body, on_failure)` installs a weak identity filter on the object's current class. It does not change isa. Other instances share the dispatcher but skip that callback. Later overrides or isa changes that bypass the entry are not followed.

```objc
#include <ABIBridge/ObjectiveCHooks.hpp>

auto hook = abi_bridge::objc_object_hook<CGSize(CGSize)>(
    view, "sizeThatFits:",
    [](auto& call, CGSize proposal) {
        proposal.width = std::max(proposal.width, 100.0);
        return call.proceed(proposal);
    },
    [](const abi_bridge::resolution_error& error) noexcept {
        std::fprintf(stderr, "%s\n", error.what());
    }
);
```

Argument object/block pointers are borrowed for the callback. Results read from a continuation remain valid until that callback ends, including across later continuation calls. ARC's typed references own their normal references; MRC and pure C/C++ must retain objects or copy blocks when keeping them longer. MRC callbacks must return valid heap/global blocks; returning a pointer to an already-ended stack block is invalid.

`objc_hook_options` supplies `class_method`, `requires_main_thread`, ownership overrides, an optional `object_filter`, and a `fallback_owner`. ARC options containing objects retain them for the options value's own lifetime; the installed object filter is weak. The fallback owner is retained independently when first publishing the dispatcher and is not replaced by later registrations.

## Initializer phases

Use `objc_initializer_hook<Signature>` for consumed-self initialization. The before callback receives only explicit arguments. It can return void to observe without replacing native argument storage, return the argument tuple, or return one convertible value for a single argument. The after callback receives the actual initialized object or nil. Pass `nullptr` to omit either phase.

```objc
auto hook = abi_bridge::objc_initializer_hook<id(int32_t)>(
    rendererClass, "initWithCapacity:",
    [](int32_t capacity) { return std::max(capacity, int32_t{16}); },
    [](id initialized) {
        if (initialized) recordInitializedObject(initialized);
    },
    [](const abi_bridge::resolution_error& error) noexcept {
        std::fprintf(stderr, "%s\n", error.what());
    }
);
```

Initialization proceeds automatically once. No phase exposes incoming self or a continuation. A preparation failure uses the original arguments for the remaining chain. A postprocessing failure preserves the actual native result and does not reinitialize. Result ownership, replacement objects, inheritance, and nested initialization follow <doc:ObjectiveCInitializerHooks>.

## C callbacks and failure ownership

`ABIInstallObjCMethodHook` and `ABIInstallObjCInitializerHook` accept a class, selector name, signature, options, context, failure handler, and context-release callback. A signature describes explicit parameters only; each `ABIObjCHookValueType` carries its encoding, size, and alignment. Zero-initialized options infer ownership; use `ABIObjCOwnershipTransferred` for an explicit +1 result or consumed self.

An ordinary callback receives an `ABIObjCHookInvocation`. Use `ABIObjCHookReadArgument`, `ABIObjCHookProceed`, `ABIObjCHookReadResult`, and `ABIObjCHookSetResult`. Storage sizes must match the declaration. Proceed can reuse incoming arguments with null/zero or receive the complete explicit argument list in aligned storage. Setting a candidate result does not publish it until the callback returns true. Void results accept null/zero storage.

A false callback result transfers an owned failure through its error output. Create it with `ABICreateResolutionFailure`; the bridge releases it after notifying `onFailure`. If no failure is supplied, the bridge reports a generic callback failure. The failure notification receives a borrowed immutable error. It must not throw or release that reference.

If the callback fails before any downstream call completes, the dispatcher proceeds with the incoming arguments. If a downstream result exists, that result is preserved. A failing callback's candidate result is discarded. A successful ordinary callback that neither proceeds nor sets a result passes through; set a void result explicitly to skip a void method.

Initializer before callbacks receive only an `ABIObjCInitializerArguments` view. Read explicit values and optionally replace individual arguments with `ABIObjCInitializerSetArgument`. Unchanged arguments retain their original native representation. Changed objects/blocks are retained/copied for continuation and discarded if preparation fails. After callbacks receive only the actual initialized object or nil, borrowed for that callback.

A nonnull `releaseContext` transfers context ownership on entry, including installation failure. It runs exactly once after failure or after the registration's last in-flight snapshot releases it. A null release callback is rejected before taking ownership. Failure reporting during invocation is distinct from installation errors, which are returned to the installer. `onFailure` is required; before and after may be null. No registry lock is held while invoking or releasing user context.

`ABIRetainObjCMethodHook` adds an owning reference. The last `ABIReleaseObjCMethodHook` invalidates; explicit invalidation is idempotent and nonblocking. Null retain/release/invalidate are accepted. `ABIObjCMethodHookStatus` remains readable after invalidation or external displacement and reports no active registration for null.

## Execution and coexistence

Swift, C, and C++ registrations join the same native chain. Later registrations wrap earlier ones, each invocation keeps its snapshot, and invalidating one token leaves other registrations intact. Published callable entries remain process-lived so saved IMPs remain callable. See <doc:ObjectiveCMethodHooks> for inherited pass-through, external-writer coordination, dynamic class/code lifetime, and the permanent-entry cost.

Callbacks run synchronously on the incoming thread. `requires_main_thread` reports a background entry and bypasses user callbacks before argument access; it does not dispatch work or establish arbitrary Swift actor isolation. C++ callback exceptions are converted to reported failures within the wrapper. Failure callbacks must be `noexcept`. Raw C callbacks, Objective-C exceptions, and exceptions from native implementations must not unwind across the call boundary.

Runtime encodings cannot establish every ownership annotation, concrete object class, block/function-pointer signature, or pointee lifetime. Installation and invocation remain unsafe native operations whose declarations and lifetimes the caller must honor. Tests through the public product cover C11, pure C++, ARC/MRC Objective-C++, mixed Swift/native ordering, initializer ownership, copy/move/destruction, concurrent invalidation, and callback failure recovery.
