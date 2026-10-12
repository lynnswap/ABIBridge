# Editing and inspecting hook calls

Edit typed arguments, continue with original or adjusted values, and inspect the registered declaration.

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

`RenderRequest` is the target API's class with the shown writable properties and methods. The callback receives the same instance, so other owners observe its mutations. `try call.receiver` supplies the receiving object for casting and property access. Use `hookMainActorMethod` when native callers must enter on MainActor, including UI objects.

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

The target must expose that setter with a matching signature. For repeated callbacks with a known argument class, prepare and reuse its implementation as described in <doc:ObjectiveCInvocation>.

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

`declaration` identifies the registration request: the class and selector for Objective-C, the supplied name for imports, or the selection declaration for a named virtual entry. An explicit adapter entry has nil. It does not identify an earlier interposer's implementation.

`signature` is the function metatype supplied through `as:`, excluding hidden receiver/selector arguments. The caller must establish that it matches the native ABI; a C++ symbol generally omits the return type.

`description` combines that declaration and type, using an unnamed-entry label when needed. It is prepared during registration, so `print(call)` performs no value inspection, image lookup, or demangling.

Diagnostic values can be copied for later use. These synchronous invocations keep `proceed` and Objective-C receiver access on the incoming thread until callback return. Raw pointers keep their borrowed lifetime, and saving diagnostics does not make an invocation Sendable. Swift async continuations instead follow <doc:SwiftFunctionHooks> and <doc:SwiftMethodHooks>.

`proceed` follows the remaining hook snapshot and its captured predecessor; it does not redispatch the symbol/selector or bypass every other hook. Dedicated initializer hooks instead expose initialization phases, as described in <doc:ObjectiveCInitializerHooks>.
