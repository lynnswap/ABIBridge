# Calling Swift functions with opaque results

Use ``NativeSwiftValue`` for a native declaration returning `some P`. The matched declaration's opaque descriptor supplies the hidden type and its result convention; runtime metadata supplies storage size and alignment.

For a loaded module declaring `func makeSummary(_ title: String) -> some Summary`:

```swift
let make = try ABIRuntime.shared.resolveAndWait(.function(
    "Example.makeSummary(_:)",
    as: ((String) -> NativeSwiftValue).self
))
let result = try unsafe make.unsafeInvoke("Title")
try result.withCopy { value in
    if let summary = value as? any Summary {
        print(summary)
    }
}
```

The same result type works with supported synchronous, throwing, and async functions, methods, static methods, and property getters, including declarations in another module's extension. Match the native effects, argument ownership, receiver, and isolation conventions exactly as for ordinary calls.

For a generic factory, use its complete declaration and bind the generic arguments:

```swift
let make = try runtime.resolveAndWait(.function(
    "Example.makeSummary<A>(A) -> some",
    as: ((String) -> NativeSwiftValue).self,
    genericArguments: [.type(String.self)]
))
let result = try unsafe make.unsafeInvoke("Title")
```

Opaque descriptors receive the enclosing type and function bindings, including existing protocol witnesses. Generic instance members combine their owner's arguments with method arguments. Tuples and Optional containers preserve the opaque declaration's storage convention. A tuple can contain multiple independent opaque results, and returned NativeSwiftClosure values use the same declaration plan, including throwing and async signatures.

## Values and lifetime

The handle owns the initialized native value and retains its implementation images through destruction. Assignment shares that owner. `copy()` creates an independent value when the payload is Copyable, and `take(as:)` transfers an exact known type, including a noncopyable type. A type mismatch leaves the original value owned.

The `type` property exposes a retained ``NativeSwiftType`` and its source name. Distinct opaque declarations keep their Swift type identities.

Copies follow Swift semantics, including shared references. Values interacting in a call share their code dependencies so later reference or inout updates remain usable, even after a native error. Related value/type handles can keep those images loaded. Borrow expiry and consumed ownership remain unchanged.

Callbacks passed alongside runtime values share those code dependencies. A callback restores that relationship when native code invokes it later, including across async suspension. Native calls made from its body contribute their implementation images even when their arguments use ordinary Swift types.

`withCopy` supplies an ordinary `Any` copy for casts to known types or existing protocol conformances. Copying a noncopyable value throws `NativeSwiftValueError.noncopyableType`. The hidden type needs no ``ABIBridgeSwiftValue`` conformance. Its actor or thread requirements still apply, so the handle is not Sendable.

If a value or metatype escapes `withCopy`, keep the handle alive while it can execute native code, including destruction. After `take(as:)`, keep the type handle for that purpose. Indirect resources keep their original lifetime requirements. Extracting an independent String or number within the scope avoids carrying the native value onward.

Use `withBorrowedValue` for access without copying. The view expires at body completion; see <doc:BorrowedSwiftValues>. Conflicting access during a native operation throws `NativeSwiftValueError.valueInUse`.

Only native success adopts the output storage. Native errors and cooperative cancellation preserve the existing NativeSwiftError behavior without destroying an uninitialized result. Async storage and descriptors remain alive until the operation completes.

## Call ordinary members

Prepare members through the result's type and pass the owner directly. For a hidden resilient value whose implementation provides `read()` and a mutating `add(_:)`:

```swift
let selfABI = try NativeType.opaque(named: result.type.name)
let read = try result.type.resolveAndWait(.method(
    "read()", as: (() -> Int64).self, receiverABI: selfABI
))
let add = try result.type.resolveAndWait(.method(
    "add(_:)", as: ((Int64) -> Void).self,
    receiverABI: selfABI, receiver: .mutating
))
try unsafe add.unsafeInvoke(on: result, 5)
print(try unsafe read.unsafeInvoke(on: result))
```

The opaque descriptor describes the factory's result convention, not every underlying member's self convention. Supply receiverABI when that convention is unavailable from the type's representation, its generic declaration, or the convention inferred from its metadata; see <doc:SwiftFunctionInvocation#Infer-struct-and-enum-conventions>. Fixed components use the same NativeType contract as ABIBridgeSwiftValue; an opaque descriptor selects formally indirect self. Class receivers use their reference representation without an override.

Members prepared with `consuming: true` transfer the owned payload, including noncopyable values. Active borrowed views support nonconsuming members, with mutation allowed only by their borrow contract. Getter signatures use a complete zero-argument function type. For earlier borrowed-member APIs, see <doc:SwiftAPIMigration>.

## Pass values through generic calls

Bind a native generic parameter to the value's retained type. The signature uses NativeSwiftValue for owned runtime inputs and results, or NativeSwiftBorrowedValue for an active borrowed input. For a provider declaring `move<T: ~Copyable>(_ value: consuming T) -> T`:

```swift
let move = try runtime.resolveAndWait(.function(
    "Provider.move<A where A: ~Swift.Copyable>(__owned A) -> A",
    as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self,
    genericArguments: [.type(result.type)]
))
let moved = try unsafe move.unsafeInvoke(NativeSwiftConsuming(result))
// result.isConsumed is true; moved owns the same native payload.
```

An ordinary runtime argument borrows its value. ``NativeSwiftConsuming`` transfers the existing payload without copying; ``NativeSwiftInout`` grants exclusive access to the same owner's storage. Type compatibility and conflicting access are checked before entry.

Conversion failure before entry preserves runtime owners. Once native execution begins, consuming arguments transfer on both success and failure. See <doc:SwiftArgumentConventions> for writeback.

Borrowed and consuming class arguments allow a subclass to be passed to its superclass or AnyObject. Inout arguments require the exact storage type because the callee can replace the reference with a different instance of the declared type.

These conventions also apply through async suspension. An async call started with an owned-value borrow retains its read access through completion, even when the borrowed view's scope has ended. Generic results initialize the same owned storage used by opaque results. Generic bindings enforce both Copyable and Escapable requirements. A noncopyable or nonescapable type can bind only where the declaration suppresses the corresponding requirement with `~Copyable` or `~Escapable`.

## Opaque and existential results

A `some P` result contains the actual hidden value. Class constraints select an owned object pointer; otherwise the result is indirect, even for a hidden integer or class instance. `withCopy` then lets Swift build an `Any` container. Declarations returning `any P` already use an existential container and follow <doc:SwiftExistentialValues>.

## Create enum values

Use a concrete ``NativeSwiftType`` to construct a case without associated values:

```swift
let modeType = try await runtime.resolveSwiftType(named: "Example.DisplayMode")
let compact = try modeType.makeEnumCase(named: "compact")
```

`makeEnumCase(named:)` returns a new ``NativeSwiftValue`` initialized by the enum's value witnesses. It reads the type's existing case metadata and runs synchronously on the caller's thread, without symbol lookup or call preparation. The value retains the type and its implementation images through destruction.

The enum must be Escapable, but it need not be Copyable. A missing or ambiguous case name, a case requiring a payload, or an unsupported type throws. Use the unqualified case name without backticks, including for Swift keywords.

For a case with associated values, pass an owned runtime payload obtained from a native call or another enum:

```swift
if let payload = try await result.resolveEnumPayload(forCase: "item") {
    let item = try await result.type.makeEnumCase(named: "item", payload: payload)
}
```

`makeEnumCase(named:payload:valueABIs:)` copies the entire payload without modifying or consuming the input. Its concrete metadata must exactly match the selected case's payload type. Multiple associated values use their native tuple representation, including labels. Direct and indirect cases own the copy independently. The payload must be Copyable; the containing enum need not be Copyable.

Function values in the payload are adapted to the case's native convention. As with enum payload resolution, supply `valueABIs` for closed nominal closure parameters or results that require an explicit ABI. Preparation runs away from the caller's executor, while copying and captured-context binding stay on it. `makeEnumCaseAndWait(named:payload:valueABIs:)` performs the same operation synchronously and can block during preparation.

A case without associated values, a mismatched payload type, or unavailable field metadata throws before an enum value is returned.

## Copy contained runtime values

An enum, tuple, or existential can contain a value whose type is unavailable to the consumer. Copy that value into another ``NativeSwiftValue`` and use its retained type for member lookup:

- `resolveEnumPayload(forCase:valueABIs:)` returns the specified case's entire runtime payload and prepares any function values for owned runtime storage. A different active case or a case without a payload returns `nil`. An unknown or ambiguous case name throws. Use `resolveEnumPayloadAndWait(forCase:valueABIs:)` for synchronous resolution.
- `copyTupleElement(at:)` copies the actual tuple element at a zero-based index. A non-tuple value or an out-of-range index throws.
- `copyUnderlyingValue()` opens an existential such as `Any` or `any P`. Nested existential containers are opened until the concrete type is reached. An Optional, enum, or other concrete container keeps its own type. A nonexistential receiver throws.

For a native enum with `case item(any Payload)` whose concrete payload is a resilient value implementing `read() -> Int64`:

```swift
if let payload = try await result.resolveEnumPayload(forCase: "item") {
    let concrete = try payload.copyUnderlyingValue()
    let read = try await concrete.type.resolve(.method(
        "read()", as: (() -> Int64).self,
        receiverABI: .opaque(named: concrete.type.name)
    ))
    print(try unsafe read.unsafeInvoke(on: concrete))
}
```

The payload retains its actual runtime shape. A labeled single associated value, such as `case item(value: Int)`, is a one-element tuple; use `copyTupleElement(at: 0)` to copy its value. Runtime metadata can describe `case pair((Int, Int))` and `case pair(Int, Int)` with the same tuple payload, so extraction does not reconstruct source parameter boundaries.

These operations leave the original owner unchanged and retain the copied value's metadata, witnesses, and code images independently. Class values keep ordinary shared reference identity. The copied type must be Copyable and Escapable; enum extraction also requires a Copyable enum.

An enum's concrete function fields can use a different calling convention from a generic function field with the same runtime type. Enum resolution uses the field declaration and generic bindings to adapt functions, including function elements in structural tuples, before publishing the owned payload. The async resolver prepares away from the caller's executor and joins required shared stages; copying and captured-context binding stay on the caller's executor. The synchronous `AndWait` resolver can block. Both work without an explicit `prepare`. Supply `valueABIs` when a projected function's parameters or result contain a closed nominal type whose calling convention requires an explicit descriptor.

Tuple and existential copies use already established value conventions and run synchronously without symbol-index search. Member or closure preparation uses the async `resolve…` or synchronous `resolve…AndWait` operation afterward. See <doc:SwiftClosureValues> for calling an extracted closure.

Member invocation keeps its existing ABI requirements. A getter returning a closed nominal enum or struct whose convention ABIBridge cannot infer requires `valueABIs:` even when `NativeSwiftValue` receives the result. Supply an established direct representation or formally indirect `.opaque` convention as described in <doc:BorrowedSwiftValues>; storage dimensions alone do not establish that calling convention.

This also applies to a nominal aggregate nested in a generic owner when its ABI cannot be inferred from the declaration, such as `Source<A>.Structure`. Use the retained type of the instantiated aggregate as the `valueABIs` key. An override does not change an archetype's formally indirect convention or the established conventions of generic classes and standard collections.

The `any Error & AnyObject` composition has incompatible native and generic storage layouts in the tested Swift 6.3 and 6.4 toolchains. Projection rejects this composition, including tuple and Optional payloads containing it, before copying. Ordinary `any Error` and class-bound protocols inheriting `Error` use their supported storage representations. See <doc:SwiftExistentialValues> for the existing native-call boundary.

## Scope

Owned opaque results must be Escapable. Their generic bindings and nested tuple or closure positions are resolved from the matched declaration. Copyability comes from the concrete metadata; `some ~Copyable` results use the same owned storage and can be moved without Any erasure. Nonescapable results use the scoped body described below. Opaque callback results and managed hook bodies require separate contracts; this owned-result API does not extend their lifetime.

Existing View conformance can be opened through the owned wrapper in <doc:SwiftUIInteroperability>. Other operations need the native protocol API or a compiled adapter; the bridge does not synthesize witnesses.

Compiler controls compare provider descriptors with independently compiled callers. The operation follows Swift's [opaque descriptor layout](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h), [generic requirements](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/GenericContext.h), and [metadata accessor ABI](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/Runtime/RuntimeFunctions.def). Runtime execution is recorded separately in the [architecture validation guide](https://github.com/lynnswap/ABIBridge/blob/main/Tests/ArchitectureValidation/README.md).

## Scoped nonescapable results

Use `NativeSwiftBorrowedValue` as the result marker and `unsafeInvoke(..., withResult:)` when a native result must stay within its valid lifetime:

```swift
let make = try runtime.resolveAndWait(.function(
    "Example.makeView(_:)",
    as: ((Owner) -> NativeSwiftBorrowedValue).self
))
let number = try unsafe make.unsafeInvoke(owner, withResult: { view in
    try unsafe read.unsafeInvoke(on: view)
})
```

Prepare member handles such as `read` before entering a synchronous body. They use the existing receiver ABI contract; a value receiver whose convention ABIBridge cannot infer requires an explicit `receiverABI`. The same `withResult:` form is available on member and bound-method handles. Async signatures accept an async body and keep the result valid through its suspension.

### Inputs that the result can borrow from

Swift passes an input that a result borrows from, as `@_lifetime(borrow input)` declares, by address when the input's type sets the addressable-for-dependencies bit, and such a tuple as one address instead of its elements. `String`, a value that stores one, and an imported C struct or union set the bit, while an imported C enum leaves it clear. Nothing that ABIBridge reads records which inputs a result borrows from: a function's mangled name, a closure's function type, and its metadata omit lifetime dependencies. Preparing a declaration with a `NativeSwiftBorrowedValue` result therefore accepts a parameter or `self` only where Swift passes it alike with or without the dependency:

- Its type leaves the bit clear, as integers, floating-point values, `Bool`, pointers, class references, closures, metatypes, collections, and structs and enums whose static value witnesses leave it clear do.
- It passes by address anyway, because it is address-only or too large for registers, or because it is an element of a parameter pack, which passes through a buffer of its elements' addresses. A tuple's elements pass separately, so the first two do not apply to a tuple.
- It is consuming or inout. Swift rejects a borrow dependency on a consuming input, and passes an inout input by address either way.

Preparing any other input throws ``ABIResolutionError/metadataUnavailable(_:)``, naming the input and its type, and what sets the bit or what does not show whether it is set, as for a generic instance, whose value witnesses the runtime builds, or for an imported option set, which the importer makes a struct and whose records do not tell it apart from a C struct. A `valueABIs` or `receiverABI` entry does not change the outcome, because it describes how the value passes without the dependency. Call such a declaration through a compiled adapter. The same applies to the parameters of a closure type whose result is `NativeSwiftBorrowedValue`.

Invocation retains argument and receiver access through the body. On return or throw, the view expires, the result is destroyed, and writeback completes. Saving the view preserves type information only.

The body can return a noncopyable Escapable value, but cannot return the native nonescapable payload as an owned handle or `Any`. Using this result marker with the ordinary result-returning overload fails before native entry.

Native and body errors remain available. If writeback also fails, `NativeSwiftWritebackError` includes the invocation/body error and the writeback error. Native failure does not run the result body or adopt uninitialized result storage.
