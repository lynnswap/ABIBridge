# Passing inout and owned Swift arguments

Describe each native Swift parameter's convention with a typed argument wrapper. Synchronous and async function, method, and initializer lookups use the same wrappers.

## Mutate a typed buffer

For a native declaration `@concurrent func append(_ text: inout String, _ suffix: consuming String) async throws`:

```swift
let append = try await ABIRuntime.shared.swiftFunction(
    named: "Example.append(_:_:)",
    as: (@concurrent (NativeSwiftInout<String>, NativeSwiftConsuming<String>) async throws -> Void).self
)
let text = try NativeSwiftInout("Hello")
try unsafe await append.unsafeInvoke(text, .init("!"))
print(text.value)
```

Match the async isolation convention to the native declaration, as described in <doc:SwiftAsyncABI>.

The buffer owns actual Swift storage and keeps it alive through native completion. Its value can be read or replaced between invocations. It does not assign back to the variable used to initialize it. A throwing or cancelled call preserves mutations that the native body already made.

Native code has exclusive access for the entire invocation, including suspension. Do not read, write, or pass an alias to the same buffer during that interval. NativeSwiftInout is deliberately not Sendable; the caller must preserve this exclusivity when invoking an unsafe native entry. The buffer is not a synchronization primitive.

## Choose ownership per parameter

| Signature argument | Native convention |
| --- | --- |
| T | Borrowed for ordinary functions/methods; owned for allocating initializers and setters |
| NativeSwiftBorrowing<T> | Borrowed; bridge storage remains owned until completion |
| NativeSwiftConsuming<T> | Native code receives an independently encoded owned copy |
| NativeSwiftInout<T> | Exclusive address of the buffer's actual Swift value |

The original value inside NativeSwiftConsuming remains usable. Native code consumes its copy on both normal and throwing completion. If argument conversion fails before entry, the bridge releases all prepared copies itself.

For a native initializer `init(_ title: borrowing String, _ content: consuming String)`:

```swift
let type = try await ABIRuntime.shared.swiftType(named: "Example.Document")
let initialize = try await type.initializer(
    named: "init(_:_:)",
    as: ((NativeSwiftBorrowing<String>, NativeSwiftConsuming<String>) -> AnyObject).self
)
let document = try unsafe initialize.unsafeInvoke(.init("Title"), .init("Contents"))
```

Label-only lookup derives demangled conventions from these wrapper types and the entry's defaults. A complete source declaration can be supplied for a foreign type name, but it does not infer or override ownership: the caller must still select matching wrappers. Symbol lookup cannot prove that a supplied signature matches the native implementation.

Explicit arguments are independent of a method receiver's mutating or consuming convention. A mutating receiver continues to use `unsafeInvoke(on: &receiver, ...)`.

## Representation and scope

Inout buffers support the existing actual Swift value representations, including String, Array, supported Optionals, class references, and values described with ABIBridgeSwiftValue. Borrowing uses the underlying value codec. Consuming requires Swift-owned copying and destruction; foreign ABIBridgeValue conversions alone do not establish that contract. See <doc:ExplicitSwiftValues>.

The wrappers describe arguments to native entries. They are not result representations or callback-body parameters for managed hooks and generated closures. Closure-value wrappers do not expose actual Swift closure storage suitable for an inout pointee. Noncopyable values and generic declarations with hidden metadata/witness arguments require a compiled adapter.

The compiler fixtures verify guaranteed, owned, and inout conventions on arm64, x86_64, arm64e, and arm64_32. Runtime tests cover independent copies, managed and scalar writeback, throwing completion, later argument-conversion failure, mixed initializer ownership, mutating receivers, and suspension/cancellation.
