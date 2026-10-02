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

## Reuse a discovered implementation with another object

A bound method's `method` property returns its prepared explicit-receiver handle. Keeping that value does not keep the original receiver binding alive. This also works for getters, setters, and async members.

```swift
let bound = try await runtime.object(firstRenderer).method(
    named: "start()", as: (() -> Void).self
)
let start = bound.method
try unsafe start.unsafeInvoke(on: secondRenderer)
let secondBound = try start.bind(to: secondRenderer)
try unsafe secondBound.unsafeInvoke()
```

The prepared handle retains the native type context and implementation images without repeating discovery. Calls and new bindings preserve the implementation chosen during lookup; they do not select an override from the new receiver. The receiver must match that context, including an instantiated generic specialization or extension constraint. Binding only retains the supplied class object; ordinary invocation validates its representation and receiver type with the existing receiver plan before calling the member. An incompatible receiver therefore reports an invocation error, including when an AnyObject adapter accepts its representation.

`bind(to:)` retains a class object until the last bound copy is released. It does not change the original bound handle or the native ownership, effects, or actor/thread requirements. Async handles keep their existing caller-isolation or concurrent behavior. Value receivers continue to use explicit invocation, including `inout` for mutating members.

## Use an instantiated generic receiver

An existing object such as `Renderer<Content>` can use the same `object(...).method/getter/setter` APIs for members with concrete parameter and result types. Lookup identifies the unspecialized declaration through the live class's nominal descriptor while retaining the instantiated metadata. The implementation obtains its enclosing generic metadata and protocol witnesses from self. Private declaration owners and inherited members follow the same lookup rules.

For example, given an existing `Renderer<Content>` with `func title() -> String`:

```swift
let title = try await runtime.object(renderer).method(
    named: "title()", as: (() -> String).self
)
let text = try unsafe title.unsafeInvoke()
```

This does not construct generic metadata or infer a substituted ABI. A member returning `Content` has a dependent formal result, which can remain indirect even when the actual value fits registers. Label-only lookup does not rewrite that declaration to the substituted concrete type. Use a compiled adapter, or the existing complete-declaration and explicit value-adapter APIs with the actual formal convention. A complete spelling such as `projected() -> A` only selects a symbol: it does not verify the supplied representation or turn the generic result into an ordinary direct result.

Member lookup also considers same-type constrained extensions such as `extension Renderer where Content == Int`. Requirements can equate a whole type parameter to a concrete type or another enclosing type parameter. Lookup checks those requirements against the current receiver or superclass specialization; a cached result for one specialization does not apply to another. Multiple applicable extension declarations remain ambiguous rather than being ordered by Swift overload specificity. Associated-type projections and generic type expressions requiring substitution remain adapter cases. A new protocol constraint can add a witness argument beyond self and is not inferred by this lookup. Methods introducing additional generic parameters still require a compiled adapter because their metadata and witnesses are separate arguments. Generic opaque results and virtual replacement retain their existing adapter requirements. Receiver ownership, effects, actor isolation, and captured implementation dispatch are unchanged.

When no supported candidate can be selected, an unestablished extension requirement or one needing a compiled adapter reports `ABIResolutionError.unsupportedDeclaration`. A proven specialization mismatch or an absent declaration reports `ABIResolutionError.declarationNotFound`. Unsupported candidates do not hide supported extensions or inherited members; a proven mismatch remains inapplicable even when another requirement cannot be evaluated.

## Reuse a type

```swift
let type = try await ABIRuntime.shared.swiftType(named: "Example.Renderer")
let start = try await type.method(named: "start()", as: (() -> Void).self)
let stop = try await type.method(named: "stop()", as: (() -> Void).self)
try unsafe start.unsafeInvoke(on: renderer)
try unsafe stop.unsafeInvoke(on: renderer)
```

Type lookup obtains the nominal descriptor and requests complete metadata. It rejects generic descriptors before calling an accessor that would need additional metadata or witness arguments. Type handles share the runtime's symbol indexes, retain their defining image, and remain valid after removeCachedResults().

Methods capture the selected implementation. Lookup prefers declarations in the type's defining image, then searches extension-qualified implementations in loaded images, and then walks superclass declarations in each superclass's defining image. Calls do not perform virtual redispatch. Existing receiver metadata also supplies the context for concrete members declared by a generic superclass.

## Initializers and static members

```swift
let initialize = try await type.initializer(
    named: "init(text:)",
    as: ((String) -> AnyObject).self
)
let renderer = try unsafe initialize.unsafeInvoke("Hello")

let standard = try await type.staticGetter(named: "standard", as: (() -> String).self)
let value = try unsafe standard.unsafeInvoke()
```

Allocating class initializers and static members receive the type metadata automatically. Initializers transfer ordinary arguments to the callee. Use NativeSwiftBorrowing for explicitly borrowed initializer arguments (`__shared` in the demangled declaration); see <doc:SwiftArgumentConventions>. A failable class initializer can use an optional class result. Initializers are resolved on the requested type; inherited allocation behavior must have its own compiler-generated initializer entry.

Opaque some results use NativeSwiftOpaqueValue for functions, methods, and getters; see <doc:SwiftOpaqueResults>.

## Property accessors

```swift
let getText = try await type.getter(named: "text", as: (() -> String).self)
let setText = try await type.setter(named: "text", as: String.self)
try unsafe setText.unsafeInvoke(on: renderer, "Updated")
let text = try unsafe getText.unsafeInvoke(on: renderer)
```

An object scope also provides getter(named:as:) and setter(named:as:) returning bound handles. Static properties use staticGetter(named:as:) and staticSetter(named:as:). Accessors use the same unsafeInvoke spelling as other native calls.

Setters transfer ownership of the incoming value. Getters use a zero-argument function metatype, such as `(() -> String).self`, `(() throws -> String).self`, or `(@concurrent () async -> String).self`. Getter symbol names do not establish these effects. See <doc:SwiftErrorABI>.

For a throwing getter in a generic type, also supply its source function type with `declaredAs:`. The getter symbol contains the property type but omits its formal error type. The concrete function metatype alone cannot distinguish `throws(B)` from a fixed error type that happens to equal the argument bound to `B`.

```swift
// For a provider declared as Getter<Value, Failure: Error>, with a property
// checked: Value { get throws(Failure) }, and arguments String/ProviderFailure:
let checked = try await type.getter(
    named: "checked",
    as: (() throws(ProviderFailure) -> String).self,
    declaredAs: "() throws(B) -> A"
)
let value = try unsafe checked.unsafeInvoke(on: receiver)
```

`A` and `B` follow the declaration's generic parameter order. A fixed error type uses its qualified name, such as `"() throws(Example.ProviderFailure) -> A"`. Include `async` when needed. Bound object getters and static getters accept the same source signature. Nonthrowing getters, including async getters, need only `as:`.

Concrete callback parameters and returned closures use the synchronous or async closure wrapper in the function-type metatype, as described in <doc:SwiftClosureValues>. Initializers transfer the encoded owned context; ordinary methods borrow it for the call.

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

Framework, executable-path, install-name, and retained-image overloads acquire explicit targets by default. Pass `loading: .loadedOnly` to retain inspection behavior; see <doc:ImageLoading>. The method or type handle keeps its implementation alive, and custom wrapper results retain their call's owners. Raw pointers remain borrowed.

The unsafe boundary requires the actual declaration's ownership, effects, and actor/thread requirements. Async function metatypes select NativeSwiftMethod or NativeSwiftFunction handles with an async Signature; see <doc:SwiftAsyncABI>. Generic metadata synthesis, nontrivial foreign value layouts, and resilient-layout inference remain adapter cases.

## Resolve members from private receivers

An existing object can supply the identity of a file-private Swift class without exposing its compiler-generated private discriminator. The object member APIs match its live nominal descriptor to symbols in its defining image. Methods, getters, setters, and inherited members use that declaration owner; two same-named private classes in different files remain distinct.

```swift
let method = try await runtime.object(receiver).method(
    named: "title()", as: (() -> String).self
)
let title = try unsafe method.unsafeInvoke()
```

The provider module need not be importable. Lookup still requires the relevant method symbols; this does not reconstruct stripped implementations. Short label-only names and complete relative declarations are both accepted. The ordinary receiver/image lifetime and caller-supplied ABI contract remain unchanged.
