# Migrating resolution, Swift calls, and values

Describe Swift and Objective-C declarations with requests, choose async or synchronous resolution explicitly, then update earlier Swift callable and value handles to complete signatures, declaration-ordered generic arguments, and the shared runtime value interface.

## Qualify Swift callable requests

Wrap each Swift callable declaration in `.swift(...)` when passing it to `resolve` or `resolveAndWait`:

| Before | After |
| --- | --- |
| `runtime.resolve(.function(n, as: s), in: scope)` | `runtime.resolve(.swift(.function(n, as: s)), in: scope)` |
| `type.resolve(.method(n, as: s))` | `type.resolve(.swift(.method(n, as: s)))` |
| `object.resolve(.getter(n, as: s))` | `object.resolve(.swift(.getter(n, as: s)))` |
| `type.resolve(.setter(n, as: s))` | `type.resolve(.swift(.setter(n, as: s)))` |
| `.initializer(…)`, `.staticMethod(…)`, `.staticGetter(…)`, `.staticSetter(…)` | Wrap the declaration in `.swift(...)` on a type or object |

The same change applies to synchronous `resolveAndWait`. Bare Swift declaration requests are no longer accepted by the resolvers. Their factories remain the inner declarations, with `as:`, `genericArguments:`, `declaredAs:`, `valueABIs:`, and receiver options in the same places. Image scope and loading policy stay on the resolver.

For a saved request, use ``NativeRequest`` and let its declaration and signature types be inferred:

```swift
let request = NativeRequest.swift(.function(
    "Example.decorate(_:)", as: ((String) -> String).self
))
let decorate = try await runtime.resolve(
    request, in: .framework(named: "Example")
)
let message = try unsafe decorate.unsafeInvoke("Hello")
```

Replace saved values constructed as `NativeSwiftFunctionRequest<Signature>.function(...)`, `NativeSwiftInstanceMemberRequest<Signature>.method(...)`, or `NativeSwiftTypeMemberRequest<Signature>.initializer(...)` with `NativeRequest.swift(...)` around the same inner declaration. The wrapper is a value type and is `Sendable` when its declaration is `Sendable`. Creating it performs no lookup or ABI preparation. Resolve it on the same destinations as before: free functions on `ABIRuntime`, and member requests on `NativeSwiftType` or `NativeObject`. A type yields an explicit-receiver member handle; an object binds its receiver.

Prepared handle types, invocation, ownership, error propagation, and async isolation keep their existing contracts. Requests have no public `Hashable` conformance and do not automatically cache returned handles. Retain a prepared handle for repeated calls; existing cache controls are described in <doc:SymbolLookup#Cache-and-loader-lifetime>.

## Qualify Objective-C callable requests

Replace `.message(...)` with `.objc(.method(...))` for ordinary message dispatch, and `.implementation(...)` with `.objc(.imp(...))` for a captured implementation:

| Before | After |
| --- | --- |
| `runtime.resolve(.message(s, as: t), on: c)` | `runtime.resolve(.objc(.method(s, as: t)), on: c)` |
| `object.resolveAndWait(.message(s, as: t))` | `object.resolveAndWait(.objc(.method(s, as: t)))` |
| `runtime.resolve(.implementation(s, as: t), on: c)` | `runtime.resolve(.objc(.imp(s, as: t)), on: c)` |
| `NativeObjCMessageRequest<R, A>.message(s, as: t)` | `NativeRequest.objc(.method(s, as: t))` |
| `NativeObjCImplementationRequest<R, A>.implementation(s, as: t)` | `NativeRequest.objc(.imp(s, as: t))` |

The concrete declaration types remain ``NativeObjCMessageRequest`` and ``NativeObjCImplementationRequest``. Their factories are now `method` and `imp`, respectively, and their wrapped requests resolve with either `resolve` or `resolveAndWait`. `String` and `Selector` overloads, native error conversion through a `throws` signature, ownership options, and typed variadic arguments retain their existing contracts. Keep `as:`, `variadicFrom:`, and `options:` inside the declaration; keep `on:`, `classMethod:`, and `retaining:` on runtime resolution.

A method request resolves on `ABIRuntime` with a class for an explicit receiver at invocation, or on `NativeObject` for a bound receiver. An IMP request resolves on `ABIRuntime` with a class and captures the implementation at that resolution. See <doc:ObjectiveCInvocation> for saved request examples, forwarding, and receiver isolation. Hook request APIs such as `NativeObjCHookRequest.method(...)` retain their own spelling.

## Qualify C and C++ function requests

Replace C and C++ free-function factories with `resolve` or `resolveAndWait` and a language-qualified request:

| Before | After |
| --- | --- |
| `runtime.resolveCFunction(named: n, as: t, variadicFrom: v, in: scope, loading: l)` | `runtime.resolve(.c(.function(n, as: t, variadicFrom: v)), in: scope, loading: l)` |
| `runtime.resolveCXXFunction(named: n, as: t, variadicFrom: v, in: scope, loading: l)` | `runtime.resolve(.cxx(.function(n, as: t, variadicFrom: v)), in: scope, loading: l)` |
| `runtime.resolveCFunctionAndWait(named: n, signature: s, in: image)` | `runtime.resolveAndWait(.c(.function(n, signature: s)), in: image)` |
| `runtime.resolveCXXFunctionAndWait(named: n, signature: s, in: image)` | `runtime.resolveAndWait(.cxx(.function(n, signature: s)), in: image)` |

The same mapping applies to both scope overloads (`ImageSelector` and `NativeImage`), to typed and dynamic signatures, and to synchronous `AndWait` or async resolution. The old per-language callable factories are removed without compatibility aliases. C++ static functions also use `.cxx(.function(...))` without a receiver.

Move `named:` to the inner factory's unlabeled name. Keep `as:` and typed `variadicFrom:` inside `.function`, or use `signature:` with a `NativeSignature` that already includes its dynamic variadic boundary. Keep `in:` and `loading:` outside the request. The default scope remains `.automatic` and loading remains `.ifNeeded`.

Save declarations with `NativeRequest.c(.function(...))` or `NativeRequest.cxx(.function(...))`; see <doc:CFunctionInvocation> for typed and dynamic examples. Request construction performs no lookup, loading, or layout validation. `as:` still yields `NativeFunction<Result, each Argument>` and `signature:` yields `DynamicNativeFunction`. Native invocation, argument promotions, image retention, pointer ownership, errors, and caller execution requirements keep their existing contracts.

## Migrate earlier per-kind resolution functions

Swift functions and members and Objective-C messages are described by request values and prepared by one `resolve` and `resolveAndWait` pair. The per-kind functions, such as `resolveGetter`, `resolveStaticMethod`, `resolveSwiftFunction`, and `resolveObjCMethod`, are removed without compatibility aliases. Requests keep their declaration options separate from their resolution destination. A Swift member request resolves on a ``NativeSwiftType`` or a ``NativeObject`` with the same options:

| Before | After |
| --- | --- |
| `runtime.resolveSwiftFunction(named: n, as: s, …, in: scope, loading: l)` | `runtime.resolve(.swift(.function(n, as: s, …)), in: scope, loading: l)` |
| `type.resolveMethod(named: n, as: s, …)` | `type.resolve(.swift(.method(n, as: s, …)))` |
| `type.resolveGetter(named: n, as: s, …)` | `type.resolve(.swift(.getter(n, as: s, …)))` |
| `type.resolveSetter(named: n, as: V.self, …)` | `type.resolve(.swift(.setter(n, as: ((V) -> Void).self, …)))` |
| `type.resolveMethod(named: "….subscript.getter : …", …)` | `type.resolve(.swift(.getter("subscript", …)))`, or the same complete name |
| `type.resolveInitializer(named: n, as: s, …)` | `type.resolve(.swift(.initializer(n, as: s, …)))` |
| `type.resolveStaticMethod`, `resolveStaticGetter`, `resolveStaticSetter` | `type.resolve(.swift(.staticMethod(…)))`, `.swift(.staticGetter(…))`, `.swift(.staticSetter(…))` |
| `object.resolveMethod(named:)`, `resolveGetter`, `resolveSetter` | `object.resolve(.swift(.method(…)))`, `.swift(.getter(…))`, `.swift(.setter(…))` |
| `mutating: true`, `consuming: true` | `receiver: .mutating`, `receiver: .consuming` |
| `mutating: false` on a setter | `receiver: .borrowing` |
| `runtime.resolveObjCMethod(on: c, selector: s, as: t, variadicFrom: v, classMethod: m, options: o, retaining: w)` | `runtime.resolve(.objc(.method(s, as: t, variadicFrom: v, options: o)), on: c, classMethod: m, retaining: w)` |
| `runtime.resolveObjCImplementation(on: c, selector: s, …)` | `runtime.resolve(.objc(.imp(s, …)), on: c, …)` |
| `object.resolveMethod(selector: s, as: t, …)` | `object.resolve(.objc(.method(s, as: t, …)))` |

Each `…AndWait` function becomes `resolveAndWait` with the same request. The handles they return are unchanged.

```swift
// Before
let read = try type.resolveMethodAndWait(named: "read()", as: (() -> Int64).self)
let setText = try runtime.object(renderer).resolveSetterAndWait(named: "text", as: String.self)

// After
let read = try type.resolveAndWait(.swift(.method("read()", as: (() -> Int64).self)))
let setText = try runtime.object(renderer).resolveAndWait(
    .swift(.setter("text", as: ((String) -> Void).self))
)
```

What changes besides the spelling:

- A setter request takes the complete function type of the call, `(Value) -> Void`, like every other member. A subscript setter takes the new value followed by the indices.
- An object accepts `valueABIs:`, `receiverABI:`, and `receiver:` as its type does, and resolves initializer and static member requests for its own type.
- A subscript's accessors are `getter` and `setter` requests for the member named `subscript`, selected by their index and value types, or by a complete accessor declaration as before. Getter and setter requests accept `genericArguments:` for generic subscripts.
- The request states the member's role. A method request whose name spells an accessor, such as `subscript.getter : (Swift.Int) -> Swift.String`, reports ``ABIResolutionError/unsupportedDeclaration(_:)``; pass that name to the matching getter or setter request.
- ``NativeSwiftReceiverConvention`` replaces the `mutating:` and `consuming:` flags, whose combination was invalid. Without a convention, methods and getters borrow `self` and setters follow their declaration.
- Throwing Objective-C messages and implementations also accept a `Selector`.

C++ instance and virtual members, Swift types, images, and value conversions keep their `resolve…` names.

## Choose synchronous or async lookup

Functions named `resolve…` perform search and call preparation on a worker while the caller suspends. Their synchronous `AndWait` counterparts take the same arguments and can block the caller. Both work without `prepare` and join only required preparation already in progress:

| Operation | Async | Synchronous |
| --- | --- | --- |
| Raw symbol or symbol request batch | `resolve` | `resolveAndWait` |
| Swift function, member, initializer, or static member request | `resolve` | `resolveAndWait` |
| Objective-C message or implementation request | `resolve` | `resolveAndWait` |
| Loaded images | `resolveImages` | `resolveImagesAndWait` |
| Lazy-library metadata | `resolveLazyLibraries` | `resolveLazyLibrariesAndWait` |
| C function request (`.c(.function(...))`) | `resolve` | `resolveAndWait` |
| C++ function request (`.cxx(.function(...))`) | `resolve` | `resolveAndWait` |
| Swift type | `resolveSwiftType` | `resolveSwiftTypeAndWait` |
| C++ instance method | `resolveMethod` | `resolveMethodAndWait` |
| C++ virtual method | `resolveVirtualMethod` | `resolveVirtualMethodAndWait` |
| Named C++ virtual-table entry | `resolveEntry` | `resolveEntryAndWait` |
| Swift enum payload | `resolveEnumPayload` | `resolveEnumPayloadAndWait` |
| Stored Swift closure | `resolveClosure` | `resolveClosureAndWait` |
| Compiled Swift virtual replacement plan | `prepareVirtualReplacement` | `prepareVirtualReplacementAndWait` |
| Compiled Swift imported replacement plan | `prepareImportedReplacement` | `prepareImportedReplacementAndWait` |

Compiled replacement planning follows the same suffix rule. Rename earlier synchronous `prepareVirtualReplacement` calls to `prepareVirtualReplacementAndWait`, or add `await` to prepare on a worker. `prepareImportedReplacementAndWait` adds synchronous planning alongside the async factory. These methods create uninstalled plans; publication and restoration remain explicit synchronous operations. See <doc:SwiftVirtualReplacements> and <doc:SwiftImportedReplacements>.

For async type and method lookup:

```swift
let type = try await runtime.resolveSwiftType(named: "Example.Counter")
let read = try await type.resolve(.swift(.method("read()", as: (() -> Int64).self)))
```

Use `resolveAndWait` without `await` for synchronous lookup, including inside an async function. It can block during cold lookup or while joining preparation. Bound member lookup keeps the receiver in the caller's isolation domain; see <doc:SwiftFunctionInvocation> and <doc:SwiftMemberInvocation>.

`ABIRuntime` and `NativeSwiftType` remain actors. Replace earlier C/C++ `cFunction`, `cxxFunction`, `resolveCFunction`, and `resolveCXXFunction` factories with `.c(.function(...))` and `.cxx(.function(...))` requests passed to `resolve` or `resolveAndWait`. The same rename applies to `images`, `lazyLibraries`, C++ `method` and `virtualMethod`, and named vtable `entry`. Earlier `objcMethod`, `objcImplementation`, and Objective-C `method(selector:)` calls become `.objc(.method(...))` or `.objc(.imp(...))` requests. Earlier synchronous raw `resolve` calls become `resolveAndWait`, or add `await` to use async resolution. The old factory names have no compatibility aliases.

For C or C++ lookup from `MainActor`, call the async factory directly:

```swift
@MainActor
func calculate() async throws -> Int32 {
    let add = try await ABIRuntime.shared.resolve(
        .cxx(.function("Example::Math::add(int, int)", as: ((Int32, Int32) -> Int32).self)),
        in: .framework(named: "Example")
    )
    return try unsafe add.unsafeInvoke(20, 22)
}
```

Resolution suspends for search, loading, and ABI preparation. It does not change the invocation's execution requirements. Bound Objective-C resolution keeps receiver-specific dynamic resolution and forwarding-signature callbacks on the caller's executor; its image and call preparation run on the worker.

Optional `prepare(_:)` remains asynchronous. Use synchronous `AndWait` functions inside its closure to prepare known requirements ahead of time:

```swift
async let prepared = runtime.prepare { runtime in
    try runtime.resolveAndWait(
        .cxx(.function("Example::Math::add(int, int)", as: ((Int32, Int32) -> Int32).self)),
        in: .framework(named: "Example")
    )
}
let add = try await runtime.resolve(
    .cxx(.function("Example::Math::add(int, int)", as: ((Int32, Int32) -> Int32).self)),
    in: .framework(named: "Example")
)
_ = try await prepared
```

The closure and its result must be Sendable. Use the same runtime so lookup shares indexes and call interfaces with preparation; it joins required work without waiting for the whole closure. See <doc:SymbolLookup>.

`object`, `cxxObject`, `bind`, and explicit `entry(at:authentication:)` create views or bindings without search or ABI preparation and remain synchronous. Memory reads, value copies, and `removeCachedResults()` also remain synchronous. Keep `await` for invoking native async signatures and for hook installation APIs that are asynchronous.

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

Apply this change to `NativeSwiftMethod`, `NativeBoundSwiftMethod`, `NativeSwiftFunctionImplementation`, and `NativeSwiftMethodImplementation`. Replace separate async function/method handles and throwing/async/concurrent closure types with the corresponding handle and complete `Signature`. Include `@Sendable` for a native Sendable closure. Lookup compares these effects with the native declaration and reports a difference as ``ABIResolutionError/signatureMismatch(_:)``. Invocation can still throw bridge errors for a nonthrowing native declaration; native async signatures need `await`.

Replace a Swift getter's result metatype, such as `String.self`, with its zero-argument function metatype:

```swift
let getter = try await type.resolve(.swift(.getter("text", as: (() -> String).self)))
```

Keep Objective-C selector lookup on its existing function-type interface. This getter change applies to Swift source declarations.

## Bind all declared generic parameters

Replace `substituting:` with `genericArguments:`. Each declared scalar parameter takes one `.type` argument; each declared type pack takes one `.pack` argument.

```swift
let run = try await runtime.resolve(.swift(.function(
    "Example.run(_:)",
    as: ((NativeSwiftClosure<() -> String>) -> String).self,
    genericArguments: [.type(String.self)]
)))
let callback = try NativeSwiftClosure<() -> String> { "value" }
let result = try unsafe run.unsafeInvoke(callback)
```

A `.type` can contain a retained ``NativeSwiftType`` when the concrete type is unavailable. Nominal lookup binds the enclosing context; member lookup supplies only its additional parameters. A different number of arguments reports ``ABIResolutionError/signatureMismatch(_:)`` with the expected count. Existing metadata and conformances supply dependent types and witnesses.

Label-only names select a declaration whose bound signature matches `as:`. Keep a complete source declaration when selecting an exact overload or using a host adapter with a different Swift type name. `declaredAs:` supplies formal information missing from the binary, and `valueABIs:` supplies an established native convention for a closed runtime-only nominal value. Neither spelling permits guessing the ABI from metadata size. See <doc:GenericSwiftValues>.

## Use one owned runtime value type

Replace `NativeSwiftOpaqueValue` with ``NativeSwiftValue``. Its retained `type` supports identity, member lookup, and generic arguments; `type.name` gives the source name. Replace `withValue` with throwing `withCopy`, which exposes an `Any` copy and can report copy failure.

```swift
let make = try await runtime.resolve(.swift(.function(
    "Example.makeSummary(_:)",
    as: ((String) -> NativeSwiftValue).self
)))
let value = try unsafe make.unsafeInvoke("title")
let type = value.type
print(type.name)
try value.withCopy { print($0) }
```

Assigning a runtime handle shares ownership. `copy()` creates an independent Copyable value; `take(as:)` moves an exact known type and consumes all aliases. Use `withBorrowedValue` for scoped access without copying. Ownership and image lifetime follow <doc:SwiftOpaqueResults>; the handle remains non-Sendable.

## Replace separate borrowed callback and member families

Use ``NativeSwiftClosure`` with ``NativeSwiftBorrowedValue`` in its signature instead of `NativeSwiftBorrowingClosure`. Prepare ordinary members instead of `borrowedMethod` or `borrowedGetter`:

```swift
let read = try await type.resolve(.swift(.method(
    "read()", as: (() -> Int64).self,
    receiverABI: .opaque(named: type.name)
)))
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
let run = try await runtime.resolve(.swift(.function(
    "Example.runAsync(_:)",
    as: (nonisolated(nonsending) (String) async throws -> String).self
)))
let result = try unsafe await run.unsafeInvoke("value")
```

Typed errors remain part of the signature, such as `(String) throws(MyError) -> String`. Native failures arrive as ``NativeSwiftError`` with the original underlying error. No isolation setting can be inferred from the result type or the current thread. See <doc:SwiftAsyncABI> and <doc:SwiftErrorABI>.

## Keep nonescapable results inside their invocation

An owned result cannot represent a native `~Escapable` payload. Select ``NativeSwiftBorrowedValue`` as the result marker and process it in `withResult:`:

```swift
let make = try runtime.resolveAndWait(.swift(.function(
    "Example.makeView(_:)",
    as: ((AnyObject) -> NativeSwiftBorrowedValue).self
)))
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
