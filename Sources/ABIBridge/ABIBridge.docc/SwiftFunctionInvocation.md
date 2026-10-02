# Calling concrete Swift functions

Resolve a synchronous Swift function by source-level name and invoke it with ordinary Swift values.

## Resolve and call

For an already-loaded module defining `func decorate(_ value: String) -> String`:

```swift
let decorate = try await ABIRuntime.shared.swiftFunction(
    named: "Example.decorate(_:)",
    as: ((String) -> String).self
)
let message = try unsafe decorate.unsafeInvoke("Hello")
```

A label-only name obtains its parameter and result type names from the function metatype. Use `Example.combine(_:suffix:)` for a declaration with one unlabeled argument and a second argument labeled suffix. The number of labels must match the signature. A complete demangled declaration is also accepted; use that form when a custom wrapper has a different Swift name from the native type.

The framework/path and retained-image overloads use the same symbol indexes as other runtime lookups. Explicit targets are acquired by default; `loading: .loadedOnly` opts out. See <doc:ImageLoading>.

## Complete callable signatures

Prepared functions, methods, bound methods, and closures use one complete function type as their generic parameter:

```swift
let decorate: NativeSwiftFunction<(String) -> String> = try await runtime.swiftFunction(
    named: "Example.decorate(_:)", as: ((String) -> String).self
)
let load: NativeSwiftFunction<@concurrent (String) async throws -> String> = try await runtime.swiftFunction(
    named: "Example.load(_:)", as: (@concurrent (String) async throws -> String).self
)
```

Calls can still throw lookup/conversion/invocation errors even when the native signature is nonthrowing. Native failures use NativeSwiftError. Async calls preserve their original task and resume on the caller's executor.

When migrating existing annotations, replace the result-first argument list with a function type. For example, `NativeSwiftFunction<String, Int64>` becomes `NativeSwiftFunction<(Int64) -> String>` for a nonthrowing declaration. Include its native `throws(Failure)` and `async` effects when present. Apply the same change to NativeSwiftMethod, NativeBoundSwiftMethod, NativeSwiftFunctionImplementation, and NativeSwiftMethodImplementation.

The separate async function/method types and throwing/async/concurrent closure types have been removed. Use NativeSwiftClosure with the corresponding function type, including `@Sendable` when the native closure declaration includes it. Returned closure wrappers and bound methods retain their original isolation requirements and are not Sendable merely because their signature is Sendable.

Getter lookup now takes a complete zero-argument function type: replace `getter(named: "text", as: String.self)` with `getter(named: "text", as: (() -> String).self)`. The same rule applies to staticGetter and bound-object getters. Include native errors and async isolation in that function type. Use `@concurrent` in place of the former `inheritsCallerIsolation: false` override.

## Supported representations

| Swift representation | Calling behavior |
| --- | --- |
| Bool, signed/unsigned 8–64-bit integers, Int, UInt, Float, Double, CGFloat | Native Swift scalar arguments and results |
| Class references, AnyObject, and their optional forms | Guaranteed arguments and owned results |
| String, Array<Element>, and their single-level optional forms | Stable Swift storage with Swift ownership, including array element lifetimes |
| `NativeSwiftClosure<Signature>` | Owned callbacks and returned closures; the function signature carries native errors, async effects, and the caller-isolated or concurrent convention |
| Unsafe pointers, OpaquePointer, Selector, and optional pointers | Borrowed pointer values |
| CGPoint, CGSize, CGRect, NSRange | Known fixed value layouts lowered with the Swift ABI |
| Any, simple protocol existentials, and their single-level optional forms | Compiler-managed containers with the native existential calling convention; see <doc:SwiftExistentialValues> |
| ABIBridgeSwiftValue | Actual Swift values with explicit fixed or formally indirect conventions and compiler-owned copying/destruction |
| ABIBridgeValue | Explicit trivial native layouts representable by NativeType's scalar/structure descriptions |
| NativeSwiftOpaqueValue | Owned hidden result of a single native some declaration; see <doc:SwiftOpaqueResults> |
| Void | An empty result or explicit empty-tuple argument |

The call interface expands values into Swift integer/floating components, spills excess arguments to the stack, and handles direct or indirect results. There is no fixed argument-count limit. It does not call a Swift implementation through a C ABI interface or cast its address to an ordinary Swift closure.

Use ``ABIBridgeSwiftValue`` for an imported managed struct or enum with an established fixed ABI; see <doc:ExplicitSwiftValues>. A custom adapter's layout must match the declaration, including field offsets, padding, and whether its ABI is fixed. C-compatible storage descriptions do not describe every Swift struct or enum. Nontrivial foreign values, undescribed resilient layouts, extended existentials, ordinary unwrapped function values, and generic signatures outside <doc:GenericSwiftValues> require a compiled native adapter. Use ``NativeSwiftClosure`` for the concrete callback subset described in <doc:SwiftClosureValues>. Use a C-compatible bridge with the C frontend for those cases. See <doc:ManagedSwiftValues> for a verified compiler-adapter path for managed structs, value Optionals, and imported resilient values.

## Ownership and isolation

Swift object, String, and Array arguments stay alive through the call, including supported optional forms. Their results transfer Swift ownership to the caller. Array elements use the compiler's own copying and destruction operations; the element type does not need a standalone direct-call representation. Array values retain ordinary copy-on-write behavior, and an optional array distinguishes nil from an empty array. Pointer results remain borrowed. Custom wrappers are responsible for their own native value contract; their returned NativeValue retains the resolved symbol.

The function retains its implementation image. Keep an image owner alive while a foreign value can execute code from that image, including destruction. A loaded Swift image can also be retained by the Swift runtime independently of explicit loader references.

The prepared handle is Sendable and can be reused concurrently. Each call uses separate argument, result, and register storage. Calling remains synchronous on the caller's executor; satisfy the declaration's actor and thread requirements.

## Unsupported declarations

Use NativeSwiftInout, NativeSwiftBorrowing, and NativeSwiftConsuming for explicit parameter conventions; see <doc:SwiftArgumentConventions>. The explicit `substituting:` overload handles one unconstrained generic parameter and zero-argument callbacks returning it; see <doc:GenericSwiftValues>. Protocol witnesses and other generic shapes need separate adapters. Async function metatypes produce NativeSwiftFunction handles with an async Signature; see <doc:SwiftAsyncABI>. Synchronous throwing calls use the function metatype's declared error type; see <doc:SwiftErrorABI>. The caller still establishes the exact native signature: the resolver does not prove ABI compatibility from a name, a metatype, or a storage size.

Incorrect signatures, invalid pointers, and violated ownership or isolation contracts can corrupt memory. The unsafe invocation boundary exposes that responsibility; conversion and resolution failures use Swift errors.

## Architecture support

The backend provides arm64, arm64_32, and x86_64 Swift register/stack call stubs. Arm64e builds authenticate the target using the function-pointer schema supplied by the native backend. Device-target compilation is separate from runtime testing on a pointer-authentication-enabled device.

The register assignments follow the [Swift calling convention summary](https://github.com/swiftlang/swift/blob/main/docs/ABI/CallingConventionSummary.rst); integer-field coalescing follows [Clang's Swift ABI implementation](https://github.com/llvm/llvm-project/blob/main/clang/lib/CodeGen/SwiftCallingConv.cpp).
