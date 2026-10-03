# Passing inout and owned Swift arguments

Describe each native Swift parameter's convention with a typed argument wrapper. Synchronous and async function, method, and initializer lookups use the same wrappers.

## Mutate a typed buffer

For a native declaration `@concurrent func append(_ text: inout String, _ suffix: consuming String) async throws`:

```swift
let append = try await ABIRuntime.shared.swiftFunction(
    named: "Example.append(_:_:)",
    as: (@concurrent (NativeSwiftInout<String>, NativeSwiftConsuming<String>) async throws -> Void).self
)
let text = NativeSwiftInout("Hello")
try unsafe await append.unsafeInvoke(text, .init("!"))
print(text.value)
```

Match the async isolation convention to the native declaration, as described in <doc:SwiftAsyncABI>.

The buffer owns its host value and keeps it alive through native completion. Its value can be read or replaced between invocations. It does not assign back to the variable used to initialize it. A throwing or cancelled call preserves mutations that the native body already made; converted buffers follow the writeback contract below.

Native code has exclusive access for the entire invocation, including suspension. Do not read, write, or pass an alias to the same buffer during that interval. NativeSwiftInout is deliberately not Sendable; the caller must preserve this exclusivity when invoking an unsafe native entry. The buffer is not a synchronization primitive.

## Choose ownership per parameter

| Signature argument | Native convention |
| --- | --- |
| T | Borrowed for ordinary functions/methods; owned for allocating initializers and setters |
| NativeSwiftBorrowing<T> | Borrowed; bridge storage remains owned until completion |
| NativeSwiftConsuming<T> | Native code receives ownership of the encoded value |
| NativeSwiftInout<T> | Exclusive mutable access, with temporary native storage when conversion is needed |

Ordinary Swift values supply an independently encoded copy, so the original value remains usable. A `NativeSwiftValue` transfers its native payload and becomes consumed after invocation; the same rule applies to runtime handles inside a consuming tuple. Native code owns transferred values on both normal and throwing completion. If argument conversion fails before entry, the bridge releases prepared copies and leaves pending runtime transfers in their existing owners.

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

## Replace a closure or tuple

For `func replaceCallback(_ callback: inout (Int64) -> Int64)`, put the closure handle in an ordinary inout buffer:

```swift
typealias Callback = NativeSwiftClosure<(Int64) -> Int64>
let initial = try NativeSwiftClosure { (value: Int64) in value + 7 }
let callback = NativeSwiftInout(initial)
let replace = try await ABIRuntime.shared.swiftFunction(
    named: "Example.replaceCallback(_:)",
    as: ((NativeSwiftInout<Callback>) -> Void).self
)
try unsafe replace.unsafeInvoke(callback)
let result = try unsafe callback.value.unsafeInvoke(35)
```

Use `NativeSwiftInout<Snapshot>` in the same way when `Snapshot` is an ordinary tuple containing runtime value or closure handles. The bridge prepares the native pointee before invocation and replaces the buffer's host value after native completion. If a runtime field has a different type name from its host handle, supply the complete native declaration, as shown in <doc:SwiftClosureValues>.

After the native body runs, the bridge prepares updated host values for all converted inout arguments before replacing any of those buffers. If one conversion fails, those converted buffers keep their previous host values. Native side effects and changes to directly accessed storage remain in place. Writeback runs when the native body throws and when result decoding fails. A conversion failure before native entry does not run writeback.

If invocation or result conversion and writeback both fail, ``NativeSwiftWritebackError`` retains the errors in `invocationError` and `writebackError`. If only writeback fails, that error is thrown directly.

## Write back callback inputs

A `NativeSwiftInout<Value>` callback parameter gives the body an owned local buffer. Its current value is written back before the callback completes, including throwing or async completion. Saving that buffer keeps an independent host value after completion. A runtime-only native `inout` parameter can instead use `NativeSwiftBorrowedValue` to grant scoped mutation access; see <doc:BorrowedSwiftValues>.

A callback that writes back a converted closure or tuple uses `throws(any Error)`. The bridge prepares all converted replacements before changing the native arguments and transfers the callback result only after writeback succeeds. If input conversion fails before the body starts, no inout writeback runs. Ordinary typed inout values and tuples without converted fields keep their declared nonthrowing or typed-error contract.

## Representation and scope

An inout buffer stores its host value using that value's Swift representation. Creating the buffer does not prepare a native call. Preparation selects direct access or the closure/runtime-value conversion required by the declaration. A generic parameter bound to a bridge wrapper, including a tuple of wrappers, uses those wrappers as ordinary Swift data. Their conversion to other native types is not applied. Borrowing and consuming follow the same declaration contract; see <doc:GenericSwiftValues> and <doc:ExplicitSwiftValues>.

Ownership wrappers describe callable parameters. Use ordinary value or closure representations for results. Managed hooks have their own argument contract in <doc:HookArguments>. Runtime-only values, including standalone noncopyable payloads, use the ownership rules in <doc:BorrowedSwiftValues> and <doc:SwiftOpaqueResults>.

The compiler fixtures verify guaranteed, owned, and inout conventions on arm64, x86_64, arm64e, and arm64_32. Runtime tests cover independent copies, managed and scalar writeback, throwing completion, later argument-conversion failure, mixed initializer ownership, mutating receivers, and suspension/cancellation.
