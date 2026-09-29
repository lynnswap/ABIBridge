# Calling Objective-C methods and reading ivars

Bind an existing receiver to invoke selectors using Swift function types or read named object ivars.

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

The `selector:` parameter also accepts `Selector` values, including compiler-checked `#selector` expressions. String names remain available for declarations that cannot be imported. Both forms use the same dispatch, ownership, isolation, and error handling, including captured implementations and direct/MainActor/coordinated hooks.

```swift
let append = try runtime.objcMethod(
    on: NSMutableString.self,
    selector: #selector(NSMutableString.append(_:)),
    as: ((String) -> Void).self
)
```

A compiler-checked selector confirms the declaration's spelling; the supplied function type and ownership contract still describe the native call.

## Prepare a message without retaining a receiver

Use `ABIRuntime.objcMethod(on:selector:as:classMethod:options:retaining:)` when a coordinator or other owner needs to cache a signature independently of the objects receiving its messages:

```swift
let append = try runtime.objcMethod(
    on: NSMutableString.self,
    selector: "appendString:",
    as: ((String) -> Void).self
)
let text = NSMutableString(string: "Hello")
try unsafe append.unsafeInvoke(on: text, " world")

let bound = try append.bind(to: text)
try unsafe bound.unsafeInvoke("!")
```

`NativeObjCMethod` retains no receiver instance. It validates the supplied receiver's class/method kind and current ABI representation, then follows normal message dispatch. Compatible subclass overrides and later hook installations are observed. Aggregate names may differ when their native layouts agree. Encoding checks cannot establish ownership attributes that the runtime omits: replacements and overrides must honor the prepared ownership contract.

`bind(to:)` returns a `NativeBoundObjCMethod` retaining that receiver and sharing the prepared signature. Its last copy releases the receiver before the prepared plan's image and optional code owner. Like `object(receiver).method(...)`, a bound handle expects later replacements to preserve its prepared signature and ownership.

| Handle | Receiver lifetime | Dispatch |
| --- | --- | --- |
| `NativeObjCMethod` | Supplied for each call | Current Objective-C message dispatch |
| `NativeBoundObjCMethod` | Retained by the handle | Current Objective-C message dispatch |
| `NativeObjCImplementation` | Supplied for each call | Captured IMP |

Class-based preparation requires a concrete method signature, including signatures supplied by dynamic method resolution. Receiver-specific forwarding signatures remain available through `object(receiver).method(...)`; one object's forwarding behavior is not assumed to apply to other instances. No receiver is constructed during class-based preparation, and no actor hop is performed. Caller-managed dynamic classes and generated code must stay valid through their final use.

## Capture an implementation for original calls

Use `objcImplementation(on:selector:as:classMethod:options:retaining:)` when a method replacement needs to call the implementation selected before replacement:

```swift
let original = try ABIRuntime.shared.objcImplementation(
    on: UIView.self,
    selector: "sizeThatFits:",
    as: ((CGSize) -> CGSize).self
)
let measured = try unsafe original.unsafeInvoke(on: view, proposedSize)
```

The capture holds a fixed IMP and signature, without retaining an instance. Supply a compatible receiver for each call; subclass instances are accepted, but their overrides are not selected. Ordinary `NativeBoundObjCMethod` handles continue to use current message dispatch. Forwarding-only selectors cannot be captured.

For a class method, pass the ordinary class with `classMethod: true` and invoke with the class object, such as `SomeClass.self as AnyObject`. A subclass class object is also valid. Wrong receiver kinds and unrelated classes fail before calling native code.

The handle retains discoverable implementation and class images. Caller-created classes must stay registered. Generated IMPs must remain callable; do not call `imp_removeBlock` or free generated code while a capture may use it. Pass `retaining:` to retain an owner responsible for that code/class lifetime. A retained block alone does not own the runtime trampoline produced by `imp_implementationWithBlock`.

Captures use the same supported values and ownership overrides as ordinary selector calls. Lookup and invocation are synchronous on the caller's executor. The captured function pointer preserves authentication through the C call backend; an unsigned loader-inspection address is not used as the callable. Foreign exceptions must not cross that backend boundary.

Installation, ordering, and restoration of replacements remain the consumer's responsibility.

## Handle lookup failures

Known Objective-C lookup failures use `ABIResolutionError` across bound methods, captured implementations, and hook preparation. A missing selector throws `declarationNotFound` with the originally requested class and selector; an unsupported encoding throws `unsupportedDeclaration`. Unknown native error domains and codes remain available as their original errors. Exceptions from invoked native code are not translated.

A signature mismatch carries `ABIResolutionError.SignatureMismatch`. Its `declaration` identifies the request, `position` identifies the zero-based explicit argument, result, argument count, or whole signature, and `expected` / `found` preserve the requested type and available native representation. Explicit argument indexes exclude `self` and `_cmd`.

```swift
do {
    _ = try object.method(selector: "increment:", as: ((Double) -> Int64).self)
} catch let ABIResolutionError.declarationNotFound(request) {
    // Only known absence should select a consumer-defined alternative.
    print("Unavailable:", request.name)
} catch let ABIResolutionError.signatureMismatch(details) {
    print(details.position, details.expected, details.found)
}
```

For a native `increment:` taking `Int64`, this example reports `.argument(0)`, `Swift.Double`, and `q`. A mismatch in the return type reports `.result` instead. Coordinated hook installation keeps its `NativeObjCHookInstallationError` envelope; inspect `underlyingError` for the same diagnostic.

The structured payload replaces the previous `signatureMismatch(expected:found:)` case. Match `signatureMismatch(let details)` and access its fields; no compatibility case or initializer is retained. Errors produced before a declaration is known, such as standalone value-layout checks, may have a nil `declaration`.

## Read an object ivar

Use the literal runtime ivar name, including any underscore; this is not a property getter or a key-value coding lookup:

```swift
let object = ABIRuntime.shared.object(renderer)
let image = try object.value(forIvar: "_image", as: UIImage?.self)
let type = try object.value(forIvar: "_rendererClass", as: AnyClass?.self)
```

Lookup searches the receiver's Objective-C class hierarchy and checks the ivar encoding before reading. The special isa field is decoded through the runtime rather than read as a raw class pointer. Object values can use ordinary Swift bridging, such as `NSString` to `String` or `NSArray` to an array. Class ivars return metatypes. Typed block ivars use `@convention(block)`; the caller must know the inner signature.

A missing ivar throws `ABIResolutionError.ivarNotFound`. A present nil value becomes nil only for an optional requested type; otherwise it throws `ABIInvocationError.unexpectedNilResult`. Incompatible values throw a conversion error. Scalars, raw pointers, and aggregate ivars are rejected even when their size matches an object pointer.

Reads run synchronously on the caller's executor. A returned object owns a reference independently of the receiver. Weak reads follow Objective-C runtime semantics and can yield nil; an unsafe-unretained pointee must remain alive throughout the read. Synchronization with writers and actor/thread affinity remain the caller's responsibility. This API does not infer Swift stored-property layouts, walk object graphs, or invoke property accessors.

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
| Structures with complete field encodings | Caller-selected compatible Swift values, including SDK and user-defined structures, nested structures, and fixed-size array fields |
| Void result | `Void` |

There is no fixed argument-count limit. Signatures are synchronous and fixed. Structure layouts come from the method's native type encoding, including the ABI used for captured implementations and managed hooks. The library does not require a registration for each structure name.

For example, a method declared with UIEdgeInsets can use the SDK type directly:

```swift
let adjusted = try runtime.object(receiver).method(
    selector: "adjustInsets:", as: ((UIEdgeInsets) -> UIEdgeInsets).self
)
let result = try unsafe adjusted.unsafeInvoke(insets)
```

The unsafe caller guarantees that the selected Swift type's field offsets, representation, alignment, and ownership are compatible with the native value. It may be an imported SDK type or a caller-defined byte-compatible structure. Type names do not need to match. The native extent must cover the Swift value without exceeding its stride, so native tail padding does not require artificial Swift fields. A size check protects storage bounds; it does not prove ABI compatibility.

C variadic tails, incomplete structure encodings, bitfields, unions, and nontrivial C++ values still need an appropriate native adapter. Long-double fields use the platform's double representation on Apple ARM; x86_64 x87 long-double fields require a native adapter.

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
