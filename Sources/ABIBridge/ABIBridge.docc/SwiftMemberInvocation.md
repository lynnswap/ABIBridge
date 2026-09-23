# Calling Swift members

Reuse a concrete type's metadata and symbol index for methods, initializers, and properties.

## Bind an existing object

For a renderer exposing a synchronous Swift method:

```swift
let object = ABIRuntime.shared.object(renderer)
let setImage = try await object.method(
    named: "setImage(_:animated:)",
    as: ((UIImage?, Bool) -> Void).self
)
try unsafe setImage.unsafeInvoke(image, true)
```

The handle retains its receiver and implementation images. Existing objects supply their runtime class metadata, including imported Objective-C classes with Swift extension methods. Bound handles stay in the caller's isolation domain.

## Reuse a type

```swift
let type = try await ABIRuntime.shared.swiftType(named: "Example.Renderer")
let start = try await type.method(named: "start()", as: (() -> Void).self)
let stop = try await type.method(named: "stop()", as: (() -> Void).self)
try unsafe start.unsafeInvoke(on: renderer)
try unsafe stop.unsafeInvoke(on: renderer)
```

Type lookup obtains the nominal descriptor and requests complete metadata. It rejects generic descriptors before calling an accessor that would need additional metadata or witness arguments. Type handles share the runtime's symbol indexes, retain their defining image, and remain valid after removeCachedResults().

Methods capture the selected implementation. Lookup prefers declarations in the type's defining image, then searches extension-qualified implementations in loaded images, and then walks superclass declarations in each superclass's defining image. Calls do not perform virtual redispatch. Generic superclass declarations require a separate adapter.

## Initializers and static members

```swift
let initialize = try await type.initializer(
    named: "init(text:)",
    as: ((String) -> AnyObject).self
)
let renderer = try unsafe initialize.unsafeInvoke("Hello")

let standard = try await type.staticGetter(named: "standard", as: String.self)
let value = try unsafe standard.unsafeInvoke()
```

Allocating class initializers and static members receive the type metadata automatically. Initializers transfer ordinary arguments to the callee. Explicitly borrowed initializer arguments (`__shared` in the demangled declaration) require a native adapter. A failable class initializer can use an optional class result. Initializers are resolved on the requested type; inherited allocation behavior must have its own compiler-generated initializer entry.

## Property accessors

```swift
let getText = try await type.getter(named: "text", as: String.self)
let setText = try await type.setter(named: "text", as: String.self)
try unsafe setText.unsafeInvoke(on: renderer, "Updated")
let text = try unsafe getText.unsafeInvoke(on: renderer)
```

An object scope also provides getter(named:as:) and setter(named:as:) returning bound handles. Static properties use staticGetter(named:as:) and staticSetter(named:as:). Accessors use the same unsafeInvoke spelling as other native calls.

Setters transfer ownership of the incoming value. Getters must be synchronous and nonthrowing: getter symbol names do not encode all effect annotations, so lookup cannot establish this contract.

## Fixed value receivers and adapters

For a supported fixed-layout value or a value conforming to ABIBridgeValue:

```swift
let pointType = try await runtime.swiftType(
    named: "Example.Point", as: Point.self
)
let translate = try await pointType.method(
    named: "translate(_:)", as: ((Double) -> Void).self,
    mutating: true
)
var point = existingPoint
try unsafe translate.unsafeInvoke(on: &point, 10)
```

The as: representation is useful for an unimportable native struct or enum. Class references, known Swift values, and declared trivial value adapters use the representations described in <doc:SwiftFunctionInvocation>. The adapter must match the actual native value layout; metadata size alone does not establish a call ABI.

Small nonmutating value receivers use ordinary trailing components. Indirect and mutating value receivers use the Swift context register. Specify mutating: true for mutating value methods/getters, and use an inout receiver. Value setters default to mutating unless consuming is true; an explicitly nonmutating setter can opt out with mutating: false.

For a `consuming` method, getter, or setter, pass `consuming: true` during lookup. Bound object methods and accessors expose the same option. This transfers an independent receiver copy and leaves the caller's value usable. Consuming and mutating conventions are mutually exclusive, and symbol names do not distinguish them. Custom value adapters must describe a trivial native value; nontrivial resource destruction requires a native adapter.

Writeback preserves the originating resource storage and implementation images without retaining a chain of intermediate value copies. After a native mutation, receiver writeback is attempted even if result conversion fails. If both conversions fail, NativeSwiftWritebackError preserves both errors. A writeback failure leaves the caller's receiver value unchanged, while other native side effects may already have occurred.

## Names, scopes, and limits

Label-only method names obtain canonical parameter/result names from their metatypes. Use a complete relative declaration when a wrapper has a different native name, such as `transform(Example.NativeValue) -> Example.NativeValue`. Operator names can omit fixity, such as `>(_:_:)`. If prefix and postfix implementations both match, lookup reports ambiguity; use `~~~ prefix(_:)` or a complete declaration to choose one. An accessor can similarly use `property.getter : Example.NativeValue` or `property.setter : Example.NativeValue`.

Framework, executable-path, and retained-image overloads select already-loaded images. They do not load missing frameworks. The method or type handle keeps its implementation alive, and custom wrapper results retain their call's owners. Raw pointers remain borrowed.

The unsafe boundary requires the actual declaration's ownership, effects, and actor/thread requirements. Generic metadata synthesis, async/throwing methods and getters, nontrivial foreign value layouts, and resilient-layout inference remain adapter cases.
