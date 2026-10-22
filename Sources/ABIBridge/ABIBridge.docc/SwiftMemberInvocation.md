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

The prepared handle retains its type context and implementation images. Calls and new bindings use the implementation chosen during lookup, without selecting an override from the new receiver.

The receiver must match that context, including its generic specialization and extension constraints. Binding retains the supplied object; invocation then validates its representation and native type. An incompatible receiver reports an invocation error even when its representation is accepted as `AnyObject`.

`bind(to:)` retains a class object until the last bound copy is released. Each binding keeps the method's ownership, effects, and isolation contract. Value receivers use explicit invocation, including `inout` for mutating members.

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

Member lookup checks constrained extensions against the receiver or superclass specialization, including conformances, associated types, and same-type requirements. A cached result for one specialization does not apply to another. Multiple applicable short-name declarations report ambiguity; use a fully qualified constrained declaration to select one.

For parameters introduced by the method itself, supply `genericArguments:`. See <doc:GenericSwiftValues> for examples and binding rules.

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

Concrete members capture the selected implementation. Lookup prefers declarations in the type's defining image, then searches extension-qualified implementations in loaded images, and then walks superclass declarations in each superclass's defining image. These calls do not perform virtual redispatch. Existing receiver metadata also supplies the context for concrete members declared by a generic superclass.

## Call class members exported only through dispatch thunks

A library-evolution framework can export only the dispatch thunk and method descriptor of an open or nonfinal class member, without its implementation symbol. Method, getter, and setter lookup on a class then reads the member's code from the lookup type's class metadata entry:

```swift
let view = try ABIRuntime.shared.resolveSwiftTypeAndWait(named: "Example.CanvasView")
let setShowsGrid = try view.resolveSetterAndWait(named: "showsGrid", as: Bool.self)
try unsafe setShowsGrid.unsafeInvoke(on: canvas, true)
```

The handle's `symbol` is the dispatch thunk, its `declaration` is the member, and calls run the code stored in the entry, so they keep the no-redispatch contract above. Binding, opaque results, async calls, virtual hooks, and replacements use the member's declaration and declaring image. Such a member takes precedence over a same-signature member that another module's extension declares. An override declared without its own thunk is found through the introducing declaration, so a subclass override runs only when the subclass is the lookup type or the bound receiver's class. The entry is read during lookup, including a replacement or hook dispatcher installed there; later changes to the class metadata do not update an existing handle.

Relative names, complete declarations, `declaredAs:`, and `valueABIs:` use the same rules. Class methods, class getters, and class setters read their entry the same way and run with the lookup type's metatype as `self`, so `resolveStaticMethod` on a subclass runs that subclass's override. Lookup still reports `declarationNotFound` when neither the implementation nor a thunk exists.

## Call a protocol extension

For a renderer conforming to `Example.Renderable`, resolve the protocol extension's `summary()` using its complete source declaration:

```swift
let summary = try type.resolveMethodAndWait(
    named: "(extension in Example):Example.Renderable.summary() -> Swift.String",
    as: (() -> String).self
)
let text = try unsafe summary.unsafeInvoke(on: renderer)
```

Lookup binds `Self` to the whole concrete type represented by `type`, including a specialization such as `Renderer<String>`, and checks its protocol conformance and extension constraints. Supply `genericArguments:` only for type parameters introduced by the method.

Getters, setters, and static members use the same rule with their corresponding lookup factories. A protocol-qualified name without `(extension in Example):` selects the protocol's requirement when it declares one, and otherwise its extension member; the name can also be label-only, such as `Example.Renderable.summary()`.

## Call an instance protocol requirement

Use the complete protocol declaration with `resolveMethod` to call an instance method requirement. For a concrete `builder` conforming to `Example.Builder`, whose `Request` associated type has an `Output` associated type:

```swift
let build = try await builder.type.resolveMethod(
    named: "Example.Builder.build(_: A.Request, in: A.Context, using: Example.Service) -> Example.Reply<A.Request.Output>",
    as: ((NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self
)
let reply = try unsafe build.unsafeInvoke(on: builder, request, context, service)
```

Here `builder`, `request`, `context`, and `service` are owned runtime values. `Service` and `Reply<Output>` are native classes, and `build` is synchronous. Awaiting lookup prepares the call; invoking it returns the native reply. Any later async operation on the reply has its own signature.

Lookup binds `Self` to the builder's concrete type and resolves `Request`, `Context`, and `Request.Output` through its native conformances. Supply `genericArguments:` only for type parameters introduced by the method. `resolveMethodAndWait` performs the same lookup synchronously.

For an owned `NativeSwiftValue` named `receiver` whose concrete type conforms to `Example.Provider`, use the complete protocol getter declaration:

```swift
let payloadType = try runtime.resolveSwiftTypeAndWait(named: "Example.Payload")
let getter = try receiver.type.resolveGetterAndWait(
    named: "Example.Provider.payload.getter : Example.Payload",
    as: (() -> NativeSwiftValue).self,
    valueABIs: [payloadType: try .opaque(named: payloadType.name)]
)
let payload = try unsafe getter.unsafeInvoke(on: receiver)
```

This example assumes the native synchronous getter returns a resilient `Payload` through indirect result storage. The returned value owns its contents; see <doc:SwiftOpaqueResults> for runtime values and formal value ABIs.

Method and getter lookup resolve the protocol's dispatch thunk in loaded images. They check the native conformance before invocation and retain the protocol and conformance implementation images. The native thunk selects the implementation from that conformance. A non-class-bound protocol keeps its formally indirect `Self` convention even when the concrete receiver is a class.

## Await type and member preparation

All type and member factories offer async `resolve…` and synchronous `resolve…AndWait` forms with the same arguments. Async lookup moves search, metadata, and call preparation to a worker queue while the caller suspends. `AndWait` runs on the caller's thread or blocks while joining required work already running. Both reuse indexes and call layouts. `ABIRuntime` and `NativeSwiftType` are actors.

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

The example awaits preparation and invokes a synchronous getter on `MainActor`. Lookup does not invoke the native body. An async native member also needs an async function metatype and `await` for `unsafeInvoke`; see <doc:SwiftAsyncABI>.

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

Use `AndWait` to select synchronous lookup in either a synchronous or async function. For preparing raw symbol lookup and the synchronous C/C++ and Objective-C APIs, see <doc:SymbolLookup>.

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

Static methods and setters follow the same factory naming. Invoke their prepared handles on the declaration's required actor or thread.

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

Use ``NativeSwiftClosure`` for callback parameters and returned closures. Initializers transfer their owned context; ordinary methods borrow it. See <doc:SwiftClosureValues>.

## Subscript accessors

Use `resolveMethod` with the complete subscript getter or setter declaration. For `subscript(_ key: Element.ID) -> Element?` in a provider's `Lookup<Element: Identifiable>`, the getter takes one index and returns an optional element. The setter takes the new value first, followed by the indices.

This example uses owned runtime values: `lookup` contains `Lookup<Element>`, `key` contains `Element.ID`, and `replacement` contains `Optional<Element>`. The provider's receiver, index, and result use indirect storage:

```swift
let valueABIs = [
    key.type: try NativeType.opaque(named: key.type.name),
    replacement.type: try NativeType.opaque(named: replacement.type.name),
]
let get = try await lookup.type.resolveMethod(
    named: "Example.Lookup.subscript.getter : (A.ID) -> A?",
    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
    valueABIs: valueABIs,
    receiverABI: .opaque(named: lookup.type.name)
)
let set = try await lookup.type.resolveMethod(
    named: "Example.Lookup.subscript.setter : (A.ID) -> A?",
    as: ((NativeSwiftValue, NativeSwiftValue) -> Void).self,
    valueABIs: valueABIs,
    receiverABI: .opaque(named: lookup.type.name),
    mutating: true
)
let setterKey = try key.copy()
try unsafe set.unsafeInvoke(on: lookup, replacement, setterKey)
let updated = try unsafe get.unsafeInvoke(on: lookup, key)
```

The setter consumes `replacement` and `setterKey`; the original `key` remains usable for the getter. Typed setter arguments transfer independent copies. Use `mutating: true` for a mutating value setter, and pass a typed receiver with `inout` or an owned `NativeSwiftValue` whose storage can be updated.

`resolveMethodAndWait` performs the same lookup synchronously. Property getters, including properties returning closures, keep their zero-argument `resolveGetter` signature.

## Writable key paths

Resolve a computed property's native `WritableKeyPath` when its root or value type is unavailable at compile time:

```swift
let settings = try await runtime.resolveSwiftType(named: "Example.Settings")
let theme = try await runtime.resolveSwiftType(named: "Example.Theme")
let themePath = try await settings.resolveWritableKeyPath(
    named: "theme", valueType: theme
)
```

The result is a ``NativeSwiftValue`` containing the actual `WritableKeyPath<Settings, Theme>`, or its `ReferenceWritableKeyPath` subclass for a nonmutating setter. Its property identity, equality, and hashing match a compiler-generated key path for that property. You can pass the owned value to a compatible native call, inspect an `AnyKeyPath` copy with `withCopy`, or use `take(as:)` with the exact key-path type when both types are importable. Copies retain the property's implementation images through the value handle's lifetime; keep the handle or its type alive if an extracted key path outlives the extraction scope.

For a property defined in another module, supply its complete extension-qualified name:

```swift
let themePath = try await settings.resolveWritableKeyPath(
    named: "(extension in Themes):Example.Settings.theme", valueType: theme
)
```

The extension module must already be loaded. `resolveWritableKeyPathAndWait` performs the same operation synchronously. Async lookup prepares the descriptor on a worker and creates the owned value in the caller's isolation domain. Neither form reads or changes a root value.

Applying an extracted key path invokes the native accessors synchronously. Apply it only on the actor or thread required by the property; the key path does not perform an actor hop.

For KVC/KVO APIs such as `NSObject.observe`, supply the property's actual Objective-C key. For example, a property declared as `@objc(displayTitle) var title: String` uses `displayTitle`:

```swift
let rendererType = try await runtime.resolveSwiftType(named: "Example.Renderer")
let stringType = try await runtime.resolveSwiftType(named: "Swift.String")
let titlePath = try await rendererType.resolveWritableKeyPath(
    named: "title", valueType: stringType, keyValueCodingKey: "displayTitle"
)
```

The key-path object retains its KVC string after extraction or copying. The provider's declaration must establish that the supplied key refers to the same property; lookup cannot validate that correspondence. The root and property must meet the KVC/KVO API's usual requirements. Omitting `keyValueCodingKey` leaves the KVC compatibility string absent, while preserving Swift access, equality, and hashing.

This operation requires a non-generic root and a nontrivial property descriptor containing writable computed-property accessors without captured arguments. A missing descriptor, a mismatched root or value type, a getter-only property, or a descriptor that requires additional generic context fails with a resolution error. Trivial descriptors omit the accessors needed for construction and are unsupported.

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

Use `as:` for an unimportable struct or enum with an established representation. The adapter must match its actual layout and calling convention. When ABIBridge can establish the native type's convention, from a conformance or its metadata, member lookup rejects a representation that passes differently with ``ABIResolutionError/signatureMismatch(_:)`` at ``ABIResolutionError/SignatureMismatch/Position/receiver``. Otherwise the representation states that convention, because `receiverABI:` describes native `self` values rather than an adapter. A member that takes a protocol's `Self` by address, such as a protocol extension method, receives the address of the representation's storage, which must be at least as large and aligned as the native value. Supported representations are listed in <doc:SwiftFunctionInvocation>.

Small nonmutating value receivers use ordinary trailing components. Indirect and mutating value receivers use the Swift context register. Specify mutating: true for mutating value methods/getters, and use an inout receiver. Value setters default to mutating unless consuming is true; an explicitly nonmutating setter can opt out with mutating: false.

For a `consuming` method, getter, or setter, pass `consuming: true` during lookup, including bound-object lookup. A typed receiver transfers an independent copy, leaving the caller's value usable. Consuming and mutating conventions are mutually exclusive, and symbol names do not distinguish them. A foreign value adapter must describe a trivial native value; nontrivial destruction requires a native adapter. Runtime owners follow the transfer contract in <doc:SwiftOpaqueResults>.

Writeback preserves the originating resource storage and implementation images without retaining a chain of intermediate value copies. After a native mutation, receiver writeback is attempted even if result conversion fails. If both conversions fail, NativeSwiftWritebackError preserves both errors. A writeback failure leaves the caller's receiver value unchanged, while other native side effects may already have occurred.

## Names, scopes, and limits

A label-only method name, such as `transform(_:)`, or a property name, such as `payload`, selects the declaration whose native parameter and result types accept the function metatype, including the class conversions described in <doc:SwiftFunctionInvocation>. Use a complete relative declaration when a wrapper has a different native name, such as `transform(Example.NativeValue) -> Example.NativeValue`; an accessor similarly uses `property.getter : Example.NativeValue` or `property.setter : Example.NativeValue`. Lookup then checks that each wrapper passes as the native type does, as described in <doc:SwiftFunctionInvocation#Use-a-wrapper-with-a-complete-declaration>. A complete declaration need not name the module of the extension that declares it. Operator names can omit fixity, such as `>(_:_:)`. If prefix and postfix implementations both match, lookup reports ambiguity; use `~~~ prefix(_:)` or a complete declaration to choose one.

Framework, executable-path, install-name, and retained-image overloads acquire explicit targets by default. Pass `loading: .loadedOnly` to retain inspection behavior; see <doc:ImageLoading>. The method or type handle keeps its implementation alive, and custom wrapper results retain their call's owners. Raw pointers remain borrowed.

The unsafe boundary requires the declaration's actual ownership, effects, and actor/thread contract. Generic metadata does not establish an unknown value's direct call layout; see <doc:ExplicitSwiftValues> and <doc:ManagedSwiftValues>.

## Resolve members from private receivers

An existing object can supply the identity of a file-private Swift class without exposing its compiler-generated private discriminator. The object member APIs match its live nominal descriptor to symbols in its defining image. Methods, getters, setters, and inherited members use that declaration owner; two same-named private classes in different files remain distinct.

```swift
let method = try runtime.object(receiver).resolveMethodAndWait(
    named: "title()", as: (() -> String).self
)
let title = try unsafe method.unsafeInvoke()
```

The provider module need not be importable. Lookup still requires the relevant method symbols; this does not reconstruct stripped implementations. Short label-only names and complete relative declarations are both accepted. The ordinary receiver/image lifetime and caller-supplied ABI contract remain unchanged.
