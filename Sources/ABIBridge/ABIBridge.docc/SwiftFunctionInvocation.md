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

A label-only name selects the declaration with those labels whose native parameter and result types accept the function metatype. For example, `Example.combine(_:suffix:)` has one unlabeled argument and one labeled `suffix`; its label count must match the signature. When several overloads at the same lookup level accept the signature, lookup reports them as ambiguous; an exported overload takes precedence over one that only the shared cache's local symbols describe (see <doc:SymbolLookup>). Use a complete demangled declaration to select one overload, or when a custom wrapper has a different name from the native type.

For a label-only name, a class argument can be a subclass of the native parameter's class, including when that parameter is `Optional`, and a class result can be requested as a superclass or `AnyObject`, also wrapped in `Optional`. These conversions apply only to the call's own arguments and result, not to `inout` values, tuple fields, or closure signatures. A handle selected through such a conversion cannot install hooks, because a hook would have to pass values back as the native types.

The framework/path and retained-image overloads use the same symbol indexes as other runtime lookups. Explicit targets are acquired by default; `loading: .loadedOnly` opts out. See <doc:ImageLoading>.

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
| String, Array<Element>, and their single-level optional forms | Stable Swift storage with Swift ownership, including array element lifetimes |
| `NativeSwiftClosure<Signature>` | Owned callbacks and returned closures; the function signature carries native errors, async effects, and the caller-isolated or concurrent convention |
| Unsafe pointers, OpaquePointer, Selector, and optional pointers | Borrowed pointer values |
| CGPoint, CGSize, CGRect, NSRange | Known fixed value layouts lowered with the Swift ABI |
| Any, simple and parameterized protocol existentials, and their single-level optional forms | Compiler-managed containers with the native existential calling convention; see <doc:SwiftExistentialValues> |
| ABIBridgeSwiftValue | Actual Swift values with explicit fixed or formally indirect conventions and compiler-owned copying/destruction |
| ABIBridgeValue | Explicit trivial native layouts representable by NativeType's scalar/structure descriptions |
| NativeSwiftValue | Owned runtime values whose native type comes from the declaration or generic binding, including supported opaque results; see <doc:SwiftOpaqueResults> |
| Ordinary tuples | Labeled or nested fields with their native Swift layouts, runtime value handles, or closure handles; see <doc:SwiftClosureValues> |
| Ordinary and existential metatypes, including parameterized protocols | Preserve thin values, runtime type metadata, and required witnesses |
| Void | An empty result or explicit empty-tuple argument |

The call interface uses Swift register and stack conventions, including direct and indirect results. There is no fixed argument-count limit.

Use ``ABIBridgeSwiftValue`` for an imported struct or enum with an established fixed or formally indirect ABI; see <doc:ExplicitSwiftValues>. Its layout must match the declaration's field offsets, padding, and passing convention. A C-compatible storage description cannot describe every Swift value.

Signatures outside these representations require a compiled adapter. <doc:ManagedSwiftValues> shows a C-compatible storage bridge for managed structs, value Optionals, and imported resilient values. Closure, existential, and generic support has its own boundaries in the linked guides.

## Ownership and isolation

Object, String, and Array arguments stay alive through the call, including supported optional forms. Results transfer Swift ownership to the caller; pointer results remain borrowed. Array elements use compiler-owned copying and destruction, so an element needs no standalone direct-call representation. Arrays keep their copy-on-write behavior, and an optional array distinguishes nil from an empty array.

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

The backend provides arm64, arm64_32, and x86_64 Swift register/stack call stubs. Arm64e builds authenticate the target using the function-pointer schema supplied by the native backend. Device-target compilation is separate from runtime testing on a pointer-authentication-enabled device.

The register assignments follow the [Swift calling convention summary](https://github.com/swiftlang/swift/blob/main/docs/ABI/CallingConventionSummary.rst); integer-field coalescing follows [Clang's Swift ABI implementation](https://github.com/llvm/llvm-project/blob/main/clang/lib/CodeGen/SwiftCallingConv.cpp).
