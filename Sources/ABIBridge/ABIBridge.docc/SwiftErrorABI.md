# Calling throwing Swift implementations

Include the declaration's native error type in the function metatype. The same API accepts nonthrowing functions, untyped `throws`, and concrete `throws(Failure)`.

```swift
let load = try await ABIRuntime.shared.swiftFunction(
    named: "Example.load(_:)", as: ((String) throws -> String).self
)
do {
    let contents = try unsafe load.unsafeInvoke("settings")
    print(contents)
} catch let error as NativeSwiftError {
    error.withUnderlyingError { nativeError in
        print(nativeError)
    }
}
```

A native failure is wrapped in ``NativeSwiftError``. The wrapper retains the original Swift error and its resolved implementation image through inspection and final destruction. Lookup, argument conversion, and other bridge failures retain their original error types. Calls remain synchronous on the caller's executor and require the declaration's actor/thread contract.

## Specify concrete errors and members

For `func checked(_ value: Int64) throws(CheckFailure) -> String`, pass `((Int64) throws(CheckFailure) -> String).self`. An imported error struct or enum supplies its actual Swift representation through ``ABIBridgeSwiftValue``; use explicit components for a fixed ABI or `NativeType.opaque(named:)` for formally indirect values. Swift class errors use their reference representation. Foreign conversion adapters cannot substitute a different native error type.

Instance and static methods and allocating initializers accept the same throwing function metatypes. A throwing getter uses a zero-argument signature:

```swift
let getter = try await type.getter(
    named: "contents", as: (() throws -> String).self
)
let contents = try unsafe getter.unsafeInvoke(on: receiver)
```

Getter symbols do not prove their effect convention, so the caller must supply the actual error type. Mutating receivers are written back even when native code throws. Ordinary initializer arguments and consuming receivers transfer ownership on both success and failure. If receiver writeback also fails, ``NativeSwiftWritebackError`` preserves both failures.

Use `withUnderlyingError` to inspect or cast the original error. If a value escapes that scope and can execute code from the native image, keep the wrapper alive for that value's lifetime. A native Swift image can also be retained independently by the Swift runtime.

## Native error representation

Untyped `throws` returns an owned Swift error reference through the platform error register. It can contain a Swift value error or NSError. The ordinary result remains uninitialized on failure and is never decoded.

Typed `throws(Failure)` uses a separate failure indicator and the concrete error value's lowering. Zero-valued error payloads still indicate failure. Small integer/reference errors share or widen integer result registers; floating ordinary results retain their floating register bank. Void success may still carry a direct error value.

An indirectly returned ordinary result, a formally indirect or large error, or an error containing floating components requires a separate trailing error-output pointer. It is independent of the ordinary indirect-result pointer. Only the selected result is adopted; error storage is not treated as an ordinary object pointer unless the declaration uses untyped throws.

These conventions follow Swift's [combined result/error lowering](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenCall.cpp) and Clang's [Swift error-return classification](https://github.com/swiftlang/llvm-project/blob/swift-6.3-RELEASE/clang/lib/CodeGen/ABIInfo.cpp).

## Boundaries and verification

Async functions use <doc:SwiftAsyncABI>. Synchronous and async throwing closure values use <doc:SwiftClosureValues>. Managed hooks currently require nonthrowing targets because their callback transport has no native error output. Compiled replacements must satisfy the exact native calling convention, including compatible error effects.

Swift errors do not include Objective-C or C++ exceptions. There is no exception unwinding or thread blocking in this transport. Incorrect ABI descriptions can corrupt memory and are not recoverable bridge errors.

Separate provider and compiler-adapter fixtures exercise boxed errors, NSError, concrete scalar/reference/managed errors, floating and resilient errors, stack arguments, independent indirect outputs, initializers, and receiver writeback. Compiler probes cover arm64, x86_64, arm64e, and arm64_32. Runtime checks passed on macOS arm64 in Debug, Release, and Address Sanitizer builds. The architecture host's swift-errors mode completed 12 checks on an arm64e iPhone Air running iOS 27, including native errors and receiver writeback. These are verified configurations, not additional deployment requirements.
