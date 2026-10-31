# Creating Swift protocol values

Implement a runtime-only class-bound Swift protocol with typed host callbacks.

## Create a delegate

For a loaded provider with this declaration:

```swift
public protocol EventDelegate: AnyObject {
    func receive(_ message: String)
}
```

Create its native value without importing the provider module:

```swift
import ABIBridge

let runtime = ABIRuntime.shared
let delegate = try await runtime.makeSwiftProtocolValue(
    "Example.EventDelegate",
    methods: [
        try NativeSwiftProtocolMethod("receive(_:)") { (message: String) in
            print(message)
        }
    ]
)
```

Use `makeSwiftProtocolValueAndWait` for synchronous preparation. The asynchronous factory performs lookup and formal call planning on a worker; it binds callback captures, registers the conformance and creates the instance in the caller's isolation domain.

The returned ``NativeSwiftValue`` contains an actual `any EventDelegate` existential. Pass it to a resolved native function using `NativeSwiftValue` in the host signature:

```swift
let install = try await runtime.resolve(.swift(.function(
    "Example.install(_:)", as: ((NativeSwiftValue) -> Void).self
)))
try unsafe install.unsafeInvoke(delegate)
```

To invoke a requirement through the existing member API, open the existential and qualify the method with its protocol:

```swift
let concrete = try delegate.copyUnderlyingValue()
let receive = try await concrete.type.resolve(.swift(.method(
    "Example.EventDelegate.receive(_:)", as: ((String) -> Void).self
)))
try unsafe receive.unsafeInvoke(on: concrete, "hello")
```

The concrete copy retains the same native instance and its code owners. For object identity alone, `delegate.withCopy { $0 as AnyObject }` is sufficient; opening the existential is needed for concrete member lookup.

Method names include argument labels. Use the complete declaration name when labels and host parameter types cannot distinguish overloaded requirements. Implement every requirement exactly once. A missing or duplicate implementation, unsupported requirement or incompatible callback signature throws before a value is returned.

## Supported requirements

The initial contract supports Swift class-bound protocols with synchronous instance methods returning `Void`, including throwing methods and `Self` parameters. Associated types, generic methods, additional generic constraints, inherited protocols, properties, initializers, static methods and async methods are unsupported.

A nonthrowing body can implement a throwing requirement. A requirement declared with ordinary `throws` accepts any host error; a typed-throws requirement preserves its declared error type. Thrown errors follow the same contracts as <doc:SwiftClosureValues>.

Requirement identities must be recoverable from the provider's method descriptors or an existing conformance's original witness symbols. When stripped nonresilient code supplies neither, preparation reports unavailable metadata.

Receiver ownership follows the native declaration. Ordinary methods borrow self. For a requirement declared `consuming func finish()`, use `NativeSwiftProtocolMethod("finish()", receiver: .consuming) { ... }`. Swift symbols and protocol requirement descriptors do not encode receiver ownership, so the supplied convention must match the declaration. A consuming witness releases its owned native reference after the callback on both return and throw.

Parameters use the same formal value conversions as Swift callbacks. Ordinary Swift values describe importable types. Use ``NativeSwiftValue`` or ``NativeSwiftBorrowedValue`` for runtime-only types, and the ownership wrappers described in <doc:SwiftArgumentConventions> when a requirement consumes or modifies an argument. Supply `valueABIs` for closed nominal types whose calling convention cannot be inferred. Borrowed callback inputs and nested closure values keep the contracts in <doc:SwiftClosureValues>.

## Retain and release delegates

Native code can retain, copy and rebox the value or recover its conformance through a standard Swift dynamic cast. An instance owns its callback bodies and captures. Releasing the original bridge handle does not invalidate copies held by the provider. The final native object release destroys its captures on the releasing thread; an invocation that has entered retains its own callback context through completion.

A weak delegate property does not keep the object alive. Keep a strong bridge handle or another native strong reference for as long as the delegate is installed. A consuming setter needs an independent native copy when the original handle must remain usable:

```swift
// The provider declares: weak var delegate: (any EventDelegate)?
let setter = try await inputType.resolve(.swift(.setter(
    "delegate", as: ((NativeSwiftValue?) -> Void).self
)))
try unsafe setter.unsafeInvoke(on: input, delegate.copy())
// Keep delegate alive while input uses the weak property.
```

Reusing the same `NativeSwiftProtocolMethod` for multiple instances shares its captured state. Create separate method callbacks when each delegate needs independent state.

Assignment of a `NativeSwiftValue` only aliases its ownership state. See <doc:SwiftArgumentConventions> for consuming arguments and <doc:SwiftOpaqueResults> for copying owned values.

## Calling thread and runtime registration

Bodies are escaping `@Sendable` callbacks. They execute synchronously on the native caller's thread, including simultaneous calls. The factory performs no executor hop. If a native API requires an actor or a particular thread, the caller must satisfy that requirement and the callback must access isolated state accordingly.

Swift's runtime caches conformance records and metadata without an unregistration operation. ABIBridge keeps prepared proxy classes and their metadata alive for the process. Successful conformance registration additionally retains witness entries, physical call interfaces and their required implementation images. Compatible instances reuse that registration. The runtime owners retain code, layouts and image leases; instance bodies and captures are released separately.

Preparation validates the entire protocol and all implementations before registering a conformance. A prepared class may remain after a signature or conversion failure because Swift caches its metadata. A registered conformance can remain after a later instance-allocation failure. These runtime owners retain no failed instance's callbacks, captures, formal conversion plans or symbol resolver.

## See Also

- ``NativeSwiftProtocolMethod``
- <doc:SwiftClosureValues>
- <doc:SwiftExistentialValues>
