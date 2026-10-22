# Calling native Swift async implementations

Resolve an async function with its native function metatype, then await ``NativeSwiftFunction``:

```swift
let load = try await ABIRuntime.shared.resolveSwiftFunction(
    named: "Example.load(_:)",
    as: (@concurrent (String) async throws -> String).self
)
let contents = try unsafe await load.unsafeInvoke("settings")
```

For a `nonisolated(nonsending)` declaration, use its caller-isolated metatype:

```swift
let process = try await ABIRuntime.shared.resolveSwiftFunction(
    named: "Example.process(_:)",
    as: (nonisolated(nonsending) (String) async -> String).self
)
let result = try unsafe await process.unsafeInvoke("input")
```

Explicit annotations keep the convention independent of the consumer's feature flags. Plain async function types follow its `NonisolatedNonsendingByDefault` setting. Use `@concurrent` when the native entry has no hidden caller-isolation payload.

## Members, values, and errors

``NativeSwiftType`` accepts async metatypes for methods, static methods, allocating initializers, and getters. Bound object lookups use the same signatures. Getter signatures have zero arguments, for example `(@concurrent () async throws -> String).self`. A concurrent metatype describes the physical parameters of an actor-isolated entry too; it does not remove that declaration's actor requirements.

Arguments and results use the same supported Swift value representations as synchronous calls. Receivers, argument storage, descriptors, and implementation images remain alive across suspension. Mutating receivers are written back even on native failure, and initializer/consuming ownership transfers follow the native declaration.

Untyped and concrete typed native failures are returned as ``NativeSwiftError``, which keeps its error and code owners alive. Bridge lookup and conversion failures retain their original types. The bridge runs on the caller's Swift task, preserves task-local and cancellation state, and returns to the caller's executor. Cancellation remains cooperative: it does not abandon an active native context or release its values before completion.

Async closures use ``NativeSwiftClosure`` with an async signature; see <doc:SwiftClosureValues>. Argument ownership follows <doc:SwiftArgumentConventions>. Bind hidden generic metadata and witnesses with `genericArguments:` as described in <doc:GenericSwiftValues>. A native call also requires a valid async descriptor.

Opaque some results can use NativeSwiftValue in the async signature. Their dynamic storage is adopted only on success; see <doc:SwiftOpaqueResults>.

## Entry and completion

Swift async entries use LLVM's `swifttailcc`. This convention lets the callee remove stack arguments for mandatory tail calls. A compiler-emitted async function descriptor contains a relative function address and a 32-bit context size. The descriptor and code must remain loaded throughout the operation.

The context begins with parent-context and resume-function pointers. On arm64e these fields have distinct authentication schemas and address diversity. A completion continuation receives the callee context, obtains its parent, and releases the callee allocation. Task-local allocation and deallocation follow a strict stack discipline.

Direct return components become parameters of the completion function. Async error completion uses the `swiftself` parameter: an owned error reference for untyped throws, or a failure indicator for typed throws. Concrete errors reuse integer carriers or use indirect storage according to their representation. Only the selected success or error value is initialized.

An indirect normal result occupies a leading ordinary parameter. An indirect typed error uses a trailing output pointer. These allocations are independent, and neither is an ordinary direct result register.

The rules are grounded in Swift's [async call lowering](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenCall.cpp), [async context definition](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Task.h), [task allocation contract](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/Runtime/Concurrency.h), and LLVM's [Swift tail calling convention](https://github.com/swiftlang/llvm-project/blob/swift-6.3-RELEASE/llvm/docs/LangRef.rst).

## Caller-isolation convention

A `nonisolated(nonsending)` declaration accepts a hidden caller-isolation payload. In the verified Swift 6.3 lowering, this expands into two pointer-sized integer words before the explicit arguments. The payload contains an actor reference and witness/flag information; it is distinct from a SerialExecutorRef, and the compiler converts it to an executor when needed. An `@concurrent` declaration has no such prefix. Actor-isolated declarations have their own executor requirements.

Enabling NonisolatedNonsendingByDefault changes a default nonisolated async declaration to caller-isolated behavior without changing its source symbol name. Therefore, symbol lookup alone cannot identify the complete ABI. Explicit `@concurrent` and `nonisolated(nonsending)` annotations keep the fixtures' contracts independent of the package's feature flags. See [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md).

The caller must satisfy any actor requirement left to it by the declaration. Selecting the physical convention does not establish that requirement.

## Verification

Independent provider and adapter tests compare ordinary Swift async calls with the bridge. They cover suspension lifetime, cancellation, task-local values, isolation, register/stack arguments, and direct/indirect success and error outputs. Runtime checks passed on macOS arm64 and an arm64e iPhone. Compiler probes check descriptors and context authentication separately; arm64_32 coverage is compilation-only. See the [architecture validation guide](https://github.com/lynnswap/ABIBridge/blob/main/Tests/ArchitectureValidation/README.md) for recorded configurations.
