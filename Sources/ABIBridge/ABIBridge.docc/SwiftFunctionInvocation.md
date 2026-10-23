# Calling concrete Swift functions

Resolve a Swift function by source-level name and invoke it with ordinary Swift values.

## Resolve and call

For an already-loaded module defining `func decorate(_ value: String) -> String`:

```swift
let decorate = try ABIRuntime.shared.resolveSwiftFunctionAndWait(
    named: "Example.decorate(_:)",
    as: ((String) -> String).self
)
let message = try unsafe decorate.unsafeInvoke("Hello")
```

A label-only name selects the declaration with those labels whose native parameter and result types accept the function metatype. For example, `Example.combine(_:suffix:)` has one unlabeled argument and one labeled `suffix`; its label count must match the signature. When several overloads at the same lookup level accept the signature, lookup reports them as ambiguous; an exported overload takes precedence over one that only the shared cache's local symbols describe (see <doc:SymbolLookup>). Use a complete demangled declaration to select one overload, or when a custom wrapper has a different name from the native type; see <doc:SwiftFunctionInvocation#Use-a-wrapper-with-a-complete-declaration>.

For a label-only name, a class argument can be a subclass of the native parameter's class, including when that parameter is `Optional`, and a class result can be requested as a superclass or `AnyObject`, also wrapped in `Optional`. These conversions apply only to the call's own arguments and result, not to `inout` values, tuple fields, or closure signatures. A handle selected through such a conversion cannot install hooks, because a hook would have to pass values back as the native types.

The framework/path and retained-image overloads use the same symbol indexes as other runtime lookups. Explicit targets are acquired by default; `loading: .loadedOnly` opts out. See <doc:ImageLoading>.

### Use a wrapper with a complete declaration

A complete declaration, such as `Example.decorate(Swift.String) -> Swift.String`, selects the declaration by its spelling, so a requested type need not have the declared type's name. Lookup instead checks that each requested argument and result passes as the declared type does: in the same sequence of integer and floating-point register components at the same offsets, with an address wherever the declared value passes by address, pointing to storage at least as large and aligned as the declared value. Each address keeps its role: a parameter's address, an output of a tuple result element that passes by address, or the indirect result that holds a direct result too large for registers. When two or more tuple elements pass by address, the compiler passes that direct result's storage as the first output instead. For example, `UInt32` can stand for a declared `Swift.Int32`, `AnyObject` for a class, and an ``ABIBridgeValue`` wrapper for a struct with the same register layout, also as an element of a tuple. A tuple parameter expands into its elements, so `CGPoint` can also stand for a declared `(Swift.Double, Swift.Double)`. `Double` or `String` cannot stand for `Swift.Int32`; lookup throws ``ABIResolutionError/signatureMismatch(_:)`` with the argument or the result as its position. The check covers values that the requested type lowers by itself, including the value inside an `inout` or ownership wrapper. Runtime values, closures, and generic or opaque positions take their convention from the declaration, and a typed error must be the declared type. Passing in the same registers does not establish ownership: a wrapper for a value with nontrivial copies must manage them as the native type does.

The check needs the declared type's convention: a built-in representation, an ``ABIBridgeSwiftValue`` conformance, a `valueABIs:` entry for the declared type, or a convention inferred from its metadata (see <doc:SwiftFunctionInvocation#Infer-struct-and-enum-conventions>). A C function pointer or block passes as one pointer, so `UnsafeRawPointer` or `AnyObject` can stand for one. When the declared convention is not established, lookup throws the error that names the missing evidence, such as an undecided inference or metadata that lookup cannot find. Describe the declared type with `valueABIs:` to have the requested type compared with it. When the declared type cannot be named, as for a C type that an image imports without exporting its type descriptor, or a function-local type in an optimized image, a `valueABIs:` entry for the requested type states the convention instead, as does the requested type's own ``ABIBridgeValue`` or ``ABIBridgeSwiftValue`` conformance, and lookup passes the value without the comparison:

```swift
let uint32 = try runtime.resolveSwiftTypeAndWait(named: "Swift.UInt32")
let target = try screenType.resolveGetterAndWait(
    named: "target.getter : __C.HIDTarget",
    as: (() -> UInt32).self,
    valueABIs: [uint32: .uint32]
)
```

## Await lookup and preparation

`resolveSwiftFunction` searches and prepares the call interface on a worker queue while the caller suspends. `resolveSwiftFunctionAndWait` performs that work synchronously and can block the caller, including inside an async function. Both reuse symbol indexes and prepared layouts, and join any preparation already running for the required work.

From `MainActor`, await the factory to keep lookup and preparation from blocking the actor:

```swift
@MainActor
func makeMessage() async throws -> String {
    let decorate = try await ABIRuntime.shared.resolveSwiftFunction(
        named: "Example.decorate(_:)",
        as: ((String) -> String).self
    )
    return try unsafe decorate.unsafeInvoke("Hello")
}
```

The native signature controls invocation separately. A synchronous signature runs on the caller's executor; an async signature also requires `await` when invoking the handle:

```swift
@MainActor
func loadContents() async throws -> String {
    let load = try await ABIRuntime.shared.resolveSwiftFunction(
        named: "Example.load(_:)",
        as: (@concurrent (String) async throws -> String).self
    )
    return try unsafe await load.unsafeInvoke("settings")
}
```

Neither factory invokes the native body or requires earlier preparation. Optional `prepare(_:)` starts work ahead of a later lookup; see <doc:SymbolLookup>.

## Complete callable signatures

Prepared functions, methods, bound methods, and closures use one complete function type as their generic parameter:

```swift
let decorate: NativeSwiftFunction<(String) -> String> = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.decorate(_:)", as: ((String) -> String).self
)
let load: NativeSwiftFunction<@concurrent (String) async throws -> String> = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.load(_:)", as: (@concurrent (String) async throws -> String).self
)
```

Invocation can throw bridge errors even when the native signature is nonthrowing. Native failures arrive as ``NativeSwiftError``. Include native errors and async isolation in the function type; see <doc:SwiftErrorABI> and <doc:SwiftAsyncABI>. For changes from earlier handle types, see <doc:SwiftAPIMigration>.

## Supported representations

| Swift representation | Calling behavior |
| --- | --- |
| Bool, signed/unsigned 8–64-bit integers, Int, UInt, Float, Double, CGFloat | Native Swift scalar arguments and results |
| Class references, AnyObject, and their optional forms | Guaranteed arguments and owned results |
| String, Array<Element>, Dictionary<Key, Value>, Set<Element>, and their single-level optional forms | Stable Swift storage with Swift ownership, including element lifetimes |
| `NativeSwiftClosure<Signature>` | Owned callbacks and returned closures; the function signature carries native errors, async effects, and the caller-isolated or concurrent convention |
| Unsafe pointers, OpaquePointer, Selector, and optional pointers | Borrowed pointer values |
| CGPoint, CGSize, CGRect, NSRange | Known fixed value layouts lowered with the Swift ABI |
| Other structs and enums | Conventions inferred from their metadata when binary evidence decides them; see <doc:SwiftFunctionInvocation#Infer-struct-and-enum-conventions> |
| Any, simple and parameterized protocol existentials, and their single-level optional forms | Compiler-managed containers with the native existential calling convention; see <doc:SwiftExistentialValues> |
| ABIBridgeSwiftValue | Actual Swift values with explicit fixed or formally indirect conventions and compiler-owned copying/destruction |
| ABIBridgeValue | Explicit trivial native layouts representable by NativeType's scalar/structure descriptions |
| NativeSwiftValue | Owned runtime values whose native type comes from the declaration or generic binding, including supported opaque results; see <doc:SwiftOpaqueResults> |
| `NativeSwiftValue?` and `NativeSwiftBorrowedValue?` | An Optional of a runtime-only value: nil is the empty case, and a value of the wrapped type is copied into the payload; a result's payload is taken into an owned value. Inout Optionals and Optionals of closures in runtime values are rejected |
| `[E]`, `[K: V]`, and `[(key: K, value: V)]` holding `NativeSwiftValue` | An Array or Set of runtime-only elements as `[E]`, and a Dictionary as `[K: V]` when `K` is the native key type or as key-value pairs. Each of `E`, `K`, and `V` is `NativeSwiftValue`, `NativeSwiftValue?` for an Optional element, or the native type. Elements are copied in both directions and checked against the declaration's element types; a Set's members and a Dictionary's pairs arrive in iteration order. As with `Set(_:)` and `Dictionary(_:uniquingKeysWith:)`, passing keeps the first of equal members or keys, with the last value for a key. Inout collections, and handles nested deeper, as in `[NativeSwiftValue]?` or `[[NativeSwiftValue]]`, are rejected |
| Ordinary tuples | Labeled or nested fields with their native Swift layouts, runtime value handles, or closure handles; see <doc:SwiftClosureValues> |
| Ordinary and existential metatypes, including parameterized protocols | Preserve thin values, runtime type metadata, and required witnesses |
| Void | An empty result or explicit empty-tuple argument |
| Optionals of representations that keep their Swift storage, such as `UInt32?` and `Double?`, including nested Optionals, and `NativeSwiftClosure<Signature>?` in nongeneric positions | Swift enum storage: the payload and tag pass as integer data, so `UInt32?` takes one integer register and `Double?` two, and nil takes a value the payload does not use where it has one, as in `Bool?`. A nil closure has a null function. An explicit ABI for such an Optional must describe this convention; see <doc:ExplicitSwiftValues#Describe-Optionals>. Nonpointer `ABIBridgeValue?`, Optionals of thin metatypes, nested Optional closures, and generic Optional closures are rejected |

The call interface uses Swift register and stack conventions, including direct and indirect results. There is no fixed argument-count limit.

Use ``ABIBridgeSwiftValue`` for an imported struct or enum with an established fixed or formally indirect ABI; see <doc:ExplicitSwiftValues>. Its layout must match the declaration's field offsets, padding, and passing convention. A C-compatible storage description cannot describe every Swift value.

Signatures outside these representations require a compiled adapter. <doc:ManagedSwiftValues> shows a C-compatible storage bridge for managed structs and imported resilient values. Closure, existential, and generic support has its own boundaries in the linked guides.

## Infer struct and enum conventions

A struct or enum without a built-in representation, an ``ABIBridgeSwiftValue`` conformance, or a `valueABIs:` entry is lowered from its runtime metadata. Inference covers `NativeSwiftValue` arguments and results, Optional payloads, tuple elements, closure parameters and results, and `self`. A host type is inferred only where it is the declaration's own type: an adapter with a different Swift name needs an explicit ABI, and inside an Optional an ``ABIBridgeSwiftValue`` conformance, because the adapter's Optional can have a different layout from the native one.

A value is loadable unless it is resilient to clients or stores an address-only field: a resilient value, a `weak` or non-native `unowned` reference, an opaque existential, or a stored property of an opaque type (`some P`) that is not class-bound. Loadable values use the same register expansion as explicit layouts and pass indirectly above four registers; address-only values always pass by address. Fields come from reflection records at the offsets in the value's metadata, and preparation checks that they rebuild the value's size and alignment.

Metadata does not record `@frozen`. ABIBridge decides a convention only from records the compiler wrote, and only from records that are present:

- A nongeneric value is loadable when its static value witnesses leave the addressable-for-dependencies bit clear: it then stores nothing resilient and no opaque type that is not class-bound. The clear bit counts only when a type of the same module sets the bit, because Swift 6.1 and earlier compilers never set it, and only when the value's fields explain whether its value witnesses are POD. The fields of such a value, including generic instances, are decided with it.
- A nongeneric value whose fields explain whether its value witnesses are POD is also loadable when it is not resilient, none of its stored properties has an opaque type, and each field is loadable on its own:
  - It is not resilient when its image holds a trivial property descriptor for a stored `var` of a struct or class of its module, which only a module built without library evolution has. A type declared in an extension belongs to the extension's module. A value of another module whose metadata is static, and that stores the value at any depth through values whose metadata is static too, also shows that the value is not resilient, because that module's compiler laid it out.
  - A field record describes a stored property of an opaque type by its underlying type, so a symbol in the image's exports or symbol table must spell each stored property's declared type: its property descriptor, an accessor, or its variable initializer. A public stored property has a descriptor. An internal or private one has an exported variable initializer when it has an initial value, and otherwise only local accessors, which stripping removes. Every struct that the value stores, at any depth, needs such symbols; enum payloads cannot be opaque.
- A value is address-only when its metadata is initialized at run time, as for a nongeneric type that stores a resilient type from another module, or when its static value witnesses are not bitwise-takable. An enum is also address-only when its image exports its enum case symbols, which only a resilient enum has.
- A value whose addressable-for-dependencies bit no field explains is resilient, and passed by address, when its module exports symbols that only library evolution emits: enum case symbols, dispatch thunks, method lookup functions, or descriptors of stored properties.

Missing symbols are not evidence, and neither are the value witnesses that the runtime builds for a generic instance. Every other value is undecided. Typical cases are a value of a library-evolution module whose bit a field such as a `String` explains, even a `@frozen` one, unless a value of another module stores it; a struct with a stored property of an opaque type, even a class-bound one; a struct with a stored property that no symbol spells, such as an internal one without an initial value in a stripped image; a generic instance such as `Range<Int>` that no nongeneric value stores; and a value of a library-evolution module that Swift 6.1 or earlier compiled. Without library evolution, Swift 5 compilers gave public stored properties of types that are not `@frozen` nontrivial descriptors, so values of such modules can stay undecided too. [#434](https://github.com/lynnswap/ABIBridge/issues/434) tracks inferring generic instances.

The second rule assumes, without checking, that a module name identifies one module within an image, as runtime name lookup does, and, for binaries of Swift 5.1 to 5.4, whose compilers' sources show it, that library evolution gave every stored `var` a nontrivial descriptor.

Swift passes an input that a result borrows from by address when its type sets the addressable-for-dependencies bit, and no symbol records which input a result borrows from. In a call with a ``NativeSwiftBorrowedValue`` result, a parameter or `self` that only the second rule makes loadable is therefore undecided when its static value witnesses set the bit, unless its lowering passes it by address anyway. Values that the first rule makes loadable leave the bit clear and keep their convention.

When the evidence leaves the question open, a parameter, a result, a typed error, or `self` still passes by address if the value's frozen lowering already exceeds four registers, because both conventions then agree. An element of a tuple parameter counts as a parameter; an element of a tuple result does not. Otherwise preparation throws ``ABIResolutionError/metadataUnavailable(_:)``, naming the type, its module, the missing evidence, and the explicit ABI to supply.

Types that use two experimental compiler features can be lowered with the wrong convention. Describe them with `valueABIs:` or an ``ABIBridgeSwiftValue`` conformance:

- A `@frozen @_addressableForDependencies` type outside the SDK, which the `AddressableTypes` feature allows, sets the addressable-for-dependencies bit itself. In a library-evolution module, ABIBridge reads it as resilient and passes it by address, while the compiler passes it directly.
- A `@sensitive` type, which the `Sensitive` feature allows, is address-only. ABIBridge detects one only when none of its fields needs nontrivial copies; one that stores a reference can be passed directly.

On arm64e, a closure's pointer-authentication discriminator hashes the declaration of each struct or enum in its signature. A type declared in an extension of a generic type, constrained or not, is declared with the extension's generic signature, which can require marker protocols such as `Sendable`. Its runtime name omits that signature, and its context descriptors record the signature's requirements without marker protocols, so ABIBridge establishes such a declaration only from the type's nominal type descriptor symbol, which spells the signature: the symbol that the type's image exports, or a local symbol, which stripping removes. Preparing a closure over a type that its image does not export throws ``ABIResolutionError/metadataUnavailable(_:)`` when the image is stripped of local symbols; call it through a compiled adapter instead. A type in an extension of a nongeneric type, which has no generic signature, or in an unconstrained extension in the module of the type it extends, which shares that type's context, is named by its runtime name.

A `private` or `fileprivate` type, a type local to a function, and a type nested in either are declared with their file's private discriminator or a local discriminator. Their runtime names spell an anonymous context by its address instead. ABIBridge establishes such a declaration from the type's nominal type descriptor symbol, which is a local symbol, or, for a type that an anonymous context wraps directly, from the name that context records in a `-g -Onone` build. Preparing a closure over one whose image is stripped of local symbols and records no such name throws ``ABIResolutionError/metadataUnavailable(_:)``; call it through a compiled adapter instead. Other architectures do not compute discriminators, so closures over all of these types prepare there.

Imported C structs and unions, tuple fields containing metatypes, SIMD vectors, `Float16`, `Int128`, and noncopyable values are not inferred; preparation throws ``ABIResolutionError/unsupportedDeclaration(_:)``. Describe such values with `valueABIs:` or an ``ABIBridgeSwiftValue`` conformance. Both take precedence over inference. A `valueABIs:` entry describes a value where the declaration's signature names its type, including the payload of an Optional and an element of a tuple in the signature, but not a field or enum payload of a value that ABIBridge infers, so when inference fails on a field, describe the containing type. Inside an Optional, the entry applies only to the declaration's own type, not to an adapter host type. A conformance applies wherever its type occurs, including fields.

## Ownership and isolation

Object, String, and collection arguments stay alive through the call, including supported optional forms. Results transfer Swift ownership to the caller; pointer results remain borrowed. Collection keys, values, and elements use compiler-owned copying and destruction, so they need no standalone direct-call representation. Collections keep their copy-on-write behavior, and an optional collection distinguishes nil from an empty one.

Custom wrappers establish their own native value contract. Their returned ``NativeValue`` retains the resolved symbol.

The function retains its implementation image. Keep an image owner alive while a foreign value can execute code from that image, including destruction. A loaded Swift image can also be retained by the Swift runtime independently of explicit loader references.

The prepared handle is Sendable and can be reused concurrently with separate storage for each call. Synchronous invocation runs on the caller's executor; the caller must satisfy the declaration's actor and thread requirements. Async invocation preserves the caller's task and resumes on its executor.

## Declaration conventions

Use ``NativeSwiftInout``, ``NativeSwiftBorrowing``, and ``NativeSwiftConsuming`` for explicit parameter conventions; see <doc:SwiftArgumentConventions>. Bind generic parameters and packs with `genericArguments:` as described in <doc:GenericSwiftValues>. The caller establishes the native signature and ownership; a source name or storage size alone does not prove ABI compatibility.

Incorrect signatures, invalid pointers, and violated ownership or isolation contracts can corrupt memory. The unsafe invocation boundary exposes that responsibility; conversion and resolution failures use Swift errors.

## Pass variadic arguments

A native `T...` parameter takes one `Array<T>` argument in the call signature. For `func collect(_ values: String...) -> [String]`, use the complete declaration to select the variadic overload:

```swift
let collect = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.collect(Swift.String...) -> [Swift.String]",
    as: (([String]) -> [String]).self
)
let values = try unsafe collect.unsafeInvoke(["first", "second"])
```

An empty array supplies zero variadic elements. A label-only name cannot tell a variadic parameter from an array parameter, so keep `...` in the complete declaration when selecting a variadic overload.

The same array representation applies to generic functions and initializers. A ``NativeSwiftValue`` argument must contain the native `Array<T>` value. Ordinary functions borrow it, while allocating initializers consume it under the ownership rules in <doc:SwiftArgumentConventions>. When supplying `declaredAs:`, retain `T...` in the source signature and use `Array<T>` in the callable signature.

## Architecture support

The backend provides Swift register/stack call stubs for the AArch64 targets listed in <doc:Architectures>: arm64, arm64e, and arm64_32. Arm64e builds authenticate the target using the function-pointer schema supplied by the native backend. Device-target compilation is separate from runtime testing on a pointer-authentication-enabled device.

The register assignments follow the [Swift calling convention summary](https://github.com/swiftlang/swift/blob/main/docs/ABI/CallingConventionSummary.rst); integer-field coalescing follows [Clang's Swift ABI implementation](https://github.com/llvm/llvm-project/blob/main/clang/lib/CodeGen/SwiftCallingConv.cpp).
