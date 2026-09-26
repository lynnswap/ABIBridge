# Hooking Objective-C methods

Intercept concrete synchronous methods with ordinary Swift argument and result types.

## Install and retain a hook

Use ``ABIRuntime/hookMethod(on:selector:as:classMethod:options:retaining:onFailure:body:)`` to install an instance-method hook. Keep its ``NativeObjCMethodHook`` token for as long as the callback should run.

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

The selector must resolve to a concrete implementation. The function type contains explicit arguments only; self and the selector are supplied by the bridge. Set `classMethod: true` for a class method. Getters and setters use their ordinary selectors. Scalar, pointer, object, optional, class, block, and supported standard structure types follow <doc:ObjectiveCInvocation>. There is no fixed argument-count limit. Only Objective-C dispatch is intercepted: Swift calls to an `@objc` method can bypass the method table unless the declaration uses `dynamic` or the caller otherwise performs Objective-C dispatch.

Installation is an unsafe operation because runtime encodings do not describe every ownership annotation, block signature, pointee lifetime, or actor requirement. Supply `NativeMethodOptions` when result ownership differs from the method family. Registrations on one managed entry must agree on ownership and native signature. Initializers use the dedicated operation in <doc:ObjectiveCInitializerHooks>. Explicit consumed arguments, foreign exception unwinding, allocation, retain/release, and lifecycle methods are outside the ordinary-method API.

## Continue, replace, and recover from failures

``NativeObjCMethodInvocation/receiver`` returns the current instance or class object. ``NativeObjCMethodInvocation/proceed(_:)`` calls the next registration in this invocation's snapshot, followed by the native implementation. It does not send the selector again. Use ordinary selector dispatch when intentional recursive entry is needed; use ``ABIRuntime/objcImplementation(on:selector:as:classMethod:options:retaining:)`` to capture a fixed implementation independently of a callback's continuation.

A callback can change arguments and results, omit `proceed`, or explicitly call it more than once for an ordinary nonconsuming method. The invocation is valid only until its callback returns and only on the original thread. Saving it does not keep the native stack frame alive; expired or wrong-thread access throws. It is not Sendable.

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

This does not change isa. The token's filter is weak and does not retain the receiver. The `NativeObject` wrapper itself has its existing strong receiver ownership, so discard that wrapper when it is no longer needed. A callback that explicitly captures its receiver can still retain it. Other instances of the class pass through the dispatcher and skip this callback. Later isa changes or overrides that bypass that class entry are not automatically followed.

## MainActor methods

Use `hookMainActorMethod` on `ABIRuntime` or `NativeObject` only when the native method has a known MainActor calling contract. The body is MainActor-isolated and executes synchronously without an actor hop. Background entry reports ``NativeObjCMethodHookError/wrongThread`` and continues to the next hook before decoding Swift arguments. Its `onFailure` closure therefore remains Sendable and must handle background calls.

Installing an ordinary hook from MainActor does not give its future callbacks MainActor isolation. General synchronous dispatch onto an arbitrary actor is not provided.

## Other method-table writers and lifetime

Managed registrations serialize their writes. External swizzlers must coordinate with installation: a comparison followed by `method_setImplementation` is not a compare-and-set operation. If another writer displaces the managed entry, the token's ``NativeObjCMethodHook/status`` reports `displaced`, invalidation still removes its callback, and a new registration throws ``NativeObjCMethodHookError/displaced``. Invalidation never writes over an external IMP.

External replacements can call a saved dispatcher IMP. Its active callbacks still apply even if the token reports displacement. ABIBridge does not automatically retarget that dispatcher to the external replacement, which could create a cycle when the replacement calls the saved dispatcher.

Published executable entries, their prepared call layout, and original fallback ownership are retained for the process lifetime because external IMP holders cannot be enumerated. This is one entry per controlled class/selector/method-kind, independent of registration count; callback captures are not process-lived. Preparation failures release unpublished entries.

Implementation and class images discovered at first installation are retained. `retaining:` can keep a generated original IMP owner or dynamic class owner alive when creating that entry; subsequent registrations reuse its existing fallback ownership. Do not dispose a controlled runtime class, invalidate generated original code, or unload an implementation that inherited pass-through may currently select. External writers remain responsible for the lifetime and ABI/ownership of implementations they introduce. Token invalidation alone does not establish that unloading or physically freeing saved code is safe.

## Cost and validation

Signatures and argument codecs are prepared at registration. Calls do not perform symbol discovery, demangling, or image scans. An empty dispatcher still has a call-boundary and snapshot cost; each active callback adds value conversion and a scoped continuation frame. Object filtering shares the class-wide dispatcher cost. The `ObjectiveCMethodHookTests` benchmark compares direct calls, inactive dispatch, and one/three hooks for scalar, CGSize, and object methods without imposing timing thresholds.

The same tests cover ordering, inheritance, weak filtering, concurrent callers and registration, reentrancy, ownership, saved entries, and external displacement. The architecture validation package's `hooks` mode exercises the public Swift callback frontend in a signed device host. Build support and executed architecture/device evidence are reported separately in <doc:Architectures>.
