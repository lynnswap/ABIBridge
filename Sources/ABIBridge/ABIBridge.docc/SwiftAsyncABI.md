# Preparing native Swift async invocation

Compiler-generated fixtures establish the context, executor, completion, and error contracts for direct async invocation. The current function handles remain synchronous; awaiting runtime lookup does not await a native async entry point.

## Entry and completion

Swift async entries use LLVM's `swifttailcc`. This convention lets the callee remove stack arguments for mandatory tail calls. A compiler-emitted async function descriptor contains a relative function address and a 32-bit context size. The descriptor and code must remain loaded throughout the operation.

The context begins with parent-context and resume-function pointers. On arm64e these fields have distinct authentication schemas and address diversity. A completion continuation receives the callee context, obtains its parent, and releases the callee allocation. Task-local allocation and deallocation follow a strict stack discipline.

Direct return components become parameters of the completion function. Async error completion uses the `swiftself` parameter: an owned error reference for untyped throws, or a failure indicator for typed throws. Concrete errors reuse integer carriers or use indirect storage according to their representation. Only the selected success or error value is initialized.

An indirect normal result occupies a leading ordinary parameter. An indirect typed error uses a trailing output pointer. These allocations are independent, and neither is an ordinary direct result register.

The rules are grounded in Swift's [async call lowering](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenCall.cpp), [async context definition](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Task.h), [task allocation contract](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/Runtime/Concurrency.h), and LLVM's [Swift tail calling convention](https://github.com/swiftlang/llvm-project/blob/swift-6.3-RELEASE/llvm/docs/LangRef.rst).

## Caller-isolation convention

A `nonisolated(nonsending)` declaration accepts a hidden caller-isolation payload. In the verified Swift 6.3 lowering, this expands into two pointer-sized integer words before the explicit arguments. The payload contains an actor reference and witness/flag information; it is distinct from a SerialExecutorRef, and the compiler converts it to an executor when needed. An `@concurrent` declaration has no such prefix. Actor-isolated declarations have their own executor requirements.

Enabling ApproachableConcurrency can change a default nonisolated async declaration to caller-isolated behavior without changing its source symbol name. Therefore, symbol lookup alone cannot identify the complete ABI. Explicit `@concurrent` and `nonisolated(nonsending)` annotations keep the fixtures' contracts independent of the package's feature flags. See [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md).

An invocation frontend must preserve the caller's task and its cancellation/task-local state, pass the correct executor convention, and resume its Swift caller on the required executor. Any actor requirement that the selected declaration leaves to its caller remains part of the unsafe invocation contract.

## Ownership and cancellation evidence

The independent provider and reference-adapter targets use ordinary Swift async calls. An actor gate proves that execution has reached a suspension point before tests inspect lifetime or request cancellation. No thread is blocked to simulate an async operation.

Tests cover immediate completion, mixed register/stack arguments, receiver and argument retention, owned errors, indirect success/error outputs, floating errors, caller task-local values, and explicitly isolated functions/members. Cancellation remains cooperative: the fixture holds its arguments while suspended, then its native body decides whether to throw CancellationError or its declared typed error.

Compiler probes inspect arm64, x86_64, arm64e, and arm64_32 entry signatures, descriptors, error completion, and authenticated context operations. These compilation checks are separate from runtime execution and do not establish that a future dynamic transport follows those contracts.
