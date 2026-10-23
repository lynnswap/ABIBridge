# Calling Swift members

Reuse a concrete type's metadata and symbol index for methods, initializers, and properties.

## Bind an existing object

For a renderer exposing a synchronous Swift method:

```swift
let object = ABIRuntime.shared.object(renderer)
let setImage = try object.resolveAndWait(.method(
    "setImage(_:animated:)",
    as: ((UIImage?, Bool) -> Void).self
))
try unsafe setImage.unsafeInvoke(image, true)
```

The handle retains its receiver and implementation images. Existing objects supply their runtime class metadata, including imported Objective-C classes with Swift extension methods. Bound handles stay in the caller's isolation domain.

An object resolves the same member requests as its type, with the same options, and returns handles bound to it. `resolveAndWait` looks up synchronously. Awaiting `resolve` moves search and call-interface preparation to a worker queue while retaining and binding the receiver in the caller's isolation domain:

```swift
@MainActor
func update(_ renderer: AnyObject, image: UIImage) async throws {
    let object = ABIRuntime.shared.object(renderer)
    let setImage = try await object.resolve(.method(
        "setImage(_:animated:)",
        as: ((UIImage?, Bool) -> Void).self
    ))
    try unsafe setImage.unsafeInvoke(image, true)
}
```

The native method remains synchronous here and executes on `MainActor`. Lookup does not invoke the native method or make its receiver Sendable.

## Reuse a discovered implementation with another object

A bound method's `method` property returns its prepared explicit-receiver handle. Keeping that value does not keep the original receiver binding alive. This also works for getters, setters, and async members.

```swift
let bound = try runtime.object(firstRenderer).resolveAndWait(.method(
    "start()", as: (() -> Void).self
))
let start = bound.method
try unsafe start.unsafeInvoke(on: secondRenderer)
let secondBound = try start.bind(to: secondRenderer)
try unsafe secondBound.unsafeInvoke()
```

The prepared handle retains its type context and implementation images. Calls and new bindings use the implementation chosen during lookup, without selecting an override from the new receiver.

The receiver must match that context, including its generic specialization and extension constraints. Binding retains the supplied object; invocation then validates its representation and native type. An incompatible receiver reports an invocation error even when its representation is accepted as `AnyObject`.

`bind(to:)` retains a class object until the last bound copy is released. Each binding keeps the method's ownership, effects, and isolation contract. Value receivers use explicit invocation, including `inout` for mutating members.

## Use an instantiated generic receiver

An existing object such as `Renderer<Content>` resolves the same method, getter, and setter requests for concrete and dependent parameter and result types. Lookup identifies the unspecialized declaration through the live class's nominal descriptor and binds its enclosing parameters from the instantiated metadata. Private declaration owners and inherited members follow the same lookup rules.

For example, given an existing `Renderer<Content>` with `func title() -> String`:

```swift
let title = try runtime.object(renderer).resolveAndWait(.method(
    "title()", as: (() -> String).self
))
let text = try unsafe title.unsafeInvoke()
```

A member returning `Content` has a dependent formal result, which can remain indirect even when the actual value fits registers. The prepared call preserves that formal convention and uses the enclosing specialization to validate the concrete signature. For a `Renderer<String>` returning `Content`, use `as: (() -> String).self`.

Member lookup checks constrained extensions against the receiver or superclass specialization, including conformances, associated types, and same-type requirements. A cached result for one specialization does not apply to another. Multiple applicable short-name declarations report ambiguity; use a fully qualified constrained declaration to select one.

For parameters introduced by the method itself, supply `genericArguments:`. See <doc:GenericSwiftValues> for examples and binding rules.

An absent declaration or specialization with no applicable candidate reports `ABIResolutionError.declarationNotFound`. A selected declaration whose requirements or representation cannot be established reports a preparation error before invocation.

## Reuse a type

```swift
let type = try ABIRuntime.shared.resolveSwiftTypeAndWait(named: "Example.Renderer")
let start = try type.resolveAndWait(.method("start()", as: (() -> Void).self))
let stop = try type.resolveAndWait(.method("stop()", as: (() -> Void).self))
try unsafe start.unsafeInvoke(on: renderer)
try unsafe stop.unsafeInvoke(on: renderer)
```

Type lookup obtains the nominal descriptor and requests complete metadata. For a generic type, supply `genericArguments: [.type(String.self)]`, or the corresponding arguments and packs in outer-to-inner declaration order. Type handles share the runtime's symbol indexes, retain their defining image and argument owners, and remain valid after removeCachedResults().

Concrete members capture the selected implementation. Lookup prefers declarations in the type's defining image, then searches extension-qualified implementations in loaded images, and then walks superclass declarations in each superclass's defining image. These calls do not perform virtual redispatch. Existing receiver metadata also supplies the context for concrete members declared by a generic superclass.

## Call class members exported only through dispatch thunks

A library-evolution framework can export only the dispatch thunk and method descriptor of an open or nonfinal class member, without its implementation symbol. Method, getter, and setter lookup on a class then reads the member's code from the lookup type's class metadata entry:

```swift
let view = try ABIRuntime.shared.resolveSwiftTypeAndWait(named: "Example.CanvasView")
let setShowsGrid = try view.resolveAndWait(.setter("showsGrid", as: ((Bool) -> Void).self))
try unsafe setShowsGrid.unsafeInvoke(on: canvas, true)
```

The handle's `symbol` is the dispatch thunk, its `declaration` is the member, and calls run the code stored in the entry, so they keep the no-redispatch contract above. Binding, opaque results, async calls, virtual hooks, and replacements use the member's declaration and declaring image. Such a member takes precedence over a same-signature member that another module's extension declares. An override declared without its own thunk is found through the introducing declaration, so a subclass override runs only when the subclass is the lookup type or the bound receiver's class. The entry is read during lookup, including a replacement or hook dispatcher installed there; later changes to the class metadata do not update an existing handle.

Relative names, complete declarations, `declaredAs:`, and `valueABIs:` use the same rules. Class methods, class getters, and class setters read their entry the same way and run with the lookup type's metatype as `self`, so a `staticMethod` request resolved on a subclass runs that subclass's override. Lookup still reports `declarationNotFound` when neither the implementation nor a thunk exists.

## Call a protocol extension

For a renderer conforming to `Example.Renderable`, resolve the protocol extension's `summary()` using its complete source declaration:

```swift
let summary = try type.resolveAndWait(.method(
    "(extension in Example):Example.Renderable.summary() -> Swift.String",
    as: (() -> String).self
))
let text = try unsafe summary.unsafeInvoke(on: renderer)
```

Lookup binds `Self` to the whole concrete type represented by `type`, including a specialization such as `Renderer<String>`, and checks its protocol conformance and extension constraints. Supply `genericArguments:` only for type parameters introduced by the method.

Getter, setter, and static member requests use the same rule. A protocol-qualified name without `(extension in Example):` selects the protocol's requirement when it declares one, and otherwise its extension member; the name can also be label-only, such as `Example.Renderable.summary()`. An extension member never stands in for a requirement, as described in the next section.

## Call a protocol requirement

A name qualified by the protocol, label-only or complete, selects a requirement of any kind: methods, getters and setters, subscript accessors, static members, and initializers. Use the request for the member's kind:

```swift
let type = try runtime.resolveSwiftTypeAndWait(named: "Example.Tile")
let make = try type.resolveAndWait(.initializer(
    "Example.Shape.init(size:)", as: ((Int64) -> AnyObject).self
))
let unit = try type.resolveAndWait(.staticMethod(
    "Example.Shape.unit()", as: (() -> AnyObject).self
))
let cell = try type.resolveAndWait(.getter(
    "Example.Shape.subscript.getter : (Swift.Int64) -> Swift.Int64",
    as: ((Int64) -> Int64).self
))
let tile = try unsafe make.unsafeInvoke(4)
let value = try unsafe cell.unsafeInvoke(on: tile, 2)
```

Here `Example.Tile` is a class conforming to `Example.Shape`. A requirement returning `Self` returns it indirectly, so a value conformer can use `NativeSwiftValue` for the result. Static requirements and initializers receive the type's metatype as `self`.

Lookup binds `Self` to the concrete type and requires its native conformance. A library-evolution module exports each requirement's dispatch thunk, which selects the witness of the conformance that a call passes. A module built without library evolution exports no thunks; lookup then runs the witness of the type's conformance, which the Swift runtime finds for the type, including a conformance inherited from a superclass. Each witness is a local symbol of the conformance's image, which stripping removes. When other conformances' witnesses show that the protocol declares the requested requirement but neither its thunk nor this type's witness is available, lookup throws ``ABIResolutionError/metadataUnavailable(_:)`` instead of selecting an extension member with the same name.

Before an extension member stands in for a protocol-qualified name, lookup establishes that no requirement of the protocol is the requested member. The name refers to the protocol's own members; a requirement that the protocol inherits from another protocol has that protocol's name.

- A Swift protocol's descriptor records each requirement's kind and effects but not its name, so only requirements of the member's own kind, static or not and async or not, can be the member. A method descriptor, which library evolution exports, names such a requirement, and so does the witness that a conformance's witness table holds for it. When a requirement that the member could be has no name in the loaded images, as in a module built without library evolution whose images are stripped, lookup throws ``ABIResolutionError/metadataUnavailable(_:)``.
- An Objective-C protocol, imported or declared `@objc`, is not checked: the Objective-C runtime names its requirements only by selectors, which do not establish their Swift names. A protocol-qualified name selects the protocol's Swift extension member.

Name the extension member with its complete `(extension in Module):` declaration to select it without this check.

A requirement can also depend on associated types. For a concrete `builder` conforming to `Example.Builder`, whose `Request` associated type has an `Output` associated type:

```swift
let build = try await builder.type.resolve(.method(
    "Example.Builder.build(_: A.Request, in: A.Context, using: Example.Service) -> Example.Reply<A.Request.Output>",
    as: ((NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self
))
let reply = try unsafe build.unsafeInvoke(on: builder, request, context, service)
```

Here `builder`, `request`, `context`, and `service` are owned runtime values. `Service` and `Reply<Output>` are native classes, and `build` is synchronous. Awaiting lookup prepares the call; invoking it returns the native reply. Any later async operation on the reply has its own signature.

Lookup binds `Self` to the builder's concrete type and resolves `Request`, `Context`, and `Request.Output` through its native conformances. Supply `genericArguments:` only for type parameters introduced by the method. `resolveAndWait` performs the same lookup synchronously.

For an owned `NativeSwiftValue` named `receiver` whose concrete type conforms to `Example.Provider`, use the complete protocol getter declaration:

```swift
let payloadType = try runtime.resolveSwiftTypeAndWait(named: "Example.Payload")
let getter = try receiver.type.resolveAndWait(.getter(
    "Example.Provider.payload.getter : Example.Payload",
    as: (() -> NativeSwiftValue).self,
    valueABIs: [payloadType: try .opaque(named: payloadType.name)]
))
let payload = try unsafe getter.unsafeInvoke(on: receiver)
```

This example assumes the native synchronous getter returns a resilient `Payload` through indirect result storage. The returned value owns its contents; see <doc:SwiftOpaqueResults> for runtime values and formal value ABIs.

Lookup checks the native conformance before invocation and retains the protocol and conformance implementation images. A non-class-bound protocol keeps its formally indirect `Self` convention even when the concrete receiver is a class.

## Await type and member preparation

Types and objects resolve member requests with async `resolve` and synchronous `resolveAndWait`, and `ABIRuntime` resolves type lookups with `resolveSwiftType` and `resolveSwiftTypeAndWait`. Async lookup moves search, metadata, and call preparation to a worker queue while the caller suspends. `AndWait` runs on the caller's thread or blocks while joining required work already running. Both reuse indexes and call layouts. `ABIRuntime` and `NativeSwiftType` are actors.

Use async resolution on `MainActor` without an earlier `prepare` call:

```swift
@MainActor
func readText(
    from renderer: AnyObject, using runtime: ABIRuntime = .shared
) async throws -> String {
    let type = try await runtime.resolveSwiftType(named: "Example.Renderer")
    let getText = try await type.resolve(.getter("text", as: (() -> String).self))
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
        return try type.resolveAndWait(.getter("text", as: (() -> String).self))
    }

    let text = try await readText(from: renderer, using: runtime)
    _ = try await preparation
    return text
}
```

If preparation is still running, `readText` suspends until the work needed for its type and getter is ready. It does not wait for the entire preparation closure before lookup. The final `await preparation` observes that closure's result after reading the property.

Use `resolveAndWait` to select synchronous lookup in either a synchronous or async function. For preparing raw symbol lookup and the synchronous C/C++ and Objective-C APIs, see <doc:SymbolLookup>.

## Initializers and static members

```swift
let initialize = try type.resolveAndWait(.initializer(
    "init(text:)",
    as: ((String) -> AnyObject).self
))
let renderer = try unsafe initialize.unsafeInvoke("Hello")

let standard = try type.resolveAndWait(.staticGetter("standard", as: (() -> String).self))
let value = try unsafe standard.unsafeInvoke()
```

Allocating class initializers and static members receive the type metadata automatically. Initializers transfer ordinary arguments to the callee. Use NativeSwiftBorrowing for explicitly borrowed initializer arguments (`__shared` in the demangled declaration); see <doc:SwiftArgumentConventions>. A failable class initializer can use an optional class result. Initializers are resolved on the requested type; inherited allocation behavior must have its own compiler-generated initializer entry.

Opaque some results use NativeSwiftValue for functions, methods, and getters; see <doc:SwiftOpaqueResults>.

Initializer and static member requests follow the same async lookup contract. For a renderer with `init(text:)` and a static `standard: String` property:

```swift
@MainActor
func makeRenderer() async throws -> AnyObject {
    let type = try await ABIRuntime.shared.resolveSwiftType(named: "Example.Renderer")
    let initialize = try await type.resolve(.initializer(
        "init(text:)", as: ((String) -> AnyObject).self
    ))
    let standard = try await type.resolve(.staticGetter("standard", as: (() -> String).self))
    let text = try unsafe standard.unsafeInvoke()
    return try unsafe initialize.unsafeInvoke(text)
}
```

Static methods and setters use `staticMethod` and `staticSetter` requests. An object resolves the same requests for its own type. Invoke their prepared handles on the declaration's required actor or thread.

## Property accessors

```swift
let getText = try type.resolveAndWait(.getter("text", as: (() -> String).self))
let setText = try type.resolveAndWait(.setter("text", as: ((String) -> Void).self))
try unsafe setText.unsafeInvoke(on: renderer, "Updated")
let text = try unsafe getText.unsafeInvoke(on: renderer)
```

An object resolves the same getter and setter requests and returns bound handles. Static properties use `staticGetter` and `staticSetter` requests. A setter's signature is its complete function type, such as `(String) -> Void`. Accessors use the same unsafeInvoke spelling as other native calls.

Await setter lookup to prepare it without blocking `MainActor`, then perform the native mutation on that actor:

```swift
@MainActor
func updateText(of renderer: AnyObject, to text: String) async throws {
    let setText = try await ABIRuntime.shared.object(renderer).resolve(.setter(
        "text", as: ((String) -> Void).self
    ))
    try unsafe setText.unsafeInvoke(text)
}
```

Setters transfer ownership of the incoming value. Getters use a zero-argument function metatype, such as `(() -> String).self`, `(() throws -> String).self`, or `(@concurrent () async -> String).self`. Getter symbol names do not establish these effects. See <doc:SwiftErrorABI>.

For a throwing getter in a generic type, also supply its source function type with `declaredAs:`. The getter symbol contains the property type but omits its formal error type. The concrete function metatype alone cannot distinguish `throws(B)` from a fixed error type that happens to equal the argument bound to `B`.

```swift
// For a provider declared as Getter<Value, Failure: Error>, with a property
// checked: Value { get throws(Failure) }, and arguments String/ProviderFailure:
let checked = try type.resolveAndWait(.getter(
    "checked",
    as: (() throws(ProviderFailure) -> String).self,
    declaredAs: "() throws(B) -> A"
))
let value = try unsafe checked.unsafeInvoke(on: receiver)
```

`declaredAs:` is also available on methods, initializers, and setters. A complete canonical `<...>` prefix supplies generic ABI requirements when the provider's import environment is needed to determine them; see <doc:GenericSwiftValues>.

`A` and `B` follow the declaration's generic parameter order. A fixed error type uses its qualified name, such as `"() throws(Example.ProviderFailure) -> A"`. Include `async` when needed. Bound object getters and static getters accept the same source signature. A getter declared with `throws(B)` still needs `declaredAs:` when `B` is bound to `Never`, even though its concrete `as:` signature is nonthrowing. Getters declared without native errors, including async getters, need only `as:`.

Use ``NativeSwiftClosure`` for callback parameters and returned closures. Initializers transfer their owned context; ordinary methods borrow it. See <doc:SwiftClosureValues>.

## Subscript accessors

Request a subscript's accessors with `getter` and `setter`, naming the complete accessor declaration. For `subscript(_ key: Element.ID) -> Element?` in a provider's `Lookup<Element: Identifiable>`, the getter takes one index and returns an optional element. The setter takes the new value first, followed by the indices.

This example uses owned runtime values: `lookup` contains `Lookup<Element>`, `key` contains `Element.ID`, and `replacement` contains `Optional<Element>`. The provider's receiver, index, and result use indirect storage:

```swift
let valueABIs = [
    key.type: try NativeType.opaque(named: key.type.name),
    replacement.type: try NativeType.opaque(named: replacement.type.name),
]
let get = try await lookup.type.resolve(.getter(
    "Example.Lookup.subscript.getter : (A.ID) -> A?",
    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
    valueABIs: valueABIs,
    receiverABI: .opaque(named: lookup.type.name)
))
let set = try await lookup.type.resolve(.setter(
    "Example.Lookup.subscript.setter : (A.ID) -> A?",
    as: ((NativeSwiftValue, NativeSwiftValue) -> Void).self,
    valueABIs: valueABIs,
    receiverABI: .opaque(named: lookup.type.name),
    receiver: .mutating
))
let setterKey = try key.copy()
try unsafe set.unsafeInvoke(on: lookup, replacement, setterKey)
let updated = try unsafe get.unsafeInvoke(on: lookup, key)
```

The setter consumes `replacement` and `setterKey`; the original `key` remains usable for the getter. Typed setter arguments transfer independent copies. A value setter receives `self` inout; pass a typed receiver with `inout` or an owned `NativeSwiftValue` whose storage can be updated.

`resolveAndWait` performs the same lookup synchronously. Property getters, including properties returning closures, keep their zero-argument signature.

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
let translate = try pointType.resolveAndWait(.method(
    "translate(_:)", as: ((Double) -> Void).self,
    receiver: .mutating
))
var point = existingPoint
try unsafe translate.unsafeInvoke(on: &point, 10)
```

Use `as:` for an unimportable struct or enum with an established representation. The adapter must match its actual layout and calling convention. When ABIBridge can establish the native type's convention, from a conformance or its metadata, member lookup rejects a representation that passes differently with ``ABIResolutionError/signatureMismatch(_:)`` at ``ABIResolutionError/SignatureMismatch/Position/receiver``. Otherwise the representation states that convention, because `receiverABI:` describes native `self` values rather than an adapter. A member that takes a protocol's `Self` by address, such as a protocol extension method, receives the address of the representation's storage, which must be at least as large and aligned as the native value. Supported representations are listed in <doc:SwiftFunctionInvocation>.

Small nonmutating value receivers use ordinary trailing components. Indirect and mutating value receivers use the Swift context register. Pass `receiver: .mutating` for mutating value methods and getters, and use an inout receiver. Value setters default to mutating; a `nonmutating` setter uses `receiver: .borrowing`.

For a `consuming` method, getter, or setter, pass `receiver: .consuming` in its request, including for an object. A typed receiver transfers an independent copy, leaving the caller's value usable. Consuming and mutating conventions are mutually exclusive, and symbol names do not distinguish them. A foreign value adapter must describe a trivial native value; nontrivial destruction requires a native adapter. Runtime owners follow the transfer contract in <doc:SwiftOpaqueResults>.

Writeback preserves the originating resource storage and implementation images without retaining a chain of intermediate value copies. After a native mutation, receiver writeback is attempted even if result conversion fails. If both conversions fail, NativeSwiftWritebackError preserves both errors. A writeback failure leaves the caller's receiver value unchanged, while other native side effects may already have occurred.

## Names, scopes, and limits

A label-only method name, such as `transform(_:)`, or a property name, such as `payload`, selects the declaration whose native parameter and result types accept the function metatype, including the class conversions described in <doc:SwiftFunctionInvocation>. Use a complete relative declaration when a wrapper has a different native name, such as `transform(Example.NativeValue) -> Example.NativeValue`; an accessor similarly uses `property.getter : Example.NativeValue` or `property.setter : Example.NativeValue`. Lookup then checks that each wrapper passes as the native type does, as described in <doc:SwiftFunctionInvocation#Use-a-wrapper-with-a-complete-declaration>. A complete declaration need not name the module of the extension that declares it. Operator names can omit fixity, such as `>(_:_:)`. If prefix and postfix implementations both match, lookup reports ambiguity; use `~~~ prefix(_:)` or a complete declaration to choose one.

Framework, executable-path, install-name, and retained-image overloads acquire explicit targets by default. Pass `loading: .loadedOnly` to retain inspection behavior; see <doc:ImageLoading>. The method or type handle keeps its implementation alive, and custom wrapper results retain their call's owners. Raw pointers remain borrowed.

The unsafe boundary requires the declaration's actual ownership, effects, and actor/thread contract. Generic metadata does not establish an unknown value's direct call layout; see <doc:ExplicitSwiftValues> and <doc:ManagedSwiftValues>.

## Resolve members from private receivers

An existing object can supply the identity of a file-private Swift class without exposing its compiler-generated private discriminator. The object member APIs match its live nominal descriptor to symbols in its defining image. Methods, getters, setters, and inherited members use that declaration owner; two same-named private classes in different files remain distinct.

```swift
let method = try runtime.object(receiver).resolveAndWait(.method(
    "title()", as: (() -> String).self
))
let title = try unsafe method.unsafeInvoke()
```

The provider module need not be importable. Lookup still requires the relevant method symbols; this does not reconstruct stripped implementations. Short label-only names and complete relative declarations are both accepted. The ordinary receiver/image lifetime and caller-supplied ABI contract remain unchanged.

A requested signature can also name a private type: as an argument, a result, a closure parameter, a tuple element, an Optional payload, or a generic argument. The runtime spells a `private` or `fileprivate` type, a type local to a function, and a type nested in either through the address of an anonymous context, while declarations spell the private or local discriminator, so the two names differ. Where the names differ, lookup resolves the declared type to metadata and accepts the host type when it is the same metadata. It resolves a private declaration from the same evidence as a closure discriminator: the symbol of the type's nominal type descriptor, or the name that the type's anonymous context records in a `-g -Onone` build; see <doc:SwiftFunctionInvocation#Infer-struct-and-enum-conventions>. Without either, lookup throws ``ABIResolutionError/metadataUnavailable(_:)`` naming the missing evidence. A private type as an argument of a parameterized protocol existential, such as `any Collection<Point>`, is not matched yet ([#472](https://github.com/lynnswap/ABIBridge/issues/472)). Pass such values as `NativeSwiftValue` or `NativeSwiftBorrowedValue`, which take their type from the declaration.
