# Calling Swift generics

Bind a declaration's type parameters with `genericArguments:` and pass its concrete callable signature with `as:`. The same binding model supports free functions, generic types, and members that introduce their own type parameters.

## Bind a generic function

For a provider declaring `func run<T>(_ apply: () -> T) -> T`, use its qualified name and argument labels:

```swift
let run = try ABIRuntime.shared.resolveAndWait(.function(
    "Example.run(_:)",
    as: ((NativeSwiftClosure<() -> String>) -> String).self,
    genericArguments: [.type(String.self)]
))
let suffix = "!"
let apply = try NativeSwiftClosure { "Hello" + suffix }
let result = try unsafe run.unsafeInvoke(apply)
```

Supply one generic argument per declared parameter, in declaration order. Lookup binds each candidate's original declaration and constraints to these arguments, then checks the concrete signature in `as:`. Multiple matching candidates report ambiguity. This also applies when `valueABIs:` describes a runtime-only argument or result.

To select an exact overload, pass its complete source-level declaration, such as `Example.run<A>(() -> A) -> A`. `A`, `B`, and later names are the Swift demangler's names for the declaration's type parameters. A complete declaration preserves explicit native types and constraints while `as:` describes the values used by the caller. Generic member lookup uses the same binding rules.

Use `.type(String.self)` for a linked Swift type or `.type(retainedType)` for a ``NativeSwiftType`` obtained at runtime. The retained type keeps metadata and implementation images alive through calls and adapted callbacks. A bare metatype assumes its implementation remains loaded.

The declaration determines the physical convention before substitution. An unconstrained `T` parameter or result remains indirect when bound to `Bool` or `String`; a class constraint can establish a reference convention. Concrete tuple fields, collections, metatypes, optional values, and dependent nominal fields retain their declaration-level lowering. Metadata size alone does not establish that convention.

## Constraints and multiple parameters

Existing protocol conformances, including conditional conformances, supply the required witness tables. Same-type requirements and associated types are resolved against the supplied arguments. For example, given `func select<T, Values: Collection>(_ fallback: T, _ values: Values) -> T where Values.Element == T`:

```swift
let select = try runtime.resolveAndWait(.function(
    "Example.select<A, B where A == B.Element, B: Swift.Collection>(A, B) -> A",
    as: ((String, [String]) -> String).self,
    genericArguments: [.type(String.self), .type([String].self)]
))
let selected = try unsafe select.unsafeInvoke("fallback", ["first"])
```

The supplied arguments must satisfy the declaration's conformance, same-type, superclass, and pack-shape requirements. Class constraints include `AnyObject` and Objective-C-compatible existential compositions, following Swift's self-conformance rules. Binding uses Swift's existing metadata and conformances; it does not create new conformances. Unsatisfied arguments fail preparation before native invocation.

Ordinary superclass/protocol compositions preserve the superclass's bound arguments, including an empty or mixed type pack. Their runtime-only values and callbacks use canonical class-bound existential metadata. A superclass plus primary-associated-type constraints instead requires extended metadata; compiler/runtime failures for those shapes remain a separate boundary described in <doc:SwiftExistentialValues>.

## Parameter packs

Use one `.pack` argument for each declared type pack, including an empty array for an empty pack. Scalar parameters remain separate entries:

```swift
// Provider: func echo<each T: Equatable>(_ values: repeat each T)
//           -> (repeat each T)
let echo = try runtime.resolveAndWait(.function(
    "Example.echo<each A where A: Swift.Equatable>(repeat A) -> (repeat A)",
    as: ((Int64, String) -> (Int64, String)).self,
    genericArguments: [.pack([.type(Int64.self), .type(String.self)])]
))
let values = try unsafe echo.unsafeInvoke(42, "answer")
```

For `repeat () -> each T`, pass one `NativeSwiftClosure<Signature>` per expanded argument, using that element's convention. Tuple patterns use one tuple per expanded element, with runtime-value and closure handles in its fields. Empty packs contribute no arguments; a single element keeps its own type, including a tuple. Short member names retain source labels such as `apply(_:)` even when the concrete signature has several arguments.

Pack expansion preserves the formal element pattern and shape. A nominal type such as `Bundle<repeat each T>` uses the same `.pack` spelling when requesting its type. Metadata and witness packs retain their ordered elements; transformed patterns and fixed prefix/suffix elements do not substitute for the declaration's hidden arguments.

## Construct a generic type and call its members

For `class Box<Value: Equatable>` with `init(_:)`, a `value` property, and `compare<Other: Equatable>(_:) -> (Value, Other, Bool)`:

```swift
let boxType = try runtime.resolveSwiftTypeAndWait(
    named: "Example.Box", genericArguments: [.type(String.self)]
)
let initialize = try boxType.resolveAndWait(.initializer(
    "init(_:)", as: ((String) -> AnyObject).self
))
let box = try unsafe initialize.unsafeInvoke("hello")
let value = try runtime.object(box).resolveAndWait(.getter(
    "value", as: (() -> String).self
))
let compare = try runtime.object(box).resolveAndWait(.method(
    "compare(_:)", as: ((Int64) -> (String, Int64, Bool)).self,
    genericArguments: [.type(Int64.self)]
))
let comparison = try unsafe compare.unsafeInvoke(42)
```

Type lookup requests complete canonical metadata for the specialization, including its required witnesses. Nested type arguments are supplied from the outer declaration to the inner declaration. Existing objects and imported value receivers provide their enclosing specialization automatically. A member's `genericArguments:` supplies only parameters introduced by that member.

Dependent results, initializers, static members, and inherited members use that enclosing context. Applicable constrained extensions are checked against the current specialization. Multiple matching short-name candidates report ambiguity; a fully qualified constrained declaration selects that exact implementation. See <doc:SwiftMemberInvocation> for receiver ownership and dispatch.

## Supply declaration information omitted from the binary

`declaredAs:` accepts the provider's formal function type, optionally prefixed by its complete canonical generic signature. It is available on free functions, methods, initializers, getters, setters, and bound object members. Keep `as:` as the concrete function type used by the caller.

Most declarations need only `as:` and their generic arguments. Generic getter symbols omit the formal error type. Supply `declaredAs: "() throws(B) -> A"` for a getter declared with `throws(Failure)`, even when `Failure` is bound to `Never`. Include `async` for an async getter and use a qualified name for a fixed error type; see <doc:SwiftMemberInvocation>.

A member combining a nominal protocol constraint with a superclass constraint may need a canonical generic signature. A retroactive superclass conformance can change hidden witnesses without changing the symbol name. Runtime conformance lookup cannot show whether the provider imported it during compilation. A conformance added in a newer version of a dependency can produce the same ambiguity. Preparation requests `declaredAs:` when it detects this ambiguity.

For `Box<Value: Score>` with a static `score() -> Int` member in `extension Box where Value: Base`, a provider that compiled with the `Base: Score` conformance visible can use:

```swift
let score = try boxType.resolveAndWait(.staticMethod(
    "score()", as: (() -> Int).self,
    declaredAs: "<A where A: BaseModule.Base> () -> Swift.Int"
))
let result = try unsafe score.unsafeInvoke()
```

If that conformance was not visible to the provider, include its remaining witness requirement:

```swift
// Same member symbol; a different canonical signature at compilation.
let score = try boxType.resolveAndWait(.staticMethod(
    "score()", as: (() -> Int).self,
    declaredAs: "<A where A: BaseModule.Base, A: BaseModule.Score> () -> Swift.Int"
))
```

Obtain the canonical signature from the provider's compiler output using its imports and build settings. Swift SIL includes the generic parameters and requirements on each declaration. Rename parameters to the demangler's names: `A`, `B`, and so on for the outer context, then `A1`, `B1` for the next depth.

Include enclosing and member parameters in order, use `each A` for a pack, and preserve conformance requirement order. Same-type and same-shape requirements use `==` and `~`. Supply the compiled declaration's signature rather than a list of runtime-discovered conformances.

When a `<...>` clause is present, its conformance requirements determine which physical witnesses are passed. The original declaration's type constraints are still validated against the supplied arguments. Known argument and result conventions continue to come from the symbol's formal types. As with `as:`, the caller is responsible for accurately describing the native implementation; a guessed canonical signature can violate its ABI.

## Effects, callbacks, and ownership

Include native errors and async isolation in `as:`; see <doc:SwiftAsyncABI> and <doc:SwiftErrorABI>. The original generic declaration determines hidden error storage even after substitution. Binding `Failure` to `Never` produces a nonthrowing concrete signature but preserves that formal convention. Binding it to `any Error` preserves the convention too.

``NativeSwiftClosure`` adapts callback arguments, results, packs, effects, and ownership to the original generic declaration. Escaping copies retain their context and images. Initializers and setters transfer an independent owned context that survives the original wrapper. See <doc:SwiftClosureValues> for callback lifetimes, nonescaping bodies, and Swift 6.3 compiler guidance.

Concrete positions follow the wrapper rule of <doc:SwiftFunctionInvocation#Use-a-wrapper-with-a-complete-declaration> when `named:` supplies the complete declaration. A direct `T` uses the bound type's actual Swift storage and compiler-owned operations. If `T` is a bridge wrapper or a tuple of wrappers, the wrappers themselves are native data; their foreign conversions are not applied. A tuple declared with native runtime-value or function fields instead converts those fields through their handles.

Use ownership wrappers to match the parameter convention. Inout writeback and cleanup also run on native error paths; see <doc:SwiftArgumentConventions>.

## Value boundaries and verification

Generic metadata establishes identity and storage operations. A concrete nominal value still needs its native call representation; see <doc:ExplicitSwiftValues> and <doc:ManagedSwiftValues>. Generic import and metadata-dispatch hooks use the same bound declarations in <doc:SwiftFunctionHooks> and <doc:SwiftMethodHooks>. Migration steps are in <doc:SwiftAPIMigration>.

Runtime tests compare bindings with separately compiled implementations, including constraints, packs, ownership, callbacks, async calls, and typed errors. An external consumer calls the public API without importing the provider. Device execution and cross-architecture compiler probes are recorded separately in the [architecture validation guide](https://github.com/lynnswap/ABIBridge/blob/main/Tests/ArchitectureValidation/README.md#generic-declaration-bindings).
