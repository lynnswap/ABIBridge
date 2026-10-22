# Calling Objective-C methods and reading ivars

Bind an existing receiver to invoke selectors using Swift function types or read named object ivars.

## Look up a method

The receiver must expose the selector to the Objective-C runtime. A Swift class can expose a method with `@objc`; a method using only the Swift ABI requires a different invocation backend.

```swift
import ABIBridge
import UIKit

let object = ABIRuntime.shared.object(renderer)
let setImage = try object.resolveMethodAndWait(
    selector: "setImage:animated:",
    as: ((UIImage?, Bool) -> Void).self
)

try unsafe setImage.unsafeInvoke(image, true)
try unsafe setImage.unsafeInvoke(nil, false)
```

The function type describes only explicit arguments. ABIBridge supplies the receiver and selector, validates the argument count, and decodes each runtime type with ObjCTypeDecodeKit. No image lookup or framework import is required once the receiver exists.

Keep a method handle to reuse its decoded signature. Each invocation builds an independent call frame and uses normal Objective-C message dispatch, including forwarding. A replacement implementation must preserve the signature and ownership contract captured during lookup.

Pass a `Selector`, including a compiler-checked `#selector`, when the declaration is importable. String names support declarations unavailable to the compiler. Both forms share the same invocation and hook contracts.

```swift
let append = try runtime.resolveObjCMethodAndWait(
    on: NSMutableString.self,
    selector: #selector(NSMutableString.append(_:)),
    as: ((String) -> Void).self
)
```

A compiler-checked selector verifies spelling. The function type and ownership options must still match the native declaration.

## Call a variadic method

Describe the concrete anonymous tail in the Swift signature and set `variadicFrom:` to the number of named arguments. Bound messages, receiver-independent messages, and captured implementations share this contract:

```swift
let format = try runtime.object(NSString.self as AnyObject).resolveMethodAndWait(
    selector: "stringWithFormat:",
    as: ((NSString, Float, Int8, NSString) -> NSString).self,
    variadicFrom: 1
)
let text = try unsafe format.unsafeInvoke("%.1f/%d/%@", 1.5, -3, "value")
```

ABIBridge applies C default promotions to the anonymous tail and infers representations for objects, classes, blocks, selectors, pointers, scalars, and standard CoreGraphics/Foundation structures. Other anonymous aggregates need the native C++ frontend. Runtime encodings describe only the named prefix, so supply the actual tail and any required sentinel.

Variadic messages resolve the receiver's current concrete IMP on each call; captured implementations keep their original IMP. Forwarding through `NSInvocation` cannot carry an anonymous tail. Fixed signatures retain their existing forwarding behavior.

## Prepare a message without retaining a receiver

Use `resolveObjCMethod` or `resolveObjCMethodAndWait` on `ABIRuntime` when a coordinator or other owner needs to cache a signature independently of the objects receiving its messages:

```swift
let append = try runtime.resolveObjCMethodAndWait(
    on: NSMutableString.self,
    selector: "appendString:",
    as: ((String) -> Void).self
)
let text = NSMutableString(string: "Hello")
try unsafe append.unsafeInvoke(on: text, " world")

let bound = try append.bind(to: text)
try unsafe bound.unsafeInvoke("!")
```

`NativeObjCMethod` validates each supplied receiver's class, method kind, and current ABI representation before message dispatch. Compatible subclass overrides and later replacements participate. Aggregate names may differ when layouts agree. Runtime encodings omit ownership attributes, so every implementation must honor the prepared ownership contract.

`bind(to:)` shares the signature in a `NativeBoundObjCMethod` that retains the receiver. Its last copy releases the receiver before the plan's image and optional code owner.

| Handle | Receiver lifetime | Dispatch |
| --- | --- | --- |
| `NativeObjCMethod` | Supplied for each call | Current Objective-C message dispatch |
| `NativeBoundObjCMethod` | Retained by the handle | Current Objective-C message dispatch |
| `NativeObjCImplementation` | Supplied for each call | Captured IMP |

Class-based preparation requires a concrete signature, possibly supplied by dynamic method resolution. For receiver-specific forwarding, use `object(receiver).resolveMethod(selector:as:)` or its `AndWait` variant. Class-based lookup constructs no receiver. Async class-based lookup runs dynamic resolution and signature preparation on a worker; its synchronous variant runs on the caller's thread. Keep dynamic classes and generated code valid through their final use.

## Reuse a message discovered on an existing object

Extract `method` from a bound handle to reuse its signature and code owner without retaining the original receiver or repeating lookup:

```swift
let bound = try runtime.object(firstRenderer).resolveMethodAndWait(
    selector: "setImage:animated:", as: ((UIImage?, Bool) -> Void).self
)
let setImage = bound.method
try unsafe setImage.unsafeInvoke(on: secondRenderer, image, true)
let secondBound = try setImage.bind(to: secondRenderer)
try unsafe secondBound.unsafeInvoke(nil, false)
```

The new receiver must have the lookup class or a subclass, or be a compatible class object for a class message. Invocation and binding validate its actual forwarding signature before use; missing or incompatible signatures throw. The message retains its class image and explicit code owner. Receiver isolation, ownership, and generated-code lifetime follow the same rules as class-based preparation.

## Capture an implementation for original calls

Use `resolveObjCImplementation` or `resolveObjCImplementationAndWait` when a method replacement needs to call the implementation selected before replacement:

```swift
let original = try ABIRuntime.shared.resolveObjCImplementationAndWait(
    on: UIView.self,
    selector: "sizeThatFits:",
    as: ((CGSize) -> CGSize).self
)
let measured = try unsafe original.unsafeInvoke(on: view, proposedSize)
```

The handle keeps a fixed IMP and signature without an instance. Supply a compatible receiver on each call; subclass instances use the captured IMP. Forwarding-only selectors cannot be captured.

For a class method, pass the ordinary class with `classMethod: true` and invoke with the class object, such as `SomeClass.self as AnyObject`. A subclass class object is also valid. Wrong receiver kinds and unrelated classes fail before calling native code.

The handle retains discoverable implementation and class images. Caller-created classes must stay registered. Generated IMPs must remain callable; do not call `imp_removeBlock` or free generated code while a capture may use it. Pass `retaining:` to retain an owner responsible for that code/class lifetime. A retained block alone does not own the runtime trampoline produced by `imp_implementationWithBlock`.

Captured calls share the value conversions and ownership options below and preserve function-pointer authentication through the C backend. The consumer manages replacement installation, ordering, and restoration.

## Call methods that report errors

A Cocoa method that reports failure through a trailing `NSError **` parameter can be prepared with a Swift `throws` signature that omits that parameter, as the Swift importer does. A `Void` result corresponds to a `BOOL` method that fails with `NO`; another result corresponds to an object method that fails with `nil`:

```swift
let open = try object.resolveMethodAndWait(
    selector: "openDocument:error:",
    as: ((URL) throws -> NSDocument).self
)
do {
    let document = try unsafe open.unsafeInvoke(url)
} catch let error as NSError {
    print(error.domain, error.code)
}
```

Invocation passes an autoreleasing error slot and throws the `NSError` the method stores. A method that fails without storing one throws ``NativeObjCUnreportedFailure``. Lookup rejects a `throws` signature when the method has no trailing `NSError **` parameter, when its result is neither `BOOL` (for `Void`) nor an object, and when the requested result is `Optional`, because `nil` then cannot be told apart from failure. Bound and unbound messages, class methods, and captured implementations accept the same signatures; variadic methods do not.

To manage the slot yourself, declare the parameter as `AutoreleasingUnsafeMutablePointer<NSError?>?` and pass storage that does not own its value, such as zeroed raw memory. Read the error through the pointer's `pointee` inside the same autorelease pool; that read retains it.

## Handle lookup failures

Bound lookup, implementation capture, and hook preparation report known failures as `ABIResolutionError`. Missing selectors throw `declarationNotFound` with the requested class and selector; unsupported encodings throw `unsupportedDeclaration`. Unknown native errors retain their original domains and codes.

A signature mismatch carries `ABIResolutionError.SignatureMismatch`. Its `declaration` identifies the request, `position` identifies the zero-based explicit argument, result, argument count, or whole signature, and `expected` / `found` preserve the requested type and available native representation. Explicit argument indexes exclude `self` and `_cmd`.

```swift
do {
    _ = try object.resolveMethodAndWait(selector: "increment:", as: ((Double) -> Int64).self)
} catch let ABIResolutionError.declarationNotFound(request) {
    // Only known absence should select a consumer-defined alternative.
    print("Unavailable:", request.name)
} catch let ABIResolutionError.signatureMismatch(details) {
    print(details.position, details.expected, details.found)
}
```

For a native `increment:` taking `Int64`, this example reports `.argument(0)`, `Swift.Double`, and `q`. A mismatch in the return type reports `.result` instead. Coordinated hook installation keeps its `NativeObjCHookInstallationError` envelope; inspect `underlyingError` for the same diagnostic.

Match `signatureMismatch(let details)` to access this payload. Errors from standalone value-layout checks can have a nil `declaration`.

To report a failure without matching its case, show the error's `localizedDescription`. It names the declaration or image and the details the case carries. For the mismatch above on a `Counter` receiver, it reads `-[Counter increment:] does not match the requested signature at argument 0: expected Swift.Double, found q.`

## Read an object ivar

Use the literal runtime ivar name, including any underscore; this is not a property getter or a key-value coding lookup:

```swift
let object = ABIRuntime.shared.object(renderer)
let image = try object.value(forIvar: "_image", as: UIImage?.self)
let type = try object.value(forIvar: "_rendererClass", as: AnyClass?.self)
```

Lookup searches the receiver's Objective-C class hierarchy and checks the ivar encoding before reading. The special isa field is decoded through the runtime rather than read as a raw class pointer. Object values can use ordinary Swift bridging, such as `NSString` to `String` or `NSArray` to an array. Class ivars return metatypes. Typed block ivars use `@convention(block)`; the caller must know the inner signature.

A missing ivar throws `ABIResolutionError.ivarNotFound`. A present nil value becomes nil only for an optional requested type; otherwise it throws `ABIInvocationError.unexpectedNilResult`. Incompatible values throw a conversion error. Scalars, raw pointers, and aggregate ivars are rejected even when their size matches an object pointer.

Reads return an independently owned object reference. Weak ivars can yield nil under Objective-C runtime semantics; unsafe-unretained pointees must stay alive through the read. Synchronize with writers and respect the receiver's actor or thread. This API reads Objective-C ivars directly; Swift stored properties and property accessors require their own APIs.

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
| Pointer or selector | Swift pointer types, `OpaquePointer`, `Unmanaged<T>`, or `Selector`; pointer values may be optional |
| Structures with complete field encodings | Caller-selected compatible Swift values, including SDK and user-defined structures, nested structures, and fixed-size array fields |
| Void result | `Void` |

There is no fixed argument-count limit. Structure layouts come from runtime encodings for messages, captured implementations, and managed hooks, without per-name registration.

For example, a method declared with UIEdgeInsets can use the SDK type directly:

```swift
let adjusted = try runtime.object(receiver).resolveMethodAndWait(
    selector: "adjustInsets:", as: ((UIEdgeInsets) -> UIEdgeInsets).self
)
let result = try unsafe adjusted.unsafeInvoke(insets)
```

Choose an SDK or caller-defined structure whose field offsets, representation, alignment, and ownership match the native value. Names may differ. The native extent must cover the Swift value without exceeding its stride; tail padding needs no artificial fields. Bounds checks do not prove ABI compatibility.

Incomplete structure encodings, bitfields, unions, and nontrivial C++ values still need an appropriate native adapter. Long-double fields use the double representation of Apple's ARM ABI.

Class arguments are checked before native dispatch, so an instance supplied for a `Class` parameter throws a value-conversion error. Class results remain metatypes during Swift conversion and cannot masquerade as instances. These conversions happen during invocation; lookup does not introspect Swift metatype metadata.

Object arguments stay alive until the call returns. Returned objects participate in ARC and are dynamically cast or bridged to the requested Swift result type. A failed cast throws ``ABIInvocationError/incompatibleValue(expected:actual:)``; nil for a nonoptional result throws ``ABIInvocationError/unexpectedNilResult(expected:)``. Pointer arguments and results remain borrowed, so their owners must establish the required lifetimes.

## Pass and receive typed blocks

Declare the block's Objective-C calling convention explicitly, then use the type in the ordinary method signature:

```swift
typealias Transform = @convention(block) (Int32) -> Int32

let apply = try object.resolveMethodAndWait(
    selector: "apply:using:",
    as: ((Int32, Transform?) -> Int32).self
)
let transform: Transform = { $0 + 1 }
let answer = try unsafe apply.unsafeInvoke(41, transform)

let getter = try object.resolveMethodAndWait(selector: "handler", as: (() -> Transform?).self)
let returned = try unsafe getter.unsafeInvoke()
let next = returned?(42)
```

Arguments are copied to owned block storage for the call. A native API that stores a callback must follow its normal block-copy contract; its retained copy keeps captures alive after invocation returns. Returned blocks are copied and managed by Swift ownership. Block-encoded returns default to borrowed-result handling even when the selector begins with `copy` or `new`; Clang does not apply those method families to block return types. Supply `returnsRetainedObject: true` when an explicit native ownership attribute returns a block at +1. Optional block values preserve nil; an unexpected nil for a nonoptional block throws an invocation error.

Use a typed block variable to bridge a Swift closure. The frontend distinguishes blocks from ordinary Swift closures and C function pointers. Object-encoded values may carry blocks, but a non-block object fails block conversion.

The usual `@?` encoding omits the block's inner signature. Supply it exactly; the Swift compiler then invokes the block through that convention, including nested completion blocks and Objective-C-representable values. See the [Clang block specification](https://clang.llvm.org/docs/Block-ABI-Apple.html) and [Swift function metadata flags](https://github.com/swiftlang/swift/blob/main/include/swift/ABI/MetadataValues.h).

Block ownership does not establish actor isolation or move callbacks to another executor. Callbacks execute where the native API invokes them, and callbacks that require the main actor must be invoked there. Completion blocks are not automatically converted into async functions.

## Describe ownership when necessary

ABIBridge infers retained results from Objective-C method families such as `copy` and `new`. Instance initializers also consume an additional receiver reference. The handle keeps its own reference to the original receiver even if an initializer returns a replacement or nil.

Runtime type encodings omit ownership attributes. For a method declared with `ns_returns_retained` outside a retained method family:

```swift
let result = try object.resolveMethodAndWait(
    selector: "makeResult",
    as: (() -> NSObject).self,
    options: .init(returnsRetainedObject: true)
)
let value = try unsafe result.unsafeInvoke()
```

Use ``NativeMethodOptions`` to override retained-result or consumed-receiver inference when the declaration requires it. Set `consumedArguments` to the zero-based explicit parameter indexes annotated `ns_consumed`; indexes exclude `self` and `_cmd`:

```swift
let consume = try object.resolveMethodAndWait(
    selector: "consumeObject:",
    as: ((NSObject?) -> Void).self,
    options: .init(consumedArguments: [0])
)
try unsafe consume.unsafeInvoke(value)
```

For each selected object, class, or block parameter, invocation transfers a separate +1 reference to native code. The caller keeps its ordinary Swift value. Conversion failures before native entry release prepared references without transferring them. The same options apply to receiver-independent messages, captured implementations, and managed hooks. A nil optional parameter remains nil.

Core Foundation values use `Unmanaged<T>`, optionally wrapped in `Optional`, with manual reference ownership. Use `passUnretained` for borrowed input, `takeRetainedValue()` for +1 results, and `takeUnretainedValue()` for borrowed results. A `cf_consumed` input needs `passRetained`; release that reference if invocation fails before native entry. See <doc:CFunctionInvocation>.

## Preserve the receiver's execution requirements

For a MainActor UI object, resolve and invoke from MainActor. Async bound lookup keeps receiver-specific dynamic resolution and forwarding-signature callbacks on that executor while a worker acquires images, decodes signatures, and prepares shared call interfaces:

```swift
@MainActor
func updateImage(_ image: UIImage?, on renderer: AnyObject) async throws {
    let setImage = try await ABIRuntime.shared.object(renderer).resolveMethod(
        selector: "setImage:animated:", as: ((UIImage?, Bool) -> Void).self
    )
    try unsafe setImage.unsafeInvoke(image, true)
}
```

Class-based `resolveObjCMethod` and `resolveObjCImplementation` perform class lookup, dynamic method resolution, and call preparation on a worker. Use their `AndWait` variants for synchronous resolution. Neither form requires `prepare`; shared call interfaces join required preparation already in progress. Bound receivers and explicit code owners stay in the caller's isolation domain.

Ivar reads, binding, invocation, and receiver-specific callbacks remain synchronous. Receiver retention does not establish thread safety or isolation. Swift ABI member lookup follows the same async/`AndWait` naming; see <doc:SwiftMemberInvocation>.

The unsafe call contract includes argument nullability, class constraints, pointer validity, ownership annotations, and any requirements that runtime encodings cannot express. Foundation signature-construction failures are reported as lookup errors. An Objective-C exception raised by the invoked method is caught where ABIBridge calls it and thrown as ``NativeObjCException`` with the exception's name, reason, and call stack; arguments already transferred to the method are not reclaimed. C++ exceptions are not translated. Keep dynamically loaded receiver classes and method implementations available for as long as the object and its handles are used.
