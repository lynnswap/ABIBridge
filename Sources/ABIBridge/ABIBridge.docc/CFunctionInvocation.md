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

The complete demangled C++ declaration selects an overload without a mangled symbol string. The function must use C-compatible parameter and result representations. Member receivers, references, and nontrivial C++ ownership require an adapter.

## Match native representations

The Swift function type describes the native ABI. A C linker name has no type information, and a demangled C++ name alone does not establish the entire call contract. Choosing a signature with the wrong widths or calling convention can corrupt memory; such mismatches are outside Swift error handling.

| C representation | Swift type |
| --- | --- |
| C bool | `Bool` |
| Signed/unsigned 8, 16, 32, or 64-bit integer | Matching `Int8`/`UInt8` through `Int64`/`UInt64` |
| Pointer-sized signed/unsigned integer | `Int`/`UInt` |
| Float/double | `Float`/`Double` |
| CoreGraphics floating point | `CGFloat` |
| Pointer | Swift pointer types or `OpaquePointer`, optionally wrapped in `Optional` |
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
