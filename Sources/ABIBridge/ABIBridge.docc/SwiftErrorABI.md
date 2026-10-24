# Calling throwing Swift implementations

Include the declaration's native error type in the function metatype. The same API accepts nonthrowing functions, untyped `throws`, and concrete `throws(Failure)`.

```swift
let load = try ABIRuntime.shared.resolveAndWait(.swift(.function(
    "Example.load(_:)", as: ((String) throws -> String).self
)))
do {
    let contents = try unsafe load.unsafeInvoke("settings")
    print(contents)
} catch let error as NativeSwiftError {
    error.withUnderlyingError { nativeError in
        print(nativeError)
    }
}
```

A native failure arrives as ``NativeSwiftError``, retaining the original error and implementation image through destruction. Lookup, conversion, and other bridge failures keep their own types. Synchronous calls run on the caller's executor and require the declaration's actor/thread contract.

## Specify concrete errors and members

For `func checked(_ value: Int64) throws(CheckFailure) -> String`, pass `((Int64) throws(CheckFailure) -> String).self`. An imported error struct or enum supplies its actual Swift representation through ``ABIBridgeSwiftValue``; use explicit components for a fixed ABI or `NativeType.opaque(named:)` for formally indirect values. Swift class errors use their reference representation. Foreign conversion adapters cannot substitute a different native error type.

Instance and static methods and allocating initializers accept the same throwing function metatypes. A throwing getter uses a zero-argument signature:

```swift
let getter = try type.resolveAndWait(.swift(.getter(
    "contents", as: (() throws -> String).self
)))
let contents = try unsafe getter.unsafeInvoke(on: receiver)
```

Getter symbols omit their error convention, so supply the actual error type. Generic throwing getters also need `declaredAs:`; see <doc:SwiftMemberInvocation>. Mutating receivers are written back after native errors. Initializer arguments and consuming receivers transfer ownership on success and failure; if writeback also fails, ``NativeSwiftWritebackError`` preserves both errors.

Use `withUnderlyingError` to inspect or cast the original error. If a value escapes that scope and can execute code from the native image, keep the wrapper alive for that value's lifetime. A native Swift image can also be retained independently by the Swift runtime.

## Native error representation

Untyped `throws` returns an owned Swift error reference through the platform error register. It can contain a Swift value error or NSError. The ordinary result remains uninitialized on failure and is never decoded.

Typed `throws(Failure)` uses a separate failure indicator and the concrete error value's lowering. Zero-valued error payloads still indicate failure. Small integer/reference errors share or widen integer result registers; floating ordinary results retain their floating register bank. Void success may still carry a direct error value.

An indirectly returned ordinary result, a formally indirect or large error, or an error containing floating components requires a separate trailing error-output pointer. It is independent of the ordinary indirect-result pointer. Only the selected result is adopted; error storage is not treated as an ordinary object pointer unless the declaration uses untyped throws.

These conventions follow Swift's [combined result/error lowering](https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/GenCall.cpp) and Clang's [Swift error-return classification](https://github.com/swiftlang/llvm-project/blob/swift-6.3-RELEASE/clang/lib/CodeGen/ABIInfo.cpp).

## Boundaries and verification

Async functions use <doc:SwiftAsyncABI>, and throwing closures use <doc:SwiftClosureValues>. Managed hooks return errors through the target's native channel when it can represent them, with recovery for other failures; see <doc:SwiftFunctionHooks>. Compiled replacements require an exact ABI match, including error effects.

Objective-C and C++ exceptions are outside this Swift error channel. Incorrect ABI descriptions can corrupt memory and cannot be recovered as bridge errors.

Separate provider and adapter fixtures check boxed and concrete errors, indirect outputs, initializers, and receiver writeback. Runtime checks passed on macOS arm64 in Debug, Release, and Address Sanitizer, and on an arm64e iPhone. Cross-architecture compiler probes are separate evidence; see the [architecture validation guide](https://github.com/lynnswap/ABIBridge/blob/main/Tests/ArchitectureValidation/README.md).
