# Calling Swift generics

Bind a declaration's type parameters with `genericArguments:` and pass its concrete callable signature with `as:`. The same binding model supports free functions, generic types, and members that introduce their own type parameters.

## Bind a generic function

For a provider declaring `func run<T>(_ apply: () -> T) -> T`, supply its complete source-level declaration:

```swift
let run = try await ABIRuntime.shared.swiftFunction(
    named: "Example.run<A>(() -> A) -> A",
    as: ((NativeSwiftClosure<() -> String>) -> String).self,
    genericArguments: [.type(String.self)]
)
let suffix = "!"
let apply = try NativeSwiftClosure { "Hello" + suffix }
let result = try unsafe run.unsafeInvoke(apply)
```

`A`, `B`, and later names are the Swift demangler's names for the declaration's type parameters. Supply one argument per parameter in declaration order. A complete declaration selects the original generic implementation; `as:` describes the concrete values used by the caller. Generic member lookup also accepts the short member names shown below.

Use `.type(String.self)` for a linked Swift type or `.type(retainedType)` for a ``NativeSwiftType`` obtained at runtime. The latter retains the type's metadata and implementation images through calls and adapted callback contexts. A bare metatype assumes its implementation remains loaded. Replace the former single `substituting:` argument with `genericArguments: [.type(...)]` when migrating.

The declaration determines the physical convention before substitution. An unconstrained `T` parameter or result remains indirect when bound to `Bool` or `String`; a class constraint can establish a reference convention. Concrete tuple fields, collections, metatypes, optional values, and dependent nominal fields retain their declaration-level lowering. Metadata size alone does not establish that convention.

## Constraints and multiple parameters

Existing protocol conformances, including conditional conformances, supply the required witness tables. Same-type requirements and associated types are resolved against the supplied arguments. For example, given `func select<T, Values: Collection>(_ fallback: T, _ values: Values) -> T where Values.Element == T`:

```swift
let select = try await runtime.swiftFunction(
    named: "Example.select<A, B where A == B.Element, B: Swift.Collection>(A, B) -> A",
    as: ((String, [String]) -> String).self,
    genericArguments: [.type(String.self), .type([String].self)]
)
let selected = try unsafe select.unsafeInvoke("fallback", ["first"])
```

The supplied arguments must satisfy the declaration's conformance, same-type, superclass, and pack-shape requirements. Class constraints include `AnyObject` and Objective-C-compatible existential compositions, following Swift's self-conformance rules. Binding uses Swift's existing metadata and conformances; it does not create new conformances. Unsatisfied arguments fail preparation before native invocation.

## Parameter packs

Use one `.pack` argument for each declared type pack, including an empty array for an empty pack. Scalar parameters remain separate entries:

```swift
// Provider: func echo<each T: Equatable>(_ values: repeat each T)
//           -> (repeat each T)
let echo = try await runtime.swiftFunction(
    named: "Example.echo<each A where A: Swift.Equatable>(repeat A) -> (repeat A)",
    as: ((Int64, String) -> (Int64, String)).self,
    genericArguments: [.pack([.type(Int64.self), .type(String.self)])]
)
let values = try unsafe echo.unsafeInvoke(42, "answer")
```

Pack expansion preserves the formal element pattern and shape. A nominal type such as `Bundle<repeat each T>` uses the same `.pack` spelling when requesting its type. Metadata and witness packs retain their ordered elements; transformed patterns and fixed prefix/suffix elements do not substitute for the declaration's hidden arguments.

## Construct a generic type and call its members

For `class Box<Value: Equatable>` with `init(_:)`, a `value` property, and `compare<Other: Equatable>(_:) -> (Value, Other, Bool)`:

```swift
let boxType = try await runtime.swiftType(
    named: "Example.Box", genericArguments: [.type(String.self)]
)
let initialize = try await boxType.initializer(
    named: "init(_:)", as: ((String) -> AnyObject).self
)
let box = try unsafe initialize.unsafeInvoke("hello")
let value = try await runtime.object(box).getter(
    named: "value", as: (() -> String).self
)
let compare = try await runtime.object(box).method(
    named: "compare(_:)", as: ((Int64) -> (String, Int64, Bool)).self,
    genericArguments: [.type(Int64.self)]
)
let comparison = try unsafe compare.unsafeInvoke(42)
```

Type lookup requests complete canonical metadata for the specialization, including its required witnesses. Nested type arguments are supplied from the outer declaration to the inner declaration. Existing objects and imported value receivers provide their enclosing specialization automatically. A member's `genericArguments:` supplies only parameters introduced by that member.

Dependent results, initializers, static members, and inherited members use that enclosing context. Applicable constrained extensions are checked against the current specialization. Multiple matching short-name candidates report ambiguity; a fully qualified constrained declaration selects that exact implementation. See <doc:SwiftMemberInvocation> for receiver ownership and dispatch.

## Supply declaration information omitted from the binary

`declaredAs:` accepts the provider's formal function type, optionally prefixed by its complete canonical generic signature. It is available on free functions, methods, initializers, getters, setters, and bound object members. Keep `as:` as the concrete function type used by the caller.

Most declarations need only `as:` and their generic arguments. An effectful generic getter additionally needs its formal error type, as described below. A member combining a nominal protocol constraint with a superclass constraint may also need a canonical generic signature: a retroactive superclass conformance can change the hidden witnesses without changing the member's mangled symbol. Finding that conformance in the running process cannot establish whether the provider imported it when compiling the member. When preparation detects this ambiguity, it requests a `declaredAs:` signature before invocation.

For `Box<Value: Score>` with a static `score() -> Int` member in `extension Box where Value: Base`, a provider that compiled with the `Base: Score` conformance visible can use:

```swift
let score = try await boxType.staticMethod(
    named: "score()", as: (() -> Int).self,
    declaredAs: "<A where A: BaseModule.Base> () -> Swift.Int"
)
let result = try unsafe score.unsafeInvoke()
```

If that conformance was not visible to the provider, include its remaining witness requirement:

```swift
// Same member symbol; a different canonical signature at compilation.
let score = try await boxType.staticMethod(
    named: "score()", as: (() -> Int).self,
    declaredAs: "<A where A: BaseModule.Base, A: BaseModule.Score> () -> Swift.Int"
)
```

Use the canonical signature from the provider's compiler output, with the same imports and build settings. For example, Swift SIL includes the canonical generic parameters and requirements on the function declaration. Rename its parameters to the demangler's names: `A`, `B`, and so on for the outer context, then `A1`, `B1` for the next depth. Include all enclosing and member parameters in order, use `each A` for a pack, and preserve the canonical order of conformance requirements. Same-type and same-shape requirements use `==` and `~`. This describes the provider's declaration; it is not a list of conformances discovered at runtime.

When a `<...>` clause is present, its conformance requirements determine which physical witnesses are passed. The original declaration's type constraints are still validated against the supplied arguments. Known argument and result conventions continue to come from the symbol's formal types. As with `as:`, the caller is responsible for accurately describing the native implementation; a guessed canonical signature can violate its ABI.

## Effects, callbacks, and ownership

Include `async`, the native isolation convention, and the actual error type in `as:`. Use `nonisolated(nonsending)` explicitly for a caller-isolated declaration when the consumer's default is concurrent. The original declaration still determines hidden error storage: binding `Failure` to `Never` produces a nonthrowing concrete signature while preserving the formal generic error convention. Binding it to `any Error` preserves that convention as well. Native failures arrive as ``NativeSwiftError`` with the original error available through `withUnderlyingError`.

Generic getter symbols omit their error type. Supply `declaredAs: "() throws(B) -> A"` for a getter declared with `throws(Failure)`, including when `Failure` is bound to `Never`; include `async` for an async getter. Fixed errors use their qualified source name. See <doc:SwiftMemberInvocation>.

Use ``NativeSwiftClosure`` for callback parameters and returned closures. The bridge adapts the concrete closure convention to the original generic declaration, including arguments, results, packs, async completion, and errors. Escaping copies retain their callback contexts and required images. Borrowing and consuming markers around a closure preserve this adaptation. Initializers and setters transfer an independently owned adapted closure, so a native property can keep calling it after the original wrapper is released. Follow the concrete closure representation and Swift 6.3 compiler guidance in <doc:SwiftClosureValues>.

For a synchronous nonescaping callback with caller-isolated state, use `NativeSwiftClosure.withUnsafeNonescaping`. Neither the native callee nor the use body may retain that callback.

Concrete argument and result positions retain the ordinary Swift adapter contract when `named:` supplies the complete native declaration. Direct `T` values use the bound type's actual Swift storage and compiler-generated value operations. An explicitly bound wrapper type is itself the native `T`; its `ABIBridgeValue` conversion is not applied. Use ``NativeSwiftBorrowing``, ``NativeSwiftConsuming``, or ``NativeSwiftInout`` to express the declaration's argument convention around the actual value. Initializers and setters retain their normal ownership defaults. Inout writeback and cleanup run on native error paths as well. See <doc:SwiftArgumentConventions>.

## Validation and value boundaries

The macOS runtime tests compare these bindings with separately compiled Swift implementations. They cover dependent values, associated types, conditional conformances, inherited members, packs, ownership, metatypes, callbacks, async calls, and typed errors. The external consumer exercises public APIs without importing the provider module. The `swift-generic-bindings` device mode passed 65 checks on iPhone Air / iOS 27.0.1 (24A446), built with Xcode 27.0 / Swift 6.4 in Release for arm64e with pointer authentication enabled. Sixteen related modes also passed on the same build, for 292 checks across 17 modes. The [architecture validation guide](https://github.com/lynnswap/ABIBridge/blob/main/Tests/ArchitectureValidation/README.md#generic-declaration-bindings) records the covered operations.

Compiler probes check formal argument/result conventions, hidden metadata and witness arguments, and pointer-authentication discriminators for arm64, x86_64, arm64e, and arm64_32. Compilation evidence does not establish runtime execution on the other architectures.

Generic metadata establishes a type's identity and storage operations. Passing a concrete nominal value directly still requires its native call representation; use <doc:ExplicitSwiftValues> for imported values and <doc:ManagedSwiftValues> for compiler-owned storage adapters. Runtime-only value ownership and nested callback composition are tracked in [the value API follow-up](https://github.com/lynnswap/ABIBridge/issues/285); generic hooks and replacement frontends are tracked in [the hook API follow-up](https://github.com/lynnswap/ABIBridge/issues/286).
