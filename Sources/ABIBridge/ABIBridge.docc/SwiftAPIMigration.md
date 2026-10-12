# Migrating Swift calls and values

Update clients of the earlier result-and-argument handle types to complete function signatures, declaration-ordered generic arguments, and the shared runtime value interface.

## Choose synchronous or async lookup

Select lookup behavior by factory name. Async lookup prepares on a worker queue while the caller suspends; synchronous lookup appends `AndWait` and takes the same arguments:

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

Use `AndWait` without `await` for synchronous lookup, including inside an async function. It can block during cold lookup or while joining preparation. Bound member lookup keeps the receiver in the caller's isolation domain; see <doc:SwiftFunctionInvocation> and <doc:SwiftMemberInvocation>.

`ABIRuntime` and `NativeSwiftType` remain actors, and earlier preparation is optional. Remove `await` from raw symbol lookup, image enumeration, C/C++ factories, Objective-C selector lookup, and `removeCachedResults()`; those operations are synchronous.

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

Apply this change to `NativeSwiftMethod`, `NativeBoundSwiftMethod`, `NativeSwiftFunctionImplementation`, and `NativeSwiftMethodImplementation`. Replace separate async function/method handles and throwing/async/concurrent closure types with the corresponding handle and complete `Signature`. Include `@Sendable` for a native Sendable closure. Invocation can still throw bridge errors for a nonthrowing native declaration; native async signatures need `await`.

Replace a Swift getter's result metatype, such as `String.self`, with its zero-argument function metatype:

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

A `.type` can contain a retained ``NativeSwiftType`` when the concrete type is unavailable. Nominal lookup binds the enclosing context; member lookup supplies only its additional parameters. Existing metadata and conformances supply dependent types and witnesses.

Label-only names select a declaration whose bound signature matches `as:`. Keep a complete source declaration when selecting an exact overload or using a host adapter with a different Swift type name. `declaredAs:` supplies formal information missing from the binary, and `valueABIs:` supplies an established native convention for a closed runtime-only nominal value. Neither spelling permits guessing the ABI from metadata size. See <doc:GenericSwiftValues>.

## Use one owned runtime value type

Replace `NativeSwiftOpaqueValue` with ``NativeSwiftValue``. Its retained `type` supports identity, member lookup, and generic arguments; `type.name` gives the source name. Replace `withValue` with throwing `withCopy`, which exposes an `Any` copy and can report copy failure.

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

Assigning a runtime handle shares ownership. `copy()` creates an independent Copyable value; `take(as:)` moves an exact known type and consumes all aliases. Use `withBorrowedValue` for scoped access without copying. Ownership and image lifetime follow <doc:SwiftOpaqueResults>; the handle remains non-Sendable.

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

This nonthrowing callback reports bridge failures through the client's `report` function. Use a throwing signature if the provider supplies a matching error channel. Its resilient value uses formally indirect self, selected by `.opaque`.

Pass the callback using the provider's complete declaration and `valueABIs:` when its concrete nominal ABI is unavailable to the host. The ordinary member handle can also invoke on an owned ``NativeSwiftValue``. Borrowed views expire at callback completion; `copy()` creates an independent owner only for Copyable, Escapable payloads. See <doc:BorrowedSwiftValues>.

Use `NativeSwiftClosure<Signature>` inside the outer signature for nested native closures. Inputs are scoped borrows; call `copy()` on an active native `@escaping` input to keep it longer. Nonescaping inputs cannot retain a stack context. Ownership markers follow <doc:SwiftArgumentConventions>, and nested lifetimes follow <doc:SwiftClosureValues>.

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

Registrations apply to their bound types, and continuations expire at callback completion. Dispatch scope, ownership, and error recovery follow <doc:SwiftFunctionHooks> and <doc:SwiftMethodHooks>.

## See Also

- <doc:SwiftCalls>
- <doc:GenericSwiftValues>
- <doc:SwiftValues>
