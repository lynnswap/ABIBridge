# Hooking shared C++ virtual entries

Select an absolute virtual-table entry by its implementation declaration, then intercept calls that dispatch through that shared table.

## Select the table and method

Start with a ``NativeVTable`` whose address point, accessible function-entry count and base subobject are known. A native adapter can acquire the table using the target compiler; the table view does not infer object layout. See <doc:CXXObjectInvocation> for receiver and vptr acquisition.

```swift
let entry = try await table.entry(
    named: "Example::Derived::value(int) const"
)
let hook = try unsafe entry.hookSharedCalls(
    as: ((Int32) -> Int32).self,
    onFailure: { error in print(error) }
) { call, value in
    try call.proceed(value + 1) + 10
}
```

The signature describes explicit arguments only. ``NativeVirtualInvocation/receiver`` is the incoming base-subobject pointer, borrowed for the callback. `proceed` passes that same pointer to the next callback or captured predecessor, preserving receiver-adjustment and covariant-return thunks. Do not cast the pointer to a complete object unless the target's layout establishes that conversion.

Named selection reads original fixups and symbols from the matching image file, including its authentication schema. A previously replaced slot still selects the original entry. If names or original metadata are unavailable, use the adapter path:

```swift
let entry = try unsafe table.entry(
    at: layout.valueSlot,
    authentication: layout.valueAuthentication
)
```

The adapter must establish the actual slot and schema. Direct interception of relative tables is unsupported. An adapter can be used here only when the calls of interest dispatch through its absolute entry. A method declaration alone does not establish a callable signature or reconstruct class layout.

## Edit argument objects

A pointer argument or pointer-backed `ABIBridgeValue` adapter refers to the original native object. Its writable properties can be changed before continuing, and the native result or resulting state can be processed afterward. For an adapter named `RequestView` that describes a live C++ request pointer:

```swift
let hook = try unsafe entry.hookSharedCalls(
    as: ((RequestView) -> Int32).self,
    onFailure: { print($0) }
) { call, request in
    request.value = 7
    let result = try call.proceed(request)
    request.observed += 1
    return result
}
```

`RequestView` supplies the actual pointer/layout or compiled accessor contract; ABIBridge does not infer arbitrary C++ properties from their names. Passing a different adapter/pointer to `proceed` changes the argument seen by the downstream call. Mutating an object's properties changes that object for every owner, while replacing the argument does not overwrite the caller's reference variable. Supported value-type arguments are copied; modify a local copy and pass it to `proceed` to change the downstream value. Native `inout` and ownership-transfer conventions are separate contracts.

Object mutations made before a callback fails are not rolled back. If no continuation completed, fallback receives the original argument references, which may now point to modified objects. If a continuation completed, its result is preserved without repeating the native call. See <doc:ObjectiveCMethodHooks> for directly typed Objective-C object arguments and dynamic setter calls.

## Understand scope and lifetime

This operation changes one **shared table entry**. Calls on every object using it can enter the callback, including objects other than the one used to obtain the table. It does not create a per-object shadow table. Direct, qualified, inlined or devirtualized calls bypass that entry. A function pointer captured before installation also bypasses the new dispatcher.

Keep the ``NativeVirtualHook`` owner while interception is required. Later registrations wrap earlier ones. Each incoming call uses an immutable callback snapshot. `invalidate()` removes that registration from future snapshots, without waiting for active callbacks and without restoring a pointer over another writer's value. Releasing the final owner also invalidates it.

Published dispatchers, original table/implementation image leases and explicit table-storage keepalives remain allocated for process lifetime. A pointer captured after publication therefore remains callable after invalidation and passes through to its predecessor. Keep resources that should release on invalidation in callback captures instead of table-storage owners; callback captures release after the last active snapshot ends.

Callbacks run synchronously on the incoming thread. Swift bodies and failure handlers are `@Sendable`; they must also respect the native receiver's thread and lifetime rules. A continuation cannot escape to another thread or outlive its callback. Swift reports those uses as ``NativeVirtualInvocationError``; C/C++ callers must not access an expired invocation view.

## Handle failure

```swift
if let slot = hook.slot {
    print(slot.status, slot.mutation.didWrite)
}
hook.invalidate()
```

The slot snapshot distinguishes active, invalidated, displaced and unreadable states. It is an observation, not synchronization with an external writer. Publication and rollback records preserve writes, original Mach failures, protection-restoration failures and the region information collected during the operation.

Installation can throw ``NativeVirtualHookInstallationError``. Its invalidated `registration` preserves any selected slot and partial effects. A nil slot means preparation failed before selection. Read-only or TPRO-protected pages can refuse installation; callers must inspect the actual outcome. A failed installation does not silently switch to a per-object technique.

When a Swift body throws before proceeding, the original arguments pass through. If a continuation already completed, its latest result is preserved. The original error is delivered to `onFailure`. C++ callback exceptions are caught by the wrapper and reported similarly. A C callback returns `false` and supplies an owned `ABIResolutionFailure` to report failure.

Use C-compatible scalars, borrowed pointers and naturally laid-out trivial aggregates. Nontrivial C++ copying/destruction, native exception unwinding through the intercepted call, special result conventions and construction/destruction dispatch require a compiled adapter with a matching contract. Callbacks and native code/resources must remain valid through their final invocation and release.

## Use C++ or Objective-C++

For an available C++ base declaration, Clang can acquire and authenticate its vptr:

```cpp
#include <ABIBridge/VirtualHooks.hpp>
#include <cstdio>

using namespace abi_bridge;
auto runtime = Runtime::current();
auto table = virtual_table::from(baseSubobject, layout.entryCount, storageOwner);
auto entry = table.entry(runtime, "Example::Derived::value(int) const");
auto hook = entry.hook_shared_calls<int(int)>(
    [](auto& call, int value) { return call.proceed(value + 1) + 10; },
    [](const resolution_error& error) noexcept { std::fprintf(stderr, "%s\n", error.what()); }
);
```

`baseSubobject` is a live polymorphic reference of the exact static base type. The helper uses `__builtin_get_vtable_pointer`; it does not decode member-function-pointer bits or guess a slot from a live implementation address. The caller still supplies the accessible absolute entry count. For a secondary base, perform the compiler's base conversion before creating the view.

For an explicit adapter, construct `virtual_entry` with an `ABIVirtualEntryInfo` and an optional `std::shared_ptr<const void>` storage/code owner. A named entry retains its metadata image. Copies share those owners; copies of `virtual_hook_handle` share registration. `virtual_hook_installation_error` preserves the invalidated registration and its copied effects.

The same C++ interface works in Objective-C++. ARC captures in a callback live until that callback's final active snapshot ends. They do not make a UI object safe to access from an arbitrary incoming thread. Failure handlers must be `noexcept`.

C++ callbacks share the `callback_value_type<T>::make()` codec customization with imported hooks. Specializations return an owned `ABIValueType` for a naturally laid-out, trivially copyable C aggregate; size and alignment must match `T`.

## Use C

Include `<ABIBridge/VirtualHooks.h>`. Obtain a named selection with `ABICopyVirtualEntry` and copy its `ABIVirtualEntryInfo`, or supply that descriptor from an explicit native adapter. Keep the named selection alive through installation.

`ABIInstallSharedVirtualHook` takes result/explicit-argument layouts, callback context, callback/failure/release functions, and an optional storage keepalive. Its parameter list excludes `this`. In the callback, `ABIVirtualInvocationReceiver` returns the borrowed subobject, `ABIVirtualReadArgument` indexes explicit arguments, and `ABIVirtualProceed` preserves the receiver automatically. Read or assign the result with `ABIVirtualCopyResult` and `ABIVirtualSetResult`.

A nonnull `releaseContext` transfers context on entry, including failure; a nonnull `releaseStorage` transfers its storage context too. A null `releaseContext` returns null and transfers neither. Other outcomes return an owned handle. Inspect `ABIVirtualHookFailure`, `ABIVirtualHookHasEntry` and the slot/mutation accessors before releasing a failed handle. Final `ABIReleaseVirtualHook` invalidates the registration.
