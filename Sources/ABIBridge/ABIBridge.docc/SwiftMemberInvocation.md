# Calling Swift members

Reuse a concrete type's metadata and symbol index for methods, initializers, and properties.

## Bind an existing object

For a renderer exposing a synchronous Swift method:

```swift
let object = ABIRuntime.shared.object(renderer)
let setImage = try object.resolveMethodAndWait(
    named: "setImage(_:animated:)",
    as: ((UIImage?, Bool) -> Void).self
)
try unsafe setImage.unsafeInvoke(image, true)
```

The handle retains its receiver and implementation images. Existing objects supply their runtime class metadata, including imported Objective-C classes with Swift extension methods. Bound handles stay in the caller's isolation domain.

Swift `resolveMethod`, `resolveGetter`, and `resolveSetter` provide async bound lookup. Their `AndWait` variants perform synchronous lookup. Awaiting a bound factory moves search and call-interface preparation to a worker queue while retaining and binding the receiver in the caller's isolation domain:

```swift
@MainActor
func update(_ renderer: AnyObject, image: UIImage) async throws {
    let object = ABIRuntime.shared.object(renderer)
    let setImage = try await object.resolveMethod(
        named: "setImage(_:animated:)",
        as: ((UIImage?, Bool) -> Void).self
    )
    try unsafe setImage.unsafeInvoke(image, true)
}
```

The native method remains synchronous here and executes on `MainActor`. Lookup does not invoke the native method or make its receiver Sendable.

## Reuse a discovered implementation with another object

A bound method's `method` property returns its prepared explicit-receiver handle. Keeping that value does not keep the original receiver binding alive. This also works for getters, setters, and async members.

```swift
let bound = try runtime.object(firstRenderer).resolveMethodAndWait(
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

An existing object such as `Renderer<Content>` uses the same `NativeObject.resolveMethod`, `resolveGetter`, and `resolveSetter` factories, or their `AndWait` variants, for concrete and dependent parameter/result types. Lookup identifies the unspecialized declaration through the live class's nominal descriptor and binds its enclosing parameters from the instantiated metadata. Private declaration owners and inherited members follow the same lookup rules.

For example, given an existing `Renderer<Content>` with `func title() -> String`:

```swift
let title = try runtime.object(renderer).resolveMethodAndWait(
    named: "title()", as: (() -> String).self
)
let text = try unsafe title.unsafeInvoke()
```

A member returning `Content` has a dependent formal result, which can remain indirect even when the actual value fits registers. The prepared call preserves that formal convention and uses the enclosing specialization to validate the concrete signature. For a `Renderer<String>` returning `Content`, use `as: (() -> String).self`.

Member lookup checks constrained extensions against the current receiver or superclass specialization, including protocol conformances, associated types, and same-type requirements. A cached result for one specialization does not apply to another. Multiple applicable short-name declarations remain ambiguous; a fully qualified constrained declaration selects that implementation explicitly. Methods introducing additional parameters accept `genericArguments:` for those parameters and supply the required metadata and witnesses. See <doc:GenericSwiftValues> for examples. Receiver ownership, effects, actor isolation, and captured implementation dispatch retain their ordinary contracts.

An absent declaration or specialization with no applicable candidate reports `ABIResolutionError.declarationNotFound`. A selected declaration whose requirements or representation cannot be established reports a preparation error before invocation.

## Reuse a type

```swift
let type = try ABIRuntime.shared.resolveSwiftTypeAndWait(named: "Example.Renderer")
let start = try type.resolveMethodAndWait(named: "start()", as: (() -> Void).self)
let stop = try type.resolveMethodAndWait(named: "stop()", as: (() -> Void).self)
try unsafe start.unsafeInvoke(on: renderer)
try unsafe stop.unsafeInvoke(on: renderer)
```

Type lookup obtains the nominal descriptor and requests complete metadata. For a generic type, supply `genericArguments: [.type(String.self)]`, or the corresponding arguments and packs in outer-to-inner declaration order. Type handles share the runtime's symbol indexes, retain their defining image and argument owners, and remain valid after removeCachedResults().

Methods capture the selected implementation. Lookup prefers declarations in the type's defining image, then searches extension-qualified implementations in loaded images, and then walks superclass declarations in each superclass's defining image. Calls do not perform virtual redispatch. Existing receiver metadata also supplies the context for concrete members declared by a generic superclass.

## Await type and member preparation

Swift function, type, and member lookup uses async factories whose names begin with `resolve`. Their synchronous counterparts append `AndWait` and accept the same arguments. On `NativeSwiftType`, the async factories are `resolveMethod`, `resolveStaticMethod`, `resolveInitializer`, `resolveGetter`, `resolveSetter`, `resolveStaticGetter`, and `resolveStaticSetter`. `ABIRuntime` and `NativeSwiftType` remain actors. Async lookup performs search, metadata preparation, and call-interface preparation on a worker queue while the caller suspends. `AndWait` prepares on the caller's thread or blocks while joining required work already running. Both forms share indexes and call layouts, and neither waits for an entire preparation closure or batch.

Use async resolution on `MainActor` without an earlier `prepare` call:

```swift
@MainActor
func readText(
    from renderer: AnyObject, using runtime: ABIRuntime = .shared
) async throws -> String {
    let type = try await runtime.resolveSwiftType(named: "Example.Renderer")
    let getText = try await type.resolveGetter(named: "text", as: (() -> String).self)
    return try unsafe getText.unsafeInvoke(on: renderer)
}
```

Lookup and native invocation have separate effects. The example awaits preparation but invokes a synchronous getter. An async native function, method, initializer, or getter uses an async function metatype and also requires `await` for `unsafeInvoke`; see <doc:SwiftAsyncABI>. Preparing the handle does not invoke the native body.

Optional `prepare(_:)` can start the same work ahead of lookup. Keep the receiver outside its Sendable worker closure:

```swift
@MainActor
func readTextWithPreparation(from renderer: AnyObject) async throws -> String {
    let runtime = ABIRuntime.shared
    async let preparation = runtime.prepare { runtime in
        let type = try runtime.resolveSwiftTypeAndWait(named: "Example.Renderer")
        return try type.resolveGetterAndWait(named: "text", as: (() -> String).self)
    }

    let text = try await readText(from: renderer, using: runtime)
    _ = try await preparation
    return text
}
```

If preparation is still running, `readText` suspends until the work needed for its type and getter is ready. It does not wait for the entire preparation closure before lookup. The final `await preparation` observes that closure's result after reading the property.

The factory name selects the lookup behavior independently of the calling context. Use `AndWait` for synchronous lookup in either a synchronous or async function:

```swift
let getText = try type.resolveGetterAndWait(named: "text", as: (() -> String).self)
```

`AndWait` can block the caller during cold lookup or while joining preparation. Objective-C selector lookup, C/C++ factories, and raw symbol resolution use their synchronous APIs. Use <doc:SymbolLookup> for preparing those operations on a worker ahead of time.

## Initializers and static members

```swift
let initialize = try type.resolveInitializerAndWait(
    named: "init(text:)",
    as: ((String) -> AnyObject).self
)
let renderer = try unsafe initialize.unsafeInvoke("Hello")

let standard = try type.resolveStaticGetterAndWait(named: "standard", as: (() -> String).self)
let value = try unsafe standard.unsafeInvoke()
```

Allocating class initializers and static members receive the type metadata automatically. Initializers transfer ordinary arguments to the callee. Use NativeSwiftBorrowing for explicitly borrowed initializer arguments (`__shared` in the demangled declaration); see <doc:SwiftArgumentConventions>. A failable class initializer can use an optional class result. Initializers are resolved on the requested type; inherited allocation behavior must have its own compiler-generated initializer entry.

Opaque some results use NativeSwiftValue for functions, methods, and getters; see <doc:SwiftOpaqueResults>.

The initializer and static-member factories follow the same async lookup contract. For a renderer with `init(text:)` and a static `standard: String` property:

```swift
@MainActor
func makeRenderer() async throws -> AnyObject {
    let type = try await ABIRuntime.shared.resolveSwiftType(named: "Example.Renderer")
    let initialize = try await type.resolveInitializer(
        named: "init(text:)", as: ((String) -> AnyObject).self
    )
    let standard = try await type.resolveStaticGetter(named: "standard", as: (() -> String).self)
    let text = try unsafe standard.unsafeInvoke()
    return try unsafe initialize.unsafeInvoke(text)
}
```

Use `resolveStaticMethod` and `resolveStaticSetter` for async lookup, or their `AndWait` variants for synchronous lookup. These factories prepare a handle; calling the native static method or writing its property still requires a separate `unsafeInvoke` on the declaration's required actor or thread.

## Property accessors

```swift
let getText = try type.resolveGetterAndWait(named: "text", as: (() -> String).self)
let setText = try type.resolveSetterAndWait(named: "text", as: String.self)
try unsafe setText.unsafeInvoke(on: renderer, "Updated")
let text = try unsafe getText.unsafeInvoke(on: renderer)
```

An object scope also provides `resolveGetter` and `resolveSetter`, with `AndWait` variants, returning bound handles. Static properties use `resolveStaticGetter` and `resolveStaticSetter`, with the same choice of lookup behavior. Accessors use the same unsafeInvoke spelling as other native calls.

Await setter lookup to prepare it without blocking `MainActor`, then perform the native mutation on that actor:

```swift
@MainActor
func updateText(of renderer: AnyObject, to text: String) async throws {
    let setText = try await ABIRuntime.shared.object(renderer).resolveSetter(
        named: "text", as: String.self
    )
    try unsafe setText.unsafeInvoke(text)
}
```

The receiver and returned bound handle stay in the caller's isolation domain. Lookup never invokes the setter, and obtaining a bound handle does not make the receiver Sendable.

Setters transfer ownership of the incoming value. Getters use a zero-argument function metatype, such as `(() -> String).self`, `(() throws -> String).self`, or `(@concurrent () async -> String).self`. Getter symbol names do not establish these effects. See <doc:SwiftErrorABI>.

For a throwing getter in a generic type, also supply its source function type with `declaredAs:`. The getter symbol contains the property type but omits its formal error type. The concrete function metatype alone cannot distinguish `throws(B)` from a fixed error type that happens to equal the argument bound to `B`.

```swift
// For a provider declared as Getter<Value, Failure: Error>, with a property
// checked: Value { get throws(Failure) }, and arguments String/ProviderFailure:
let checked = try type.resolveGetterAndWait(
    named: "checked",
    as: (() throws(ProviderFailure) -> String).self,
    declaredAs: "() throws(B) -> A"
)
let value = try unsafe checked.unsafeInvoke(on: receiver)
```

`declaredAs:` is also available on methods, initializers, and setters. A complete canonical `<...>` prefix supplies generic ABI requirements when the provider's import environment is needed to determine them; see <doc:GenericSwiftValues>.

`A` and `B` follow the declaration's generic parameter order. A fixed error type uses its qualified name, such as `"() throws(Example.ProviderFailure) -> A"`. Include `async` when needed. Bound object getters and static getters accept the same source signature. A getter declared with `throws(B)` still needs `declaredAs:` when `B` is bound to `Never`, even though its concrete `as:` signature is nonthrowing. Getters declared without native errors, including async getters, need only `as:`.

Concrete callback parameters and returned closures use the synchronous or async closure wrapper in the function-type metatype, as described in <doc:SwiftClosureValues>. Initializers transfer the encoded owned context; ordinary methods borrow it for the call.

## Fixed value receivers and adapters

For a supported fixed-layout value or a value conforming to ABIBridgeValue:

```swift
let pointType = try runtime.resolveSwiftTypeAndWait(
    named: "Example.Point", as: Point.self
)
let translate = try pointType.resolveMethodAndWait(
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

The unsafe boundary requires the actual declaration's ownership, effects, and actor/thread requirements. Async function metatypes select NativeSwiftMethod or NativeSwiftFunction handles with an async Signature; see <doc:SwiftAsyncABI>. Constructing generic metadata does not establish an unknown foreign value's direct call layout; see <doc:ExplicitSwiftValues> and <doc:ManagedSwiftValues> for value representations.

## Resolve members from private receivers

An existing object can supply the identity of a file-private Swift class without exposing its compiler-generated private discriminator. The object member APIs match its live nominal descriptor to symbols in its defining image. Methods, getters, setters, and inherited members use that declaration owner; two same-named private classes in different files remain distinct.

```swift
let method = try runtime.object(receiver).resolveMethodAndWait(
    named: "title()", as: (() -> String).self
)
let title = try unsafe method.unsafeInvoke()
```

The provider module need not be importable. Lookup still requires the relevant method symbols; this does not reconstruct stripped implementations. Short label-only names and complete relative declarations are both accepted. The ordinary receiver/image lifetime and caller-supplied ABI contract remain unchanged.
