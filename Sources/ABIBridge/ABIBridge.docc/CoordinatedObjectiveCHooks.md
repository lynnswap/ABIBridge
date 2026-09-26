# Installing several Objective-C hooks

Validate related declarations before installation and retain the resulting ordinary hook handles together.

## Declare and install

Create ``NativeObjCHookRequest`` values and pass them to ``ABIRuntime/installHooks(_:)``. Request creation does not change method tables. This is optional: single-hook callers can continue using `hookMethod` or `hookInitializer` directly.

```swift
let hooks = try unsafe runtime.installHooks([
    unsafe .method(
        on: Renderer.self, selector: "sizeThatFits:",
        as: ((CGSize) -> CGSize).self, onFailure: reportFailure
    ) { call, size in
        try call.proceed(CGSize(width: max(size.width, 100), height: size.height))
    },
    unsafe .initializer(
        on: Renderer.self, selector: "initWithConfiguration:",
        as: ((NSMutableDictionary) -> Renderer?).self, onFailure: reportFailure,
        before: { $0["compact"] = true }
    )
])

for hook in hooks { hook.invalidate() }
```

`method`, `objectMethod`, `initializer`, `mainActorMethod`, and `mainActorInitializer` use the corresponding direct hook contracts. Requests retain their callback captures and declaration inputs until the requests are released. An object request holds its receiver during preparation; the installed identity filter remains weak. Request values can be reused.

The returned array owns ordinary ``NativeObjCMethodHook`` tokens in request order. Releasing the array removes registrations when their last token references are released. Explicitly invalidating its elements removes them even if another reference remains. Calls already in progress keep their snapshots. Other independently installed registrations are unaffected.

## Preparation and activation

Every request's target, signature, ownership, and call layout is validated before any entry is published. Requests for the same method must agree on result and receiver ownership. A declaration failure stops preparation without adding any registration.

Activation then revalidates current predecessors and installs in request order. Parent and child class requests may appear in either order; an inherited continuation follows the current superclass implementation. A concurrent caller can observe a partially activated batch. The Objective-C runtime does not provide an atomic multi-method swap.

External writers still need to coordinate with installation. A method or implementation can change after preparation. If a later activation fails, all registrations already added by this operation are logically invalidated in reverse order. Preexisting registrations and external replacements are preserved. Added subclass-local method entries and published executable storage can remain as pass-through entries. This rollback does not undo native/user side effects performed by calls that entered while activation was in progress.

## Inspect a failure

``NativeObjCHookInstallationError`` retains the original error, zero-based failed request index, phase, and earlier handles that were invalidated during activation failure:

```swift
do {
    let hooks = try unsafe runtime.installHooks(requests)
    retainHooks(hooks)
} catch let error as NativeObjCHookInstallationError {
    print(error.failedIndex, error.phase, error.underlyingError)
    print(error.invalidatedHooks.map(\.status))
}
```

Preparation errors have an empty partial-handle array. Activation errors expose the registrations created before failure, already invalidated. Status remains readable regardless of displacement. Logical invalidation does not throw or wait for live calls, so it introduces no separate cleanup-error channel. It does not imply that published IMPs or runtime method-table entries were physically removed.

## Native callers

C++20 and Objective-C++ use `abi_bridge::objc_hook_request` and `install_objc_hooks`. The result is a vector of ordinary owning handles:

```cpp
using abi_bridge::objc_hook_request;
auto hooks = abi_bridge::install_objc_hooks({
    objc_hook_request::method<int32_t(int32_t)>(
        rendererClass, "valueAt:",
        [](auto& call, int32_t index) { return call.proceed(index + 1); },
        onFailure
    ),
    objc_hook_request::initializer<id(int32_t)>(
        rendererClass, "initWithCapacity:",
        [](int32_t capacity) { return std::max(capacity, int32_t{16}); },
        nullptr, onFailure
    )
});
for (auto& hook : hooks) hook.invalidate();
```

`onFailure` must be a `noexcept` callback, as in <doc:NativeObjectiveCHooks>. Options preserve instance/class scope, weak object filtering, and explicit main-thread requirements. A C++ request retains callback storage; releasing installed handles does not release captures still owned by a retained request. `objc_hook_installation_error` supplies `failed_index()`, `phase()`, the original `cause()`, and `invalidated_hooks()`. Allocation failures while constructing C++ request/return containers remain ordinary C++ allocation exceptions; any activated handles are invalidated before propagating an error constructing the result vector.

C callers pass an `ABIObjCHookRequest` array to `ABIInstallObjCHooks`. Keep the array, signature storage, strings, classes, and supplied objects valid throughout the call. The returned `ABIObjCHookInstallation` owns successful or invalidated partial handles and any failure. Inspect it with `ABIObjCHookInstallationFailure`, `FailedIndex`, `Phase`, `Count`, and `Get`; retain a borrowed handle with `ABIRetainObjCMethodHook` to own it independently.

A null array with nonzero count, or any missing context-release callback, is rejected without taking any contexts. Otherwise every context reference transfers on entry, including requests after the first declaration failure. Each registration retains/releases its own context reference. Reusing the same raw pointer in several requests requires a corresponding independent ownership reference for each request. Release callbacks run outside registry locks and may reenter the API.

`ABIInvalidateObjCHookInstallation` logically invalidates every result handle and is idempotent. `ABIReleaseObjCHookInstallation` releases its references; independently retained aliases follow the ordinary last-owner contract. Empty batches succeed. Successful results have no failure, phase zero, and `SIZE_MAX` for the failed index. The same non-atomic visibility, inheritance, process-lived entry, and rollback contracts apply across Swift and native callers.
