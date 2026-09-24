# Calling Objective-C methods

Bind an existing receiver and invoke its selectors using Swift function types.

## Look up a method

The receiver must expose the selector to the Objective-C runtime. A Swift class can expose a method with `@objc`; a method using only the Swift ABI requires a different invocation backend.

```swift
import ABIBridge
import UIKit

let object = ABIRuntime.shared.object(renderer)
let setImage = try object.method(
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
| Objective-C block | Typed `@convention(block)` values, optionally wrapped in `Optional` |
| Pointer or selector | Swift pointer types, `OpaquePointer`, or `Selector`; pointer values may be optional |
| Standard structures | `CGPoint`, `CGSize`, `CGRect`, and `NSRange` |
| Void result | `Void` |

There is no fixed argument-count limit. Signatures are synchronous and fixed: C variadic tails, arbitrary structures, unions, and nontrivial C++ values are not supported by this frontend.

Class arguments are checked before native dispatch, so an instance supplied for a `Class` parameter throws a value-conversion error. Class results remain metatypes during Swift conversion and cannot masquerade as instances. These conversions happen during invocation; lookup does not introspect Swift metatype metadata.

Object arguments stay alive until the call returns. Returned objects participate in ARC and are dynamically cast or bridged to the requested Swift result type. A failed cast throws ``ABIInvocationError/incompatibleValue(expected:actual:)``; nil for a nonoptional result throws ``ABIInvocationError/unexpectedNilResult(expected:)``. Pointer arguments and results remain borrowed, so their owners must establish the required lifetimes.

## Pass and receive typed blocks

Declare the block's Objective-C calling convention explicitly, then use the type in the ordinary method signature:

```swift
typealias Transform = @convention(block) (Int32) -> Int32

let apply = try object.method(
    selector: "apply:using:",
    as: ((Int32, Transform?) -> Int32).self
)
let transform: Transform = { $0 + 1 }
let answer = try unsafe apply.unsafeInvoke(41, transform)

let getter = try object.method(selector: "handler", as: (() -> Transform?).self)
let returned = try unsafe getter.unsafeInvoke()
let next = returned?(42)
```

Arguments are copied to owned block storage for the call. A native API that stores a callback must follow its normal block-copy contract; its retained copy keeps captures alive after invocation returns. Returned blocks are copied and managed by Swift ownership. Block-encoded returns default to borrowed-result handling even when the selector begins with `copy` or `new`; Clang does not apply those method families to block return types. Supply `returnsRetainedObject: true` when an explicit native ownership attribute returns a block at +1. Optional block values preserve nil; an unexpected nil for a nonoptional block throws an invocation error.

The frontend distinguishes block function metadata from ordinary Swift closures and C function pointers. Use a typed block variable to bridge a Swift closure explicitly. An object-encoded argument or result may also carry a typed block, but a non-block object cannot be returned as a block.

The usual `@?` method encoding does not describe the block's own arguments and result. The caller must supply that exact signature. A block's inner call is performed by the Swift compiler through its declared convention, including nested completion blocks and Objective-C-representable values. ABI conventions follow the [Clang block specification](https://clang.llvm.org/docs/Block-ABI-Apple.html) and [Swift function metadata flags](https://github.com/swiftlang/swift/blob/main/include/swift/ABI/MetadataValues.h).

Block ownership does not establish actor isolation or move callbacks to another executor. Callbacks execute where the native API invokes them, and callbacks that require the main actor must be invoked there. Completion blocks are not automatically converted into async functions.

## Describe ownership when necessary

ABIBridge infers retained results from Objective-C method families such as `copy` and `new`. Instance initializers also consume an additional receiver reference. The handle keeps its own reference to the original receiver even if an initializer returns a replacement or nil.

Runtime type encodings omit ownership attributes. For a method declared with `ns_returns_retained` outside a retained method family:

```swift
let result = try object.method(
    selector: "makeResult",
    as: (() -> NSObject).self,
    options: .init(returnsRetainedObject: true)
)
let value = try unsafe result.unsafeInvoke()
```

Use ``NativeMethodOptions`` to override retained-result or consumed-receiver inference when the declaration requires it. Consumed explicit arguments and Core Foundation ownership conventions require an adapter and are not managed by this frontend.

## Preserve the receiver's execution requirements

Selector lookup and invocation are synchronous and stay in the caller's isolation domain. Call `method(selector:as:options:)` without `await`; the Swift ABI `method(named:as:consuming:)` overload remains asynchronous. Handles retain their receiver but do not make it thread-safe or actor-independent. For a main-actor UI object, perform lookup and invocation on the main actor.

The unsafe call contract includes argument nullability, class constraints, pointer validity, ownership annotations, and any requirements that runtime encodings cannot express. Foundation signature-construction failures are reported as lookup errors. Exceptions from the invoked Objective-C or C++ implementation are not converted to Swift errors. Keep dynamically loaded receiver classes and method implementations available for as long as the object and its handles are used.
