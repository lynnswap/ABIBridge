# Migrating Swift calls and values

Update clients of the earlier result-and-argument handle types to complete function signatures, declaration-ordered generic arguments, and the shared runtime value interface.

## Choose synchronous or async lookup

Choose async lookup or synchronous waiting by the factory name. Async factories search and prepare on a worker queue while the caller suspends; synchronous factories use the same arguments and append `AndWait` to the name:

| Lookup | Async factory | Synchronous factory |
| --- | --- | --- |
| Swift function | `resolveSwiftFunction` | `resolveSwiftFunctionAndWait` |
| Swift type | `resolveSwiftType` | `resolveSwiftTypeAndWait` |
| Instance method | `resolveMethod` | `resolveMethodAndWait` |
| Initializer | `resolveInitializer` | `resolveInitializerAndWait` |
| Static method | `resolveStaticMethod` | `resolveStaticMethodAndWait` |
| Instance getter | `resolveGetter` | `resolveGetterAndWait` |
| Instance setter | `resolveSetter` | `resolveSetterAndWait` |
| Static getter | `resolveStaticGetter` | `resolveStaticGetterAndWait` |
| Static setter | `resolveStaticSetter` | `resolveStaticSetterAndWait` |

For async type and method lookup:

```swift
let type = try await runtime.resolveSwiftType(named: "Example.Counter")
let read = try await type.resolveMethod(named: "read()", as: (() -> Int64).self)
```

Use `AndWait` without `await` to choose synchronous lookup, including inside async functions. Cold lookup runs on the caller's thread; if a required preparation stage is running, the caller waits for it. Bound object method, getter, and setter lookup keeps the receiver in the caller's isolation domain. See <doc:SwiftFunctionInvocation> and <doc:SwiftMemberInvocation>.

`ABIRuntime` and `NativeSwiftType` remain actors. Earlier preparation is optional for both lookup forms, and both share symbol indexes and prepared call interfaces. Raw symbol lookup, image enumeration, C/C++ factories, Objective-C selector lookup, and `removeCachedResults()` are synchronous; remove `await` from those operations.

Optional `prepare(_:)` remains asynchronous. Its closure overload runs synchronous factories on a worker queue and shares their preparation with later lookup. See <doc:SymbolLookup>. Keep `await` for invoking native async signatures and for hook installation APIs that remain asynchronous.

## Use a complete callable signature

The function type now carries arguments, results, native errors, and async isolation. Replace explicit annotations using the earlier result and argument parameters:

```swift
// Before
let function: NativeSwiftFunction<String, Int64>
let callback: NativeSwiftClosure<String>

// After
let function: NativeSwiftFunction<(Int64) -> String>
let callback: NativeSwiftClosure<() -> String>
```

Apply the same change to `NativeSwiftMethod`, `NativeBoundSwiftMethod`, and returned closures. The separate throwing and async closure types have been removed; use `NativeSwiftClosure<Signature>` with the native effects in `Signature`. Invocation remains throwing for bridge failures, even when the native declaration is nonthrowing. Async signatures use `await`.

Swift getters now take a zero-argument function type in place of the earlier result type, such as `String.self`, so their error and isolation contracts remain visible:

```swift
let getter = try await type.resolveGetter(named: "text", as: (() -> String).self)
```

Keep Objective-C selector lookup on its existing function-type interface. This getter change applies to Swift source declarations.

## Bind all declared generic parameters

Replace `substituting:` with `genericArguments:`. Each declared scalar parameter takes one `.type` argument; each declared type pack takes one `.pack` argument.

```swift
let run = try await runtime.resolveSwiftFunction(
    named: "Example.run(_:)",
    as: ((NativeSwiftClosure<() -> String>) -> String).self,
    genericArguments: [.type(String.self)]
)
let callback = try NativeSwiftClosure<() -> String> { "value" }
let result = try unsafe run.unsafeInvoke(callback)
```

A `.type` can also contain a retained ``NativeSwiftType`` when the consumer cannot import the concrete type. Nominal type lookup binds the enclosing context; member lookup supplies only that member's additional arguments. Existing native metadata and conformances determine substitutions, dependent types, and witnesses. Consumers do not construct witness tables.

Label-only names select a declaration whose bound signature matches `as:`. Keep a complete source declaration when selecting an exact overload or using a host adapter with a different Swift type name. `declaredAs:` supplies formal information missing from the binary, and `valueABIs:` supplies an established native convention for a closed runtime-only nominal value. Neither spelling permits guessing the ABI from metadata size. See <doc:GenericSwiftValues>.

## Use one owned runtime value type

Replace `NativeSwiftOpaqueValue` with ``NativeSwiftValue``. Use its public `type` handle for type identity, member lookup, and generic arguments, and `type.name` for the source-level name. The handle retains the type's implementation images. The earlier `withValue` operation made an `Any` copy; its replacement, `withCopy`, can report an invalid copy.

```swift
let make = try await runtime.resolveSwiftFunction(
    named: "Example.makeSummary(_:)",
    as: ((String) -> NativeSwiftValue).self
)
let value = try unsafe make.unsafeInvoke("title")
let type = value.type
print(type.name)
try value.withCopy { print($0) }
```

The same owner receives ordinary generic and opaque results. Assigning it shares ownership; `copy()` creates an independent native copy when the payload permits copying. `take(as:)` moves an exact known payload and consumes all aliases. Use `withBorrowedValue` to inspect a noncopyable value without making an `Any` copy. These handles retain implementation images but do not make a hidden payload Sendable.

## Replace separate borrowed callback and member families

Use ``NativeSwiftClosure`` with ``NativeSwiftBorrowedValue`` in its signature instead of `NativeSwiftBorrowingClosure`. Prepare ordinary members instead of `borrowedMethod` or `borrowedGetter`:

```swift
let read = try await type.resolveMethod(
    named: "read()", as: (() -> Int64).self,
    receiverABI: .opaque(named: type.name)
)
let callback = try NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Int64> { view in
    do { return try unsafe read.unsafeInvoke(on: view) }
    catch { report(error); return 0 }
}
```

This example preserves a nonthrowing provider callback and reports bridge failures through the client's `report` function. A provider with a matching native error channel can instead use a throwing callback signature. The explicit opaque receiver convention applies to this example's formally indirect resilient value.

Pass the callback using the provider's complete declaration and `valueABIs:` when its concrete nominal ABI is unavailable to the host. The ordinary member handle can also invoke on an owned ``NativeSwiftValue``. Borrowed views expire at callback completion; `copy()` creates an independent owner only for Copyable, Escapable payloads. See <doc:BorrowedSwiftValues>.

Nested native closures now appear as `NativeSwiftClosure<Signature>` arguments or results inside the outer signature. Incoming nonescaping closures remain scoped borrows. Copy a native `@escaping` input while its borrow is active if it must outlive the callback; saving a nonescaping input does not retain its stack context. Use ``NativeSwiftBorrowing``, ``NativeSwiftConsuming``, and ``NativeSwiftInout`` according to the provider's parameter conventions. See <doc:SwiftClosureValues> and <doc:SwiftArgumentConventions>.

## Keep isolation in the function type

Replace the earlier `inheritsCallerIsolation: false` setting with an `@concurrent` signature for a concurrent native async declaration. Use `nonisolated(nonsending)` for a caller-isolated declaration, including when the consumer's default differs from the provider's:

```swift
let run = try await runtime.resolveSwiftFunction(
    named: "Example.runAsync(_:)",
    as: (nonisolated(nonsending) (String) async throws -> String).self
)
let result = try unsafe await run.unsafeInvoke("value")
```

Typed errors remain part of the signature, such as `(String) throws(MyError) -> String`. Native failures arrive as ``NativeSwiftError`` with the original underlying error. No isolation setting can be inferred from the result type or the current thread. See <doc:SwiftAsyncABI> and <doc:SwiftErrorABI>.

## Keep nonescapable results inside their invocation

An owned result cannot represent a native `~Escapable` payload. Select ``NativeSwiftBorrowedValue`` as the result marker and process it in `withResult:`:

```swift
let make = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.makeView(_:)",
    as: ((AnyObject) -> NativeSwiftBorrowedValue).self
)
let number = try unsafe make.unsafeInvoke(owner, withResult: { view in
    try unsafe read.unsafeInvoke(on: view)
})
```

Prepare the matching member handle before invoking `make`. The invocation retains inputs and its receiver through the body, expires the view, destroys the native result, and completes writeback. Async signatures accept an async body. Return an Escapable value from that body; keeping the view does not preserve native access. See <doc:SwiftOpaqueResults>.

## Use complete signatures in hook continuations

Imported and virtual Swift hooks use `NativeSwiftFunctionInvocation<Signature>` and `NativeSwiftMethodInvocation<Signature>`. Their continuations preserve the declaration's generic bindings, native error convention, and async task. Use `try call.proceed(...)` for sync entries and `try await call.proceed(...)` for async entries.

Each registration applies to its bound types; unrelated substitutions continue through the captured native chain. A continuation expires when its callback returns. Hook bodies follow the native declaration's ownership and error contract, while `onFailure` handles errors that its native channel cannot represent. See <doc:SwiftFunctionHooks> and <doc:SwiftMethodHooks>.

The interception mechanism keeps its actual reach: imports and metadata slots can be hooked when publication is permitted; direct, inlined, or devirtualized calls can bypass them. A unified signature does not change that dispatch behavior.

## See Also

- <doc:SwiftCalls>
- <doc:GenericSwiftValues>
- <doc:SwiftValues>
