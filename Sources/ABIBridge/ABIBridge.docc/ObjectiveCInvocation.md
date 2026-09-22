# Calling Objective-C methods

Bind an existing receiver and invoke its selectors using Swift function types.

## Look up a method

The receiver must expose the selector to the Objective-C runtime. A Swift class can expose a method with `@objc`; a method using only the Swift ABI requires a different invocation backend.

```swift
import ABIBridge
import UIKit

let object = ABIRuntime.shared.object(renderer)
let setImage = try await object.method(
    selector: "setImage:animated:",
    as: ((UIImage?, Bool) -> Void).self
)

try unsafe setImage.unsafeInvoke(image, true)
try unsafe setImage.unsafeInvoke(nil, false)
```

The function type describes only explicit arguments. ABIBridge supplies the receiver and selector, validates the argument count, and decodes each runtime type with ObjCTypeDecodeKit. No image lookup or framework import is required once the receiver exists.

Keep a method handle to reuse its decoded signature. Each invocation builds an independent call frame and uses normal Objective-C message dispatch, including forwarding. A replacement implementation must preserve the signature and ownership contract captured during lookup.

## Use Swift values

The frontend supports these mappings:

| Native encoding | Swift values |
| --- | --- |
| Boolean or signed character Boolean | `Bool` |
| Signed or unsigned integer | Matching signedness and width, including `Int` and `UInt` |
| Floating point | `Float`, `Double`, or a matching `CGFloat` |
| Objective-C object | Object types and Swift values that bridge to objects, optionally wrapped in `Optional` |
| Objective-C class | Class metatypes, optionally wrapped in `Optional` |
| Pointer or selector | Swift pointer types, `OpaquePointer`, or `Selector`; pointer values may be optional |
| Standard structures | `CGPoint`, `CGSize`, `CGRect`, and `NSRange` |
| Void result | `Void` |

There is no fixed argument-count limit. Signatures are synchronous and fixed: C variadic tails, blocks, arbitrary structures, unions, and nontrivial C++ values are not supported by this frontend.

Class arguments are checked before native dispatch, so an instance supplied for a `Class` parameter throws a value-conversion error. Class results remain metatypes during Swift conversion and cannot masquerade as instances. These conversions happen during invocation; lookup does not introspect Swift metatype metadata.

Object arguments stay alive until the call returns. Returned objects participate in ARC and are dynamically cast or bridged to the requested Swift result type. A failed cast throws ``ABIInvocationError/incompatibleValue(expected:actual:)``; nil for a nonoptional result throws ``ABIInvocationError/unexpectedNilResult(expected:)``. Pointer arguments and results remain borrowed, so their owners must establish the required lifetimes.

## Describe ownership when necessary

ABIBridge infers retained results from Objective-C method families such as `copy` and `new`. Instance initializers also consume an additional receiver reference. The handle keeps its own reference to the original receiver even if an initializer returns a replacement or nil.

Runtime type encodings omit ownership attributes. For a method declared with `ns_returns_retained` outside a retained method family:

```swift
let result = try await object.method(
    selector: "makeResult",
    as: (() -> NSObject).self,
    options: .init(returnsRetainedObject: true)
)
let value = try unsafe result.unsafeInvoke()
```

Use ``NativeMethodOptions`` to override retained-result or consumed-receiver inference when the declaration requires it. Consumed explicit arguments and Core Foundation ownership conventions require an adapter and are not managed by this frontend.

## Preserve the receiver's execution requirements

Lookup stays in the caller's isolation domain, and invocation is synchronous. Handles retain their receiver but do not make it thread-safe or actor-independent. For a main-actor UI object, perform lookup and invocation on the main actor.

The unsafe call contract includes argument nullability, class constraints, pointer validity, ownership annotations, and any requirements that runtime encodings cannot express. Native Objective-C or C++ exceptions are not converted to Swift errors. Keep dynamically loaded receiver classes and method implementations available for as long as the object and its handles are used.
