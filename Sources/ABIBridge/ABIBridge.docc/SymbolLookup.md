# Resolving symbols and retaining images

Resolve a declaration in a selected image and keep its code or data alive while using it.

## Choose a search scope

The default automatic scope of ``ABIRuntime`` searches images already loaded in the process. Explicit framework, executable-path, and install-name scopes acquire their target by default. Use `loading: .loadedOnly` to keep lookup from requesting loading or initialization. See <doc:ImageLoading> for dyld path rules and ownership.

```swift
let runtime = ABIRuntime()
let images = try runtime.resolveImagesAndWait(
    matching: .framework(named: "Foundation")
)
```

Enumeration includes only loaded images that can currently be retained. dyld can register an image before its initializers finish; another thread may temporarily exclude it, while explicit selection reports `ABIResolutionError.imageUnavailable`. An empty list means no matching image is currently available, even if a later resolution request could acquire one.

A `NativeImage` retains its loaded image. Reuse that handle to resolve several declarations in the same scope. The runtime caches raw symbol data and decoded declaration indexes; C++ members with a plain qualified owner reuse that owner's index.

Lookup automatically prepares its indexes, and callable factories return handles ready for invocation. Synchronous `AndWait` factories are `nonisolated` on `ABIRuntime` and `NativeSwiftType`: they perform missing work or block while required preparation finishes, including on `MainActor`.

Factories named `resolve…` perform symbol, image, function, type, and member lookup on a worker queue while the caller suspends. Their `AndWait` counterparts select synchronous lookup in either a synchronous or async context. Bound factories keep receivers in the caller's isolation domain. Receiver-specific Objective-C dynamic resolution and forwarding-signature callbacks stay on the caller's executor while image and call preparation run on the worker. See <doc:CFunctionInvocation>, <doc:ObjectiveCInvocation>, and <doc:SwiftMemberInvocation> for examples.

Native invocation follows the target's actor-isolation and thread-affinity requirements. A synchronous native function stays synchronous; an async native signature requires `await` when invoking the returned handle.

## Keep repeated lookup work small

Automatic lookup works without configuration. When you know which framework provides a declaration, specify it to reduce the images searched, especially when probing for optional APIs that may be absent:

```swift
let decorate = try runtime.resolveSwiftFunctionAndWait(
    named: "Example.decorate(_:)", as: ((String) -> String).self,
    in: .framework(named: "Example")
)
let first = try unsafe decorate.unsafeInvoke("Hello")
let second = try unsafe decorate.unsafeInvoke("Again")
```

Retain the handle for repeated calls. For other declarations in the same image, pass its retained `NativeImage` to an `in:` overload.

A Swift module name does not necessarily identify its containing framework: a statically linked module can live in the executable, and a framework can contain several modules. Select the image that actually supplies the declaration. An explicit framework scope does not search its dependencies or fall back to the whole process. If the provider can vary, list its possible frameworks in a ``NativeSymbolRequest``. Append `.automatic` only when a final process-wide search is needed.

An automatic search checks every available image for absence or ambiguity, so its first lookup can cost substantially more than a framework-scoped lookup. The runtime caches results while the catalog is unchanged; loading or unloading refreshes that scope. Keep these caches between lookups.

## Prepare known requirements ahead of time

Await a resolution factory directly to search and prepare without blocking `MainActor`:

```swift
@MainActor
func calculate() async throws -> Int32 {
    let add = try await ABIRuntime.shared.resolveCXXFunction(
        named: "Example::Math::add(int, int)",
        as: ((Int32, Int32) -> Int32).self,
        in: .framework(named: "Example")
    )
    return try unsafe add.unsafeInvoke(20, 22)
}
```

Synchronous lookup works without a preceding preparation call:

```swift
@MainActor
func calculate(using runtime: ABIRuntime) throws -> Int32 {
    let add = try runtime.resolveCXXFunctionAndWait(
        named: "Example::Math::add(int, int)",
        as: ((Int32, Int32) -> Int32).self,
        in: .framework(named: "Example")
    )
    return try unsafe add.unsafeInvoke(20, 22)
}
```

Use the asynchronous closure overload of `prepare(_:)` to obtain the same handle ahead of time. It runs the closure on a worker queue, independent of the caller's actor. The closure and its returned value must be Sendable; keep actor-isolated receivers and native invocation on their required actor:

```swift
@MainActor
func calculateWithPreparation() async throws -> Int32 {
    let runtime = ABIRuntime.shared
    async let prepared = runtime.prepare { runtime in
        try runtime.resolveCXXFunctionAndWait(
            named: "Example::Math::add(int, int)",
            as: ((Int32, Int32) -> Int32).self,
            in: .framework(named: "Example")
        )
    }

    // Other screen setup can run before the synchronous API is needed.
    let sum = try calculate(using: runtime)

    // Observe the preparation result without making it a prerequisite.
    _ = try await prepared
    return sum
}
```

Use the same runtime for preparation and lookup so both share indexes and call layouts. Lookup performs work that has not started and joins only the work it needs, without waiting for the whole closure or batch. Discarding a prepared handle leaves cached preparation intact. No readiness flag is required. Native image loading and Swift metadata initialization retain their reentrancy rules.

For symbol-only preparation, `prepare(request)` returns a ``ResolvedSymbol`` with the same errors as `resolve(request)`. `prepare(requests)` preserves order and partial success with one `Result` per input. Both honor scopes, aliases, fallbacks, and loading policy. To prepare a call signature too, use a callable factory in the closure overload.

## Describe the declaration

A `NativeDeclaration` combines a source-level name with its language and required storage kind:

- C names use their ordinary linker spelling, without Mach-O's leading underscore.
- C++ names use complete demangled declarations, such as `Example::Math::add(int, int)`.
- Swift names use complete demangled declarations, including module qualification and a return type.
- Objective-C selectors require an invocation frontend and are not resolved through these symbol-table APIs.

Punctuation spacing is normalized while identifier boundaries remain significant. For C++ vtables, use `NativeDeclaration(vtableFor: "Example::Counter")`. Pass the qualified type name; the library supplies the descriptive symbol spelling. The result is the vtable symbol base, with no inferred address-point offset. Existing complete demangled declarations remain supported.

Symbol resolution does not reconstruct a function's calling convention. In particular, C++ symbols do not always encode return types, and nontrivial values require layout and ownership information beyond a name.

## Use exact spellings when ABI variants matter

Prefer ordinary declaration names. When distinct ABI entry points share a demangled declaration, such as C++ destructor variants, use an explicit linker or Mach-O spelling:

```swift
let linker = NativeDeclaration(
    linkerName: "_ZN7Example4Math3addEii", language: .cxx
)
let literal = NativeDeclaration(
    machOName: "__ZN7Example4Math3addEii", language: .cxx
)
let symbol = try runtime.resolveAndWait(linker)
```

Both declarations identify the same symbol spelling in this example. Linker form adds exactly one Mach-O underscore. Literal Mach-O form uses the supplied name unchanged. The resolver never guesses the form from a prefix, strips an existing underscore, or normalizes punctuation or whitespace in an exact name.

For example, a C linker name `_helper` corresponds to Mach-O spelling `__helper`. A mangled Swift linker name beginning with `$s` corresponds to a Mach-O spelling beginning with `_$s`. The declaration's ``NativeDeclaration/language`` remains available as metadata; exact matching does not reinterpret the name through that language's demangler.

Exact declarations use the same storage checks, image scopes, lookup precedence, ambiguity errors, and image retention as source lookup. They can be mixed with source-level aliases in ``NativeSymbolRequest``. Matching an exact symbol still does not establish an invocation signature.

## Lookup precedence and failures

The runtime searches loaded symbol tables and exports first. If no definition matches, it searches local symbols from the matching dyld shared cache where that metadata is available. Loaded-image results retain precedence even after a shared-cache index has been populated.

Available images can yield a match while unrelated images are still initializing. If no match is found and some registered images remain unavailable, lookup throws `ABIResolutionError.imageUnavailable`. Partial scopes are not cached, even in a batch: initializer completion leaves the catalog revision unchanged. A later lookup can discover that image or new ambiguity without a cache reset.

Distinct available definitions at the same lookup level produce `ABIResolutionError.ambiguousDeclaration`. A matching name whose address is outside the requested executable or data storage produces `ABIResolutionError.invalidAddress`. The containing section range does not establish the size of a function or value. Thread-local descriptors and storage templates are rejected because they do not provide an ordinary process-wide variable address.

Shared-cache files are optional lookup sources, selected using cache and image identity rather than a particular OS build number. Their presence and readability vary by platform and installation. Missing local symbol metadata can leave a declaration unresolved.

## Resolve a group of requirements

Use ``NativeSymbolRequest`` to describe a declaration, optional alternative spellings, and ordered image scopes. Pass several requests to `await runtime.resolve(_:)`, or `runtime.resolveAndWait(_:)`, to receive one `Result` per input:

```swift
let requests: [NativeSymbolRequest] = [
    .init(
        .init(name: "Example::Renderer::refresh()", language: .cxx),
        in: [.framework(named: "Example"), .framework(named: "ExampleSupport")]
    ),
    .init(.init(name: "Example::counter", language: .cxx, kind: .data),
          in: [.framework(named: "Example")])
]
let results = runtime.resolveAndWait(requests)
for result in results {
    switch result {
    case .success(let symbol): print(symbol.image.path)
    case .failure(let error): print(error)
    }
}
```

A single request can also be resolved with `try await runtime.resolve(request)` or `try runtime.resolveAndWait(request)`. The first scope containing a matching declaration wins. Later scopes are tried only when an image or declaration is absent. An empty scope array searches no images and reports `imageNotLoaded`.

Use `alternatives:` for declarations expected to identify the same symbol. Missing spellings are ignored, including a missing primary declaration. Every found spelling in the selected scope must agree on both address and image generation. Distinct matches are ambiguous, and invalid storage stops lookup even if another spelling matched. The returned symbol records the first declaration that matched.

Batch results preserve input order and partial success. An empty batch returns no results. Retained image lists are reused for repeated scopes within the batch, while declaration indexes use the runtime's existing cache. Acquisition invalidates earlier scope snapshots so later requests can discover newly loaded dependencies. This is not an atomic snapshot of loader activity. Each successful result retains its image independently of the batch and runtime.

## Try names lazily

Use `fallbacks:` when one declaration should be tried only after an earlier candidate is absent. For example, an adapter with a known linker spelling can keep its exact-name fast path and use source-level resolution only when needed:

```swift
let request = NativeSymbolRequest(
    .init(linkerName: "_ZN7Example7counterE", language: .cxx, kind: .data),
    fallbacks: [
        .init(name: "Example::counter", language: .cxx, kind: .data)
    ],
    in: [.framework(named: "Example"), .framework(named: "ExampleSupport")]
)
let symbol = try runtime.resolveAndWait(request)
```

Search proceeds by candidate, then scope: the primary and its aliases search all scopes, followed by each fallback in order. The first success stops lookup. Ambiguity, invalid storage, unsupported declarations, and loader failures stop immediately. If all candidates are absent, the error identifies the primary; empty or entirely unloaded scopes report `imageNotLoaded`.

Use `alternatives:` for aliases that must agree, and `fallbacks:` for independent ordered choices.

## Borrow an address

Use `ResolvedSymbol.withUnsafeAddress` for a synchronous operation that requires the raw address. The closure keeps the containing image retained, but the pointer must not escape.

Calling a function still requires a correct signature, calling convention, argument ownership, and any function-pointer authentication required by the target ABI. Interpreting data requires the actual object's size and layout. The resolver supplies raw addresses; it does not authenticate or sign function pointers.

The image handle protects code and static storage belonging to that image. It does not retain an unrelated receiver, protect a borrowed object's lifetime, or satisfy a function's thread-affinity contract.

## Hand a symbol to a native adapter

Use ``ResolvedSymbol/copyNativeHandle()`` when a C or Objective-C++ adapter needs to retain the result beyond a synchronous borrow. The returned `ABIResolvedSymbol *` owns a reference independently of the Swift value. Transfer that reference to the adapter, or release it with `ABIReleaseResolvedSymbol` from `ABIBridgeCore`.

To import a live borrowed C handle, use ``ResolvedSymbol/init(retainingNativeHandle:)``. The initializer acquires independent Swift ownership without consuming the C reference or repeating lookup. Declaration metadata, section bounds, image identity, and lookup source are preserved.

See <doc:NativeInspection> for C++ adoption and retention. These operations keep the implementation image loaded; they do not establish receiver ownership or validate a native call signature.

## Cache and loader lifetime

Call `removeCachedResults()` to release cached indexes and results. Existing image, symbol, and callable handles stay valid; subsequent lookups rebuild the required indexes. Known Swift classes reuse their defining image while it remains retained.

Each image load has a process-local generation, so a later image at the same address cannot inherit the previous generation's identity. The native catalog registers process-lifetime dyld observers and pins the image containing their callback code. Executables and dyld shared-cache images already have process lifetime, so their leases do not reopen a filesystem path. Other image leases acquire loader references without loading missing code.

## Validation boundary

The test suite resolves C++ functions, data, and vtables from temporary native libraries, resolves a Swift declaration, checks ambiguous and missing lookups, and verifies that retained handles survive release of the original loader handle. It also checks unload/reload generations. Generic platform builds verify compilation; they do not establish runtime behavior on every supported device.
