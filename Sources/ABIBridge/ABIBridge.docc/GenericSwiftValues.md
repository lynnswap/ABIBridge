# Calling Swift generics

Call synchronous free functions with one unconstrained type parameter using an explicit substitution. Use an importing compiler adapter for constrained declarations and generic nominal metadata construction.

## Call one unconstrained generic function

For a provider declaring `func run<T>(_ apply: () -> T) -> T`, supply its complete source-level declaration and a concrete signature:

```swift
let run = try await ABIRuntime.shared.swiftFunction(
    named: "Example.run<A>(() -> A) -> A",
    as: ((NativeSwiftClosure<String>) -> String).self,
    substituting: String.self
)
let suffix = "!"
let apply = try NativeSwiftClosure { "Hello" + suffix }
let result = try unsafe run.unsafeInvoke(apply)
```

`A` is the Swift demangler's source-level name for the first type parameter; no mangled symbol is needed. The supplied metatype must match every occurrence of `A` in the concrete signature. The `substituting:` overload also accepts a retained ``NativeSwiftType`` and retains its image through invocation and adapted callback contexts. Supplying a metatype directly assumes the type's implementation remains available, as for ordinary linked Swift types.

The declaration controls physical lowering. `Bool` and `String` both use indirect generic arguments/results, even though their concrete calling conventions differ. The bridge appends the hidden type metadata and adapts a zero-argument callback to initialize its formal indirect result. Native escaping copies retain the adapted closure's context and required code owners. A failure converting a later argument releases earlier storage and adapted contexts without entering native code.

The initial direct subset supports synchronous, nonthrowing free functions with one unconstrained `<A>`. `A` can occur directly in arguments/results or as the result of `() -> A`; other positions use the existing concrete representations. Direct `A` arguments/results use the substituted type's actual Swift storage and compiler-generated value operations. `ABIBridgeValue` conversions and argument convention markers are not applied at those positions: explicitly substituting a wrapper type means `A` is the wrapper itself. A `() -> A` callback additionally requires `NativeSwiftClosure`'s supported concrete result representation for reabstraction. Constraints, dependent composites such as `Array<A>`, multiple parameters, generic members, packs, async/throwing effects, and imported hooks/replacements need additional contracts. Nongeneric nominal types containing concrete substitutions remain covered by <doc:ExplicitSwiftValues>.

For a native nonescaping `apply`, use ``NativeSwiftClosure/withUnsafeNonescaping(_:_:)`` to keep a caller-isolated body within its synchronous call. Neither the callee nor the use body may retain that callback:

```swift
let run = try await ABIRuntime.shared.swiftFunction(
    named: "Example.run<A>(() -> A) -> A",
    as: ((NativeSwiftClosure<Bool>) -> Bool).self,
    substituting: Bool.self
)
var calls = 0
let result = try unsafe NativeSwiftClosure<Bool>.withUnsafeNonescaping({
    calls += 1
    return true
}) { callback in
    try unsafe run.unsafeInvoke(callback)
}
```

`SwiftGenericCallTests` compares scalar and managed substitutions with separately compiled compiler-generated calls, including capturing callbacks, indirect reference ownership, empty results, escaping copies and conversion failures. `SwiftRuntimeValueConsumer` combines this entry with a runtime-only borrowed callback without importing its concrete provider type. Runtime validation is on macOS arm64 in Debug and Release. `check-swift-generic-call-codegen.py` checks hidden metadata, formal result/self conventions, and arm64e callback discriminators on arm64, x86_64, arm64e and arm64_32. Compilation does not establish runtime coverage on those other targets.

## Choose the specialization boundary

A Swift generic accessor does not share the zero-substitution metadata contract used by ``NativeSwiftType``. The verified prototype uses a separate fixture module with a constrained `GenericRecord<Value: GenericMetric>` and an adapter module that imports its declaration. The adapter accepts a live element metatype, checks its existing `GenericMetric` conformance, and lets Swift open that metatype for generic code.

```swift
func specializedType(for argument: Any.Type) -> Any.Type? {
    guard let conforming = argument as? any GenericMetric.Type else { return nil }
    func specialize<Value: GenericMetric>(_ type: Value.Type) -> Any.Type {
        GenericRecord<Value>.self
    }
    return specialize(conforming)
}
```

The caller supplies a metatype, not a mangled generic argument list. The compiler supplies the metadata and protocol witness arguments and requests complete specialization metadata. Repeated requests for the same nominal declaration and substitutions return the runtime's canonical metadata. Different substitutions have different identities. This compiler runtime cache does not replace ABIBridge's image-aware symbol cache or authorize persisting an unowned metadata address.

The constrained metadata prototype uses the C frontend. It does not extend the direct free-function subset above to arbitrary generic nominal lookup or protocol constraints. A metatype still does not provide all declaration-level lowering and ownership information.

## Pass values and retain their owners

The importing adapter can report a specialized type's stride and alignment, initialize that type into caller-provided storage, read it through a constrained generic operation, and destroy it. Invoke such C-compatible exports through the C frontend's ``NativeFunction`` and use ``NativeValue`` to own the initialized allocation.

Keep these contracts together:

- The argument metadata comes from a valid live Swift metatype. A raw address is not validated by a conformance cast.
- The adapter's compiler knows the generic nominal declaration and protocol. It checks the conformance before calling the accessor or interpreting value storage.
- Input storage contains the exact substituted Swift type. An initializer borrows it and initializes one fresh, distinct output allocation.
- The allocation uses the compiler-reported stride and alignment. An unsuccessful operation leaves output untouched and does not create a value to destroy.
- Retain the adapter, nominal declaration, substituted type, and conformance implementation images through the final value operation, including destruction. The prototype's value retains the resolved adapter and argument-provider handles.
- Destroy initialized values exactly once. The Swift compiler handles their value witnesses and payload references.

The fixture's status distinguishes unavailable metadata from an unsatisfied conformance. This is an adapter-specific C contract, not a new ABIBridge error API. Its shape is known at compile time; it does not attempt to cast arbitrary protocols supplied by runtime name.

## Supported evidence and remaining work

Runtime fixtures cover reference-bearing frozen and resilient substitutions, an existing conditional conformance, indirect generic results, copied value ownership, repeated specialization identity, and failure before output initialization. An external consumer loads separate fixture and adapter libraries without importing the Swift types, calls through retained metadata and storage handles, then destroys the value after its lookup runtime and original loader reference end. Swift's own runtime may retain these libraries independently; the check does not claim they physically unload.

Compiler fixtures record the metadata accessor's request, substituted metadata and witness arguments, generic indirect value lowering, and value destruction for arm64, x86_64, arm64e, and arm64_32. These are compilation checks; runtime execution is verified separately on macOS arm64 in Debug and Release.

| Case | Prototype contract |
| --- | --- |
| One known generic nominal declaration and imported protocol | Compiler-owned specialization and constrained calls |
| Existing conditional conformance | Checked by Swift's conformance cast, including failure |
| Associated types and same-type requirements | Need their own substitution and witness evidence |
| Generic superclass members | Need the inherited generic context and member convention |
| Parameter packs | Need pack shape, metadata and witness argument lowering |
| Protocol unavailable to the adapter compiler | Needs a separately established runtime conformance contract |
| New arbitrary conformances | Not synthesized |
| Unknown by-value struct or enum ABI | Not established by specialization metadata or storage size |

See <doc:ManagedSwiftValues> for storage ownership and <doc:SwiftFunctionInvocation> for currently supported direct representations.
