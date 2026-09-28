# Specializing Swift generics through compiler adapters

Use an importing compiler adapter to construct a known generic nominal type from metatype substitutions and invoke operations requiring an existing protocol conformance.

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

The prototype demonstrates a route available through the existing C frontend; it does not add general direct generic lookup to ``NativeSwiftType`` or ``NativeSwiftFunction``. A metatype still does not provide all declaration-level lowering and ownership information.

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
