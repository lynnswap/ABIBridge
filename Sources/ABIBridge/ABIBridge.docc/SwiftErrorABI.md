# Preparing synchronous Swift error invocation

Native Swift error handling needs a separate error-result contract. The compiler fixtures establish that contract before the direct frontend gains throwing invocation.

## Distinguish error representations

An untyped `throws` declaration returns an owned Swift error reference through the platform's error register. That reference can carry a Swift value error or a bridged NSError. It is distinct from the ordinary result, which is uninitialized on failure.

Typed `throws(Failure)` uses a failure indicator and the concrete error value's lowering. The indicator remains necessary when the error payload is zero. The compiler can reuse integer return registers for a small integer/reference error, widen a normal integer carrier, or add integer carriers alongside a floating result. A Void success type can still have a direct error carrier.

The following cases require separate error output storage: an indirectly returned ordinary result, a formally indirect error, an error too large for direct return, or an error containing floating components. The error-output pointer follows the ordinary arguments and context/error convention parameters. It is independent of the ordinary indirect-result pointer.

These rules follow Swift's [combined result/error lowering](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenCall.cpp) and Clang's [Swift error-return classification](https://github.com/swiftlang/llvm-project/blob/swift-6.3-RELEASE/clang/lib/CodeGen/ABIInfo.cpp). Fixture compilation checks the installed toolchain separately.

## Use a compiler adapter until direct invocation is available

The test adapters import the native declarations and let Swift handle both ordinary and error results. Their C boundary accepts distinct result/error allocations and returns a Boolean selecting the one initialized allocation.

On success, adopt or move the ordinary result and free the uninitialized error allocation. On failure, adopt or move the exact declared error and free the uninitialized ordinary-result allocation. Destroy only initialized values. A Boolean failure indication does not make the accompanying error bytes optional, and an arbitrary nonzero error-register value is not always a retainable object pointer.

Calls still need the target's actor/thread contract. Swift errors returned this way do not include C++ or Objective-C exceptions. No exception unwinding or thread blocking is introduced by the adapters.

## Evidence and integration requirements

Separate library-evolution provider and adapter modules exercise boxed errors, NSError values, typed scalar/reference/managed errors, large and resilient errors, independent success/error buffers, throwing members, and throwing initializers. Runtime tests verify payload ownership and that failure leaves ordinary-result storage untouched.

Compiler probes inspect arm64, x86_64, arm64e, and arm64_32 declarations and typed failure indicators. Runtime execution is macOS arm64 in Debug and Release; compilation does not establish authenticated device execution.

A correct direct caller must preserve the native error state before interpreting result registers, transfer owned errors exactly once, retain their required code owners, and run argument/receiver completion handling even when the callee fails. The declared error type and ordinary result together determine the native signature; a storage size alone cannot select its error convention.
