# Calling C and C++ functions

Resolve a source-level name and supply its signature as a Swift function type.

## Call a C function

```swift
import ABIBridge

let runtime = ABIRuntime.shared
let processID = try runtime.resolveAndWait(.c(.function("getpid", as: (() -> Int32).self)))
let value = try unsafe processID.unsafeInvoke()
```

The runtime searches loaded images automatically. Use a framework or executable-path scope to select a particular loaded binary:

```swift
let add = try runtime.resolveAndWait(
    .cxx(.function("Example::Math::add(int, int)", as: ((Int32, Int32) -> Int32).self)),
    in: .framework(named: "Example")
)
let sum = try unsafe add.unsafeInvoke(20, 22)
```

Both examples use synchronous `AndWait` lookup. Await `resolve` with the same request to run search, image acquisition, and call-interface preparation on a worker:

```swift
@MainActor
func processIdentifier() async throws -> Int32 {
    let processID = try await ABIRuntime.shared.resolve(
        .c(.function("getpid", as: (() -> Int32).self))
    )
    return try unsafe processID.unsafeInvoke()
}
```

Neither form needs `prepare`. If earlier preparation is still running, lookup joins only the required shared indexes and call interfaces. Invocation remains synchronous and runs where the caller invokes it. See <doc:SymbolLookup> for optional earlier preparation.

A complete demangled C++ declaration selects the overload. Parameters and results must have C-compatible representations; see <doc:CXXObjectInvocation> for member calls. Pass reference parameters as addresses with the declared access and lifetime. Nontrivial values require a compiler adapter to handle construction, destruction, and call lowering.

## Save a function request

Use ``NativeRequest`` to save a typed declaration and resolve it later:

```swift
let request = NativeRequest.c(.function("getpid", as: (() -> Int32).self))
let getPID = try await runtime.resolve(request)
let value = try unsafe getPID.unsafeInvoke()
```

`.c(...)` selects C linker-name lookup; `.cxx(...)` selects a demangled C++ free or static function. Both wrap a ``NativeFunctionRequest`` when using `as:` and return the existing ``NativeFunction`` handle. The name, function metatype, and typed `variadicFrom:` belong to the inner `.function(...)` declaration. Keep image selection and `loading:` on `resolve` or `resolveAndWait`. Both `in: ImageSelector` and `in: NativeImage` are supported; omitted scope searches `.automatic`, and loading defaults to `.ifNeeded`.

Request creation performs no lookup or ABI preparation. Requests can cross isolation boundaries because their declarations are `Sendable`; invocation must still obey the native function's execution and memory-access requirements. Saving a request does not cache a handle. Retain the resolved handle for repeated calls; existing cache controls follow <doc:SymbolLookup#Cache-and-loader-lifetime>.

## Match native representations

Supply a Swift function type that matches the native ABI. C linker names contain no type information, and demangled C++ names omit parts of the call contract. Wrong widths or calling conventions can corrupt memory without producing a Swift error.

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

There is no fixed argument-count limit. Swift calling conventions use the separate APIs in <doc:SwiftCalls>.

## Describe layouts at runtime

Use `signature:` instead of `as:` when the parameter and result layouts are known at runtime. The inner declaration is a ``DynamicNativeFunctionRequest``, and resolution returns a ``DynamicNativeFunction``:

```swift
let request = NativeRequest.cxx(
    .function(
        "Example::Math::add(int, int)",
        signature: NativeSignature(parameters: [.int32, .int32], returns: .int32)
    )
)
let add = try runtime.resolveAndWait(request, in: .framework(named: "Example"))
let values = [
    try NativeValue(copying: Int32(20), as: .int32),
    try NativeValue(copying: Int32(22), as: .int32),
]
let sum = try unsafe add.unsafeInvoke(with: values).read(as: Int32.self)
```

The same form works with `.c(.function(..., signature: ...))`. Runtime signatures describe the C-compatible layouts explicitly; they do not infer a native ABI from a declaration name. See <doc:NativeValueAdapters> for custom value storage.

## Call a variadic function

Inside `.function(...)`, include every concrete argument in `as:` and set `variadicFrom:` to the zero-based index of the first anonymous argument. For `int printf(const char *format, ...)`, the fixed prefix has one parameter:

```swift
let printValue = try runtime.resolveAndWait(
    .c(.function("printf", as: ((UnsafePointer<CChar>, Float) -> Int32).self, variadicFrom: 1))
)
try "value: %.1f\n".withCString { format in
    _ = try unsafe printValue.unsafeInvoke(format, 1.5)
}
```

The backend applies C default argument promotions to the anonymous tail: Float becomes Double, and Bool, Int8, UInt8, Int16, and UInt16 become C int. Fixed arguments and other C-compatible values keep their declared representation. Match every tail argument to the consumer's format conversion or `va_arg` type.

For a `signature:` request, ``NativeSignature`` supplies the variadic boundary too. Its `parameters:` list describes the fixed prefix, and `variadicParameters:` describes this call's tail. An empty tail still denotes a variadic call; omitting it denotes a fixed declaration:

```swift
let signature = NativeSignature(
    parameters: [.pointer],
    variadicParameters: [.float],
    returns: .int32
)
let printValue = try runtime.resolveAndWait(.c(.function("printf", signature: signature)))
```

Reuse a handle for the same concrete tail; prepare another handle when its types or count change. The libffi path requires at least one fixed parameter. Native C++ `function<Signature>` wrappers use the consumer compiler's variadic function type directly. Callback entry also requires a known concrete tail, which cannot be inferred from an import name.

## Keep pointers and images alive

A function handle retains its resolved image and prepared signature. Clearing the runtime's cached indexes does not invalidate existing handles. To reuse an image explicitly:

```swift
let images = try runtime.resolveImagesAndWait(matching: .framework(named: "Example"))
if let image = images.first {
    let start = try runtime.resolveAndWait(
        .c(.function("ExampleStart", as: (() -> Void).self)),
        in: image
    )
    let stop = try runtime.resolveAndWait(
        .c(.function("ExampleStop", as: (() -> Void).self)),
        in: image
    )
}
```

Pointer arguments and results remain borrowed. Keep pointees alive and satisfy the native function's access and ownership requirements. A null return maps to an optional pointer or throws ``ABIInvocationError/unexpectedNilResult(expected:)`` for a nonoptional pointer type.

Handles are Sendable and can reuse their immutable signatures concurrently. Every call has separate argument and result storage, but the native function and supplied memory still determine whether concurrent invocation is valid. Call a thread-bound function on its required thread. Native C++ and Objective-C exceptions must not cross this invocation boundary.

## Express Core Foundation ownership

Use `Unmanaged<T>` for a native reference represented by a pointer. For example, a provider's `ExampleCopyValue` returning `CFTypeRef` at +1 can be called as follows:

```swift
let copy = try runtime.resolveAndWait(
    .c(.function("ExampleCopyValue", as: ((Unmanaged<CFString>) -> Unmanaged<CFString>).self))
)
let result = try unsafe copy.unsafeInvoke(.passUnretained(input)).takeRetainedValue()
```

Use `takeRetainedValue()` for a +1 result and `takeUnretainedValue()` for a borrowed result whose owner remains alive. ABIBridge passes the pointer bits without managing these references.

For a consumed input, `passRetained` creates a reference that transfers on native entry. Release it yourself if the call fails before entry. Finish other fallible argument conversions before creating it, or use a compiler adapter to manage ownership and errors together.
