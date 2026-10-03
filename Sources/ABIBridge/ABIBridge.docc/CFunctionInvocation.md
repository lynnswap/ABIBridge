# Calling C and C++ functions

Resolve a source-level name and supply its signature as a Swift function type.

## Call a C function

```swift
import ABIBridge

let runtime = ABIRuntime.shared
let processID = try await runtime.cFunction(
    named: "getpid",
    as: (() -> Int32).self
)
let value = try unsafe processID.unsafeInvoke()
```

The runtime searches loaded images automatically. Use a framework or executable-path scope to select a particular loaded binary:

```swift
let add = try await runtime.cxxFunction(
    named: "Example::Math::add(int, int)",
    as: ((Int32, Int32) -> Int32).self,
    in: .framework(named: "Example")
)
let sum = try unsafe add.unsafeInvoke(20, 22)
```

The complete demangled C++ declaration selects an overload without a mangled symbol string. The function must use C-compatible parameter and result representations. Use <doc:CXXObjectInvocation> for member receivers. Reference parameters use an address with the declared access and lifetime contract. Nontrivial by-value parameters and results require a compiler adapter because their construction, destruction, and call lowering are not established by the symbol name.

## Match native representations

The Swift function type describes the native ABI. A C linker name has no type information, and a demangled C++ name alone does not establish the entire call contract. Choosing a signature with the wrong widths or calling convention can corrupt memory; such mismatches are outside Swift error handling.

| C representation | Swift type |
| --- | --- |
| C bool | `Bool` |
| Signed/unsigned 8, 16, 32, or 64-bit integer | Matching `Int8`/`UInt8` through `Int64`/`UInt64` |
| Pointer-sized signed/unsigned integer | `Int`/`UInt` |
| Float/double | `Float`/`Double` |
| CoreGraphics floating point | `CGFloat` |
| Pointer | Swift pointer types, `OpaquePointer`, or `Unmanaged<T>`, optionally wrapped in `Optional` |
| Objective-C selector pointer | `Selector` |
| Imported standard structures | `CGPoint`, `CGSize`, `CGRect`, `NSRange` |
| Void result | `Void` |

For example, a C `int` uses `Int32`, while a pointer-sized integer uses `Int`. Ordinary Swift strings, objects, arbitrary structures, and optional scalars do not have an implicit C representation in this API.

There is no fixed argument-count limit. These handles describe fixed signatures; C variadic functions need a distinct call contract and are not supported here. A Swift function using the Swift calling convention cannot be invoked through this C ABI entry point.

## Keep pointers and images alive

A function handle retains its resolved image and prepared signature. Clearing the runtime's cached indexes does not invalidate existing handles. To reuse an image explicitly:

```swift
let images = try await runtime.images(matching: .framework(named: "Example"))
if let image = images.first {
    let start = try await runtime.cFunction(
        named: "ExampleStart", as: (() -> Void).self, in: image
    )
    let stop = try await runtime.cFunction(
        named: "ExampleStop", as: (() -> Void).self, in: image
    )
}
```

Pointer arguments and results remain borrowed. Keep pointees alive and satisfy the native function's access and ownership requirements. A null return maps to an optional pointer or throws ``ABIInvocationError/unexpectedNilResult(expected:)`` for a nonoptional pointer type.

Handles are Sendable and can reuse their immutable signatures concurrently. Every call has separate argument and result storage, but the native function and supplied memory still determine whether concurrent invocation is valid. Call a thread-bound function on its required thread. Native C++ and Objective-C exceptions must not cross this invocation boundary.

## Express Core Foundation ownership

Use `Unmanaged<T>` for a native reference represented by a pointer. For example, a provider's `ExampleCopyValue` returning `CFTypeRef` at +1 can be called as follows:

```swift
let copy = try await runtime.cFunction(
    named: "ExampleCopyValue",
    as: ((Unmanaged<CFString>) -> Unmanaged<CFString>).self
)
let result = try unsafe copy.unsafeInvoke(.passUnretained(input)).takeRetainedValue()
```

The provider's contract determines whether the result is retained. Use `takeUnretainedValue()` for a borrowed result and keep its native owner alive. These operations are Swift's standard manual ownership operations; the bridge only passes pointer bits. A consumed input uses `passRetained`, and its reference transfers when native code enters. If a call fails before entry, release that reference yourself. Complete other fallible argument conversions before creating such a reference, or use a compiler adapter when the operation needs a single ownership and error boundary.
