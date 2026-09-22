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

The framework/path and retained-image overloads use the same symbol indexes as other runtime lookups. They search loaded images and do not load a missing framework.

## Supported representations

| Swift representation | Calling behavior |
| --- | --- |
| Bool, fixed-width integers, Int, UInt, Float, Double, CGFloat | Native Swift scalar arguments and results |
| Class references, AnyObject, and their optional forms | Guaranteed arguments and owned results |
| String | Stable Swift storage with Swift ownership |
| Unsafe pointers, OpaquePointer, Selector, and optional pointers | Borrowed pointer values |
| CGPoint, CGSize, CGRect, NSRange | Known fixed value layouts lowered with the Swift ABI |
| ABIBridgeValue | Explicit trivial native layouts representable by NativeType's scalar/structure descriptions |
| Void | An empty result or explicit empty-tuple argument |

The call interface expands values into Swift integer/floating components, spills excess arguments to the stack, and handles direct or indirect results. There is no fixed argument-count limit. It does not call a Swift implementation through a C ABI interface or cast its address to an ordinary Swift closure.

A custom adapter's layout must match the declaration, including field offsets, padding, and whether its ABI is fixed. C-compatible storage descriptions do not describe every Swift struct or enum. Nontrivial foreign values, resilient layouts, existential containers, closures, and generic metadata or witness arguments require a compiled native adapter. Use a C-compatible bridge with the C frontend for those cases.

## Ownership and isolation

Swift object and String arguments stay alive through the call. The returned object or String transfers Swift ownership to the caller. Pointer results remain borrowed. Custom wrappers are responsible for their own native value contract; their returned NativeValue retains the resolved symbol.

The function retains its implementation image. Keep an image owner alive while a foreign value can execute code from that image, including destruction. A loaded Swift image can also be retained by the Swift runtime independently of explicit loader references.

The prepared handle is Sendable and can be reused concurrently. Each call uses separate argument, result, and register storage. Calling remains synchronous on the caller's executor; satisfy the declaration's actor and thread requirements.

## Unsupported declarations

Generic declarations, async functions, throwing functions, inout parameters, and consuming parameters need separate adapters. Lookup rejects these conventions when they are present in the source-level declaration. The caller still establishes the exact native signature: the resolver does not prove ABI compatibility from a name, a metatype, or a storage size.

Incorrect signatures, invalid pointers, and violated ownership or isolation contracts can corrupt memory. The unsafe invocation boundary exposes that responsibility; conversion and resolution failures use Swift errors.

## Architecture support

The backend provides arm64, arm64_32, and x86_64 Swift register/stack call stubs. Arm64e builds authenticate the target using the function-pointer schema supplied by the native backend. Device-target compilation is separate from runtime testing on a pointer-authentication-enabled device.

The register assignments follow the [Swift calling convention summary](https://github.com/swiftlang/swift/blob/main/docs/ABI/CallingConventionSummary.rst); aggregate lowering follows [Clang's Swift ABI implementation](https://github.com/llvm/llvm-project/blob/main/clang/lib/CodeGen/SwiftCallingConv.cpp).
