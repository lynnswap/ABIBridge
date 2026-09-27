# Editing and inspecting hook calls

Work with ordinary typed arguments, continue with their original or adjusted values, and inspect the declaration without reading native object memory.

## Edit a referenced object

For an existing Objective-C `Renderer` method `render:` that receives a mutable `RenderRequest` instance:

```swift
let hook = try unsafe runtime.hookMethod(
    on: Renderer.self,
    selector: "render:",
    as: ((RenderRequest) -> Void).self,
    onFailure: { print($0) }
) { call, request in
    request.scale = 2
    request.prepareForRendering()
    try call.proceed(request)
    request.didRender = true
}
```

Here `RenderRequest` is the actual class used by the target API, with those writable properties and methods. The callback receives that same instance; no argument wrapper is required. Other owners observe its mutations too. Within the callback, `try call.receiver` also provides the receiving object for casting to its known class and editing its properties. Use `hookMainActorMethod` for objects whose native callers must run on MainActor, including UI objects.

Passing a different object to `proceed` changes the reference received by downstream hooks and the implementation. It does not assign a new value to the caller's reference variable. Bridged Swift values, such as a Swift dictionary converted from an Objective-C object, may have value semantics; use the actual reference type when shared mutation is intended.

Object changes are not rolled back if the callback later fails. Fallback before a completed continuation uses the original argument references, whose objects may already have changed. After a completed continuation, its result is preserved without repeating the native call.

## Use an object without its concrete class

For an Objective-C argument whose class cannot be imported, accept `AnyObject` and invoke a known setter using its runtime signature:

```swift
let hook = try unsafe runtime.hookMethod(
    on: Renderer.self,
    selector: "render:",
    as: ((AnyObject) -> Void).self,
    onFailure: { print($0) }
) { call, argument in
    let setScale = try runtime.object(argument).method(
        selector: "setScale:", as: ((Double) -> Void).self
    )
    try unsafe setScale.unsafeInvoke(2)
    try call.proceed(argument)
}
```

The target must expose a setter with that signature. This path does not make a read-only property writable or reinterpret a C++ pointer as an Objective-C instance. Repeated callbacks can use an appropriately prepared implementation when the argument class and method contract are already known; see <doc:ObjectiveCInvocation>.

## Edit values and native pointees

For supported value arguments, create a local copy, modify it, and pass the new value to `proceed`. The original caller's variable is unaffected. Native `inout`, reference ownership and consuming arguments require their own ABI contract.

C++ pointer arguments and pointer-backed `ABIBridgeValue` adapters can expose writable native properties directly. The adapter establishes the actual layout or compiled accessor contract. Mutating its pointee affects every reference to that same native object. See <doc:CXXVirtualHooks> for a typed adapter example. Arbitrary C++ object layouts are not inferred from Swift property names.

## Inspect the declaration and supplied signature

Ordinary Objective-C, imported-function and C++ virtual invocations provide:

```swift
print(call.declaration)
print(call.signature)
print(call)
```

`declaration` identifies the registration request. For Objective-C it includes the registration class and selector, such as `-[Renderer render:]`; for imports it preserves the supplied declaration/name form. A named virtual entry carries its selection declaration, while an explicit adapter entry has a nil declaration. This information does not identify an implementation installed earlier by another writer.

`signature` is exactly the Swift function-type metatype supplied via `as:`, excluding hidden receiver/selector arguments. It describes the caller's contract, not an inferred or verified native signature. In particular, a C++ symbol does not generally encode the return type.

`description`, also used by `print(call)`, is prepared when the hook is registered. It combines a readable declaration with that supplied type, or an unnamed-entry label when no declaration is available. It does not inspect receiver/argument values, invoke their `description` methods, query images, or demangle symbols during the call.

Copied declaration, signature and description values may be kept for later diagnostics. `proceed` remains valid only on the callback's incoming thread before return. Objective-C receiver access follows that same checked scope; raw native pointers keep their borrowed lifetime contract. The invocation is not made Sendable by these diagnostic properties.

`proceed` follows the remaining hook snapshot and its captured predecessor; it does not redispatch the symbol/selector or bypass every other hook. Dedicated initializer hooks instead expose initialization phases, as described in <doc:ObjectiveCInitializerHooks>.
