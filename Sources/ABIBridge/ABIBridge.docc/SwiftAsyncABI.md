# Calling native Swift async implementations

Resolve an async function with its native function metatype, then await ``NativeSwiftAsyncFunction``:

```swift
let load = try await ABIRuntime.shared.swiftFunction(
    named: "Example.load(_:)",
    as: (@concurrent (String) async throws -> String).self
)
let contents = try unsafe await load.unsafeInvoke("settings")
```

For a `nonisolated(nonsending)` declaration, use its caller-isolated metatype:

```swift
let process = try await ABIRuntime.shared.swiftFunction(
    named: "Example.process(_:)",
    as: (nonisolated(nonsending) (String) async -> String).self
)
let result = try unsafe await process.unsafeInvoke("input")
```

Explicit annotations keep the call convention independent of the caller target's feature flags. Plain async function types follow that target's NonisolatedNonsendingByDefault setting. The caller-isolated overload also accepts `inheritsCallerIsolation: false` when the selected native entry has no hidden isolation payload; this is a calling-convention assertion, not an executor preference.

## Members, values, and errors

``NativeSwiftType`` accepts async metatypes for methods, static methods, allocating initializers, and getters. Bound object lookups use the same signatures. Getter signatures have zero arguments, for example `(@concurrent () async throws -> String).self`. A concurrent metatype describes the physical parameters of an actor-isolated entry too; it does not remove that declaration's actor requirements.

Arguments and results use the same supported Swift value representations as synchronous calls. Receivers, argument storage, descriptors, and implementation images remain alive across suspension. Mutating receivers are written back even on native failure, and initializer/consuming ownership transfers follow the native declaration.

Untyped and concrete typed native failures are returned as ``NativeSwiftError``, which keeps its error and code owners alive. Bridge lookup and conversion failures retain their original types. The bridge runs on the caller's Swift task, preserves task-local and cancellation state, and returns to the caller's executor. Cancellation remains cooperative: it does not abandon an active native context or release its values before completion.

Async closure arguments and results use NativeSwiftAsyncClosure or NativeSwiftConcurrentClosure; see <doc:SwiftClosureValues>. Generic signatures and inout/consuming explicit parameters remain separate conventions. Calls require a valid async descriptor. See <doc:SwiftFunctionInvocation> for value support and <doc:SwiftErrorABI> for error inspection.

## Entry and completion

Swift async entries use LLVM's `swifttailcc`. This convention lets the callee remove stack arguments for mandatory tail calls. A compiler-emitted async function descriptor contains a relative function address and a 32-bit context size. The descriptor and code must remain loaded throughout the operation.

The context begins with parent-context and resume-function pointers. On arm64e these fields have distinct authentication schemas and address diversity. A completion continuation receives the callee context, obtains its parent, and releases the callee allocation. Task-local allocation and deallocation follow a strict stack discipline.

Direct return components become parameters of the completion function. Async error completion uses the `swiftself` parameter: an owned error reference for untyped throws, or a failure indicator for typed throws. Concrete errors reuse integer carriers or use indirect storage according to their representation. Only the selected success or error value is initialized.

An indirect normal result occupies a leading ordinary parameter. An indirect typed error uses a trailing output pointer. These allocations are independent, and neither is an ordinary direct result register.

The rules are grounded in Swift's [async call lowering](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenCall.cpp), [async context definition](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Task.h), [task allocation contract](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/Runtime/Concurrency.h), and LLVM's [Swift tail calling convention](https://github.com/swiftlang/llvm-project/blob/swift-6.3-RELEASE/llvm/docs/LangRef.rst).

## Caller-isolation convention

A `nonisolated(nonsending)` declaration accepts a hidden caller-isolation payload. In the verified Swift 6.3 lowering, this expands into two pointer-sized integer words before the explicit arguments. The payload contains an actor reference and witness/flag information; it is distinct from a SerialExecutorRef, and the compiler converts it to an executor when needed. An `@concurrent` declaration has no such prefix. Actor-isolated declarations have their own executor requirements.

Enabling ApproachableConcurrency can change a default nonisolated async declaration to caller-isolated behavior without changing its source symbol name. Therefore, symbol lookup alone cannot identify the complete ABI. Explicit `@concurrent` and `nonisolated(nonsending)` annotations keep the fixtures' contracts independent of the package's feature flags. See [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md).

The frontend preserves the caller's task and cancellation/task-local state, passes the selected caller-isolation convention, and resumes its Swift caller on the original executor. Any actor requirement that the selected declaration leaves to its caller remains part of the unsafe invocation contract.

## Ownership and cancellation evidence

The independent provider and reference-adapter targets use ordinary Swift async calls. An actor gate proves that execution has reached a suspension point before tests inspect lifetime or request cancellation. No thread is blocked to simulate an async operation.

Tests cover immediate completion, mixed register/stack arguments, receiver and argument retention, owned errors, indirect success/error outputs, floating errors, caller task-local values, and explicitly isolated functions/members. Cancellation remains cooperative: the fixture holds its arguments while suspended, then its native body decides whether to throw CancellationError or its declared typed error.

Compiler probes inspect arm64, x86_64, arm64e, and arm64_32 entry signatures, descriptors, error completion, and authenticated context operations. The dynamic frontend passed macOS arm64 tests in Debug, Release, and Address Sanitizer, x86_64 tests under Rosetta, and eight checks on an arm64e iPhone Air running iOS 27. The arm64_32 result is compilation evidence. These are verified configurations, not additional deployment requirements.
