# Hooking Objective-C methods

Intercept concrete synchronous methods with ordinary Swift argument and result types.

## Install and retain a hook

Use ``ABIRuntime/hookMethod(on:selector:as:classMethod:options:retaining:onFailure:body:)-(_,String,_,_,_,_,_,_)`` to install an instance-method hook. Keep its ``NativeObjCMethodHook`` token for as long as the callback should run.

```swift
import ABIBridge
import CoreGraphics
import Foundation

class Renderer: NSObject {
    @objc dynamic func sizeThatFits(_ proposal: CGSize) -> CGSize { proposal }
}

let hook = try unsafe ABIRuntime.shared.hookMethod(
    on: Renderer.self,
    selector: "sizeThatFits:",
    as: ((CGSize) -> CGSize).self,
    onFailure: { print("Hook failed:", $0) }
) { call, proposal in
    let adjusted = CGSize(width: max(proposal.width, 100), height: proposal.height)
    return try call.proceed(adjusted)
}

let size = Renderer().sizeThatFits(CGSize(width: 40, height: 20))
// size.width == 100
hook.invalidate()
```

The selector must resolve to a concrete implementation. The function type contains explicit arguments; ABIBridge supplies self and the selector. Set `classMethod: true` for class methods, and use ordinary selectors for getters and setters. Value types follow <doc:ObjectiveCInvocation>, with no fixed argument-count limit.

Calls must use Objective-C dispatch to enter the hook. Swift calls to an `@objc` method can bypass it unless the declaration uses `dynamic` or the caller performs Objective-C dispatch.

Installation is an unsafe operation because runtime encodings do not describe every ownership annotation, block signature, pointee lifetime, or actor requirement. Supply `NativeMethodOptions` when result ownership differs from the method family or explicit parameters are annotated `ns_consumed`. Registrations on one managed entry must agree on ownership and native signature. Initializers use the dedicated operation in <doc:ObjectiveCInitializerHooks>. Foreign exception unwinding, allocation, retain/release, and lifecycle methods are outside the ordinary-method API.

A method declared with `objc_method_family(none)` can use an `init`- or `alloc`-like selector without those lifecycle semantics. For an ordinary +0 object result and borrowed self, supply `NativeMethodOptions(returnsRetainedObject: false, consumesReceiver: false)` to describe that contract explicitly. Default initializer and allocation ownership still require their dedicated contracts.

## Continue, replace, and recover from failures

``NativeObjCMethodInvocation/receiver`` returns the current instance or class object. ``NativeObjCMethodInvocation/proceed(_:)`` calls the next registration in this invocation's snapshot, followed by the native implementation. It does not send the selector again. Use ordinary selector dispatch when intentional recursive entry is needed; resolve `.objc(.imp(...))` to capture a fixed implementation independently of a callback's continuation (see <doc:ObjectiveCInvocation>).

A callback can change arguments and results, omit `proceed`, or call it repeatedly for an ordinary method with borrowed self. Callback values have ordinary Swift ownership and can be saved. See <doc:HookArguments> for object mutations, reference replacement, and diagnostics.

For `consumedArguments: [0]`, the dispatcher owns the incoming argument and supplies a fresh +1 reference on each native continuation. Skipping continuation releases the unused reference; failure recovery balances all attempted transfers.

The invocation itself is non-Sendable and valid only on its callback's original thread until return. Saving it does not keep the native frame alive. Expired or wrong-thread access throws.

A Swift callback or conversion failure is reported synchronously to `onFailure`. If no continuation has completed, the bridge bypasses that callback with its original arguments and runs the remaining snapshot. If a continuation has completed, its most recent result is preserved without replaying native side effects. Side effects already performed by user code are not rolled back. Swift errors do not unwind through Objective-C callers, and Objective-C/C++ exceptions are not translated into Swift errors.

## Order and invalidation

Later registrations run outside earlier ones. If hooks A and then B are installed, a call enters B, then A when B proceeds, then the native implementation. Each call keeps one immutable snapshot; adding or invalidating hooks during that call changes future snapshots, not its current order.

`invalidate()` is idempotent and does not wait for active calls. Token destruction has the same effect. Captures are released after the last snapshot using that registration ends, even when an invalidated token remains alive. Callbacks, native calls, error handlers, and capture destruction run outside the registry locks. Invalidation from inside a callback is supported.

A dispatcher remains installed when its chain is empty and passes calls through. ABIBridge reuses that dispatcher on later registrations rather than allocating a new executable entry every time.

## Inherited methods and object scope

Hooking an inherited method adds an override to the requested class; it does not replace the superclass's method or affect sibling classes. Its native continuation looks up the current superclass implementation, including later replacements. Class methods use the corresponding metaclass inheritance. Removing the final hook restores inherited behavior, but the added method-table entry remains: the Objective-C runtime does not provide a supported method-removal operation.

Use a ``NativeObject`` wrapper to filter a registration to one object's identity:

```swift
let renderer = Renderer()
let hook = try unsafe ABIRuntime.shared.object(renderer).hookMethod(
    selector: "sizeThatFits:",
    as: ((CGSize) -> CGSize).self,
    onFailure: { print($0) }
) { call, size in
    try call.proceed(CGSize(width: size.width + 20, height: size.height))
}
```

The token filters weakly by identity on the object's current class, leaving isa unchanged. Other instances pass through and skip the callback. The `NativeObject` wrapper and explicit callback captures can still retain the receiver. Release the wrapper when no longer needed. Later isa changes or overrides that bypass the class entry also bypass the hook.

## MainActor methods

Use `hookMainActorMethod` on `ABIRuntime` or `NativeObject` only when the native method has a known MainActor calling contract. The body is MainActor-isolated and executes synchronously without an actor hop. Background entry reports ``NativeObjCMethodHookError/wrongThread`` and continues to the next hook before decoding Swift arguments. Its `onFailure` closure therefore remains Sendable and must handle background calls.

Installing an ordinary hook from MainActor does not give its future callbacks MainActor isolation. General synchronous dispatch onto an arbitrary actor is not provided.

## Other method-table writers and lifetime

Managed registrations serialize their writes. External swizzlers must coordinate with installation: a comparison followed by `method_setImplementation` is not a compare-and-set operation. If another writer displaces the managed entry, the token's ``NativeObjCMethodHook/status`` reports `displaced`, invalidation still removes its callback, and a new registration throws ``NativeObjCMethodHookError/displaced``. Invalidation never writes over an external IMP.

External replacements can call a saved dispatcher IMP. Its active callbacks still apply even if the token reports displacement. ABIBridge does not automatically retarget that dispatcher to the external replacement, which could create a cycle when the replacement calls the saved dispatcher.

Saved IMPs require published entries, prepared layouts, and original fallback owners to remain alive for the process lifetime. ABIBridge keeps one entry per controlled class, selector, and method kind regardless of registration count. Callback captures release after their last active snapshot; preparation failures release unpublished entries.

First installation retains discoverable implementation and class images. Supply `retaining:` for a generated original IMP or dynamic class owner; later registrations reuse that fallback ownership. Keep controlled classes, generated original code, and inherited pass-through implementations valid even after token invalidation. External writers own the lifetime and ABI/ownership contract of their replacements.

See <doc:NativeObjectiveCHooks> for C, C++, and Objective-C++ registration on the same chain.

## Invocation cost

Registration prepares signatures and argument codecs. Calls reuse them without symbol or image searches. Even an empty dispatcher pays for a call boundary and snapshot; each active callback adds conversion and a continuation frame. Object filtering uses the same class-wide dispatcher. See <doc:Architectures> for execution evidence.
