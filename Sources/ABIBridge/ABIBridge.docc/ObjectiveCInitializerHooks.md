# Hooking Objective-C initializers

Prepare arguments and process the actual initialized result while the bridge owns continuation and consumed-self transfer.

## Observe initialization

Use ``ABIRuntime/hookInitializer(on:selector:as:options:retaining:onFailure:transformingArguments:before:after:)`` for a concrete Objective-C instance initializer. For an imported `Renderer` class exposing `initWithConfiguration:`, its use looks like this:

```swift
let hook = try unsafe runtime.hookInitializer(
    on: Renderer.self,
    selector: "initWithConfiguration:",
    as: ((NSMutableDictionary) -> Renderer?).self,
    onFailure: { print("Initializer hook failed:", $0) },
    before: { configuration in
        configuration["compact"] = true
    },
    after: { initialized in
        guard let initialized else { return }
        configure(initialized)
    }
)
```

The function type contains only explicit arguments and the desired result type. `before` receives its registration's incoming arguments; outer hooks may already have transformed them. The bridge automatically proceeds once, then `after` receives the actual initialized object or nil. Neither callback receives uninitialized self, a continuation, or an allocation to replace.

Keep the returned ``NativeObjCMethodHook`` token alive. Invalidation, destruction, external displacement, persistent entry ownership, and inherited-method behavior follow <doc:ObjectiveCMethodHooks>. Initializer scope is a class and selector; it is not a weak identity filter on an existing `NativeObject`.

## Transform value arguments

`transformingArguments` runs after `before` and supplies the arguments for downstream hooks and native initialization. Return an ordinary tuple for multiple arguments, a value for one argument, and `()` for zero arguments. No inout parameter-pack syntax or explicit native-value wrapping is needed.

```swift
let hook = try unsafe runtime.hookInitializer(
    on: Renderer.self,
    selector: "initWithWidth:height:",
    as: ((Double, Double) -> Renderer?).self,
    onFailure: { print($0) },
    transformingArguments: { width, height in
        (max(width, 100), max(height, 40))
    }
)
```

Omitting transformation forwards the original native argument storage, preserving object identity and representations even when `before` observes a bridged Swift value. Omitting `before` or `after` performs no corresponding user action. Swift 6.3 consumer tests compile and execute these parameter-pack shapes against compiler-generated Objective-C initializers.

## Ownership and ordering

An Objective-C initializer receives self at +1, consumes that reference, and returns an owned initialized object or nil. A superclass initializer or class-cluster implementation can return another object and destroy the incoming receiver. The native boundary forwards the incoming reference without first creating a Swift object reference, preserves the actual returned +1 object, and gives postprocessing an independently managed Swift reference to that result.

Ordinary captured-implementation invocation has a different starting point: it receives an already-owned receiver and supplies an additional consumed reference. That API retains its existing behavior. Initializer hooks never use that outgoing-receiver ownership path.

Later registrations wrap earlier registrations. Installing A followed by B gives `B.before → B.transform → A.before → A.transform → native initializer → A.after → B.after`. Mutations of the initialized result by A are visible to B. Each native entry performs its own downstream initialization once; legitimate superclass delegation, another initializer selector, and initialization of another instance are separate entries and remain supported.

A call retains its chain snapshot. Concurrent invalidation removes callbacks from future snapshots but lets the current initialization and postprocessing finish. Token destruction has the same logical effect. Callback captures are released after their last in-flight reference, independently of executable-entry lifetime.

## Failures and execution context

A `before`, transformation, or argument-conversion failure is reported through `onFailure`. That hook is bypassed using its incoming arguments, and the remaining chain still initializes once. Reference mutations or other user side effects that already happened are not rolled back.

After initialization, a result-conversion failure or an error thrown by `after` is reported while returning the existing native result. The bridge never reinitializes, fabricates a nil result, or replaces the returned object to recover. Request an optional result when nil is possible. A mismatched nonoptional or object type can fail conversion while the original native caller still receives its actual object or nil.

Callbacks are synchronous on the native caller's thread. For a known MainActor initializer contract, use ``ABIRuntime/hookMainActorInitializer(on:selector:as:options:retaining:onFailure:transformingArguments:before:after:)``. It checks background entry before decoding arguments, reports `wrongThread`, and bypasses the actor callbacks. It does not perform an actor hop; `onFailure` must remain safe on background threads.

## Supported declarations

The initializer operation requires an instance method with consumed self and a retained non-block object result. Standard init-family selectors infer these conventions. Supply `NativeMethodOptions(returnsRetainedObject: true, consumesReceiver: true)` for a nonstandard selector whose declaration explicitly has those semantics. Registrations must agree on both result and receiver ownership; an ordinary hook cannot join a consuming initializer chain.

The unsafe installation contract also covers pointer/block lifetimes, valid explicit object arguments, execution isolation, and coordination with external method-table writers. Explicit consumed parameters, foreign exception unwinding, allocation/lifecycle interception, arbitrary cancellation, replacement construction, repeated initialization, native Swift allocating entries, and C++ constructors need separate contracts.

Executable tests cover same-object, nil, replacement-object, nested, inherited, and superclass initialization; argument and result conversion failures; mutation/retention of the actual result; concurrent invalidation; and MainActor bypass. The separate Swift package consumer uses an MRC Objective-C fixture that counts premature retains of uninitialized self as well as leaked instances.
