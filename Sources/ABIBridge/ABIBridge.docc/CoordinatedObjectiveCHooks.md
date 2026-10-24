# Installing several Objective-C hooks

Validate related declarations before installation and retain the resulting ordinary hook handles together.

## Declare and install

Pass ``NativeObjCHookRequest`` values to ``ABIRuntime/installHooks(_:)`` to prepare related declarations together. Creating requests leaves method tables unchanged. For one hook, call `hookMethod` or `hookInitializer` directly.

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

The returned array owns ``NativeObjCMethodHook`` tokens in request order. Each token follows the invalidation and snapshot rules in <doc:ObjectiveCMethodHooks>. Invalidate elements explicitly, or release their last references to remove these registrations.

## Preparation and activation

Every request's target, signature, ownership, and call layout is validated before any entry is published. Requests for the same method must agree on result and receiver ownership. A declaration failure stops preparation without adding any registration.

Activation then revalidates current predecessors and installs in request order. Parent and child class requests may appear in either order; an inherited continuation follows the current superclass implementation. A concurrent caller can observe a partially activated batch. The Objective-C runtime does not provide an atomic multi-method swap.

Coordinate with external writers, since methods can change after preparation. On activation failure, the operation invalidates its earlier registrations in reverse order and preserves preexisting registrations and external replacements. Published entries can remain as pass-through storage. Calls that entered during activation keep any native or user side effects.

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

Preparation errors have no partial handles. Activation errors expose earlier registrations after invalidation, with readable status even after displacement. Invalidation is nonthrowing and does not wait for calls or physically remove published IMPs and method-table entries.

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

`onFailure` must be `noexcept`; scope, weak filtering, and main-thread options follow <doc:NativeObjectiveCHooks>. Retained requests keep their captures even after installed handles release them. Inspect `objc_hook_installation_error` through `failed_index()`, `phase()`, `cause()`, and `invalidated_hooks()`. Container allocation errors remain C++ exceptions; failure to construct the result vector invalidates activated handles before throwing.

C callers pass an `ABIObjCHookRequest` array to `ABIInstallObjCHooks`. Keep the array, signature storage, strings, classes, and supplied objects valid throughout the call. The returned `ABIObjCHookInstallation` owns successful or invalidated partial handles and any failure. Inspect it with `ABIObjCHookInstallationGetFailure`, `GetFailedIndex`, `GetPhase`, `GetCount`, and `GetHook`; retain a borrowed handle with `ABIRetainObjCMethodHook` to own it independently.

A null array with nonzero count or a missing context-release callback is rejected without taking contexts. Otherwise all context references transfer on entry, even for requests after a declaration failure. Supply an independent owned reference per request when reusing a context pointer. Release callbacks run outside registry locks and may reenter the API.

`ABIInvalidateObjCHookInstallation` logically invalidates every result handle and is idempotent. `ABIReleaseObjCHookInstallation` releases its references; independently retained aliases follow the ordinary last-owner contract. Empty batches succeed. Successful results have no failure, phase zero, and `SIZE_MAX` for the failed index. The same non-atomic visibility, inheritance, process-lived entry, and rollback contracts apply across Swift and native callers.
