# Resolving symbols and retaining images

Select a loaded image, resolve a declaration, and use its address within an explicit lifetime.

## Choose a search scope

The default scope of ``ABIRuntime`` searches images already loaded in the process. It does not load frameworks or execute their initializers. Use ``ImageSelector`` to restrict lookup to a framework name or an executable path.

```swift
let runtime = ABIRuntime()
let images = try await runtime.images(
    matching: .framework(named: "Foundation")
)
```

An empty image list means no loaded image matches. Resolving a declaration in an empty scope throws `ABIResolutionError.imageNotLoaded`. If the application loads a framework later, a subsequent query can discover it.

A `NativeImage` retains its loaded image. Reuse that handle to resolve several declarations in the same scope. The runtime caches raw symbol data and decoded declaration indexes; C++ members with a plain qualified owner reuse that owner's index.

## Describe the declaration

A `NativeDeclaration` combines a source-level name with its language and required storage kind:

- C names use their ordinary linker spelling, without Mach-O's leading underscore.
- C++ names use complete demangled declarations, such as `Example::Math::add(int, int)`.
- Swift names use complete demangled declarations, including module qualification and a return type.
- Objective-C selectors require an invocation frontend and are not resolved through these symbol-table APIs.

Punctuation spacing is normalized while identifier boundaries remain significant. For C++ vtables, use a declaration such as `vtable for Example::Counter` with kind `.vtable`.

Symbol resolution does not reconstruct a function's calling convention. In particular, C++ symbols do not always encode return types, and nontrivial values require layout and ownership information beyond a name.

## Lookup precedence and failures

The runtime searches loaded symbol tables and exports first. If no definition matches, it searches local symbols from the matching dyld shared cache where that metadata is available. Loaded-image results retain precedence even after a shared-cache index has been populated.

Distinct definitions at the same lookup level produce `ABIResolutionError.ambiguousDeclaration`. A matching name whose address is outside the requested executable or data storage produces `ABIResolutionError.invalidAddress`. The containing section range does not establish the size of a function or value.

Shared-cache files are optional lookup sources, selected using cache and image identity rather than a particular OS build number. Their presence and readability vary by platform and installation. Missing local symbol metadata can leave a declaration unresolved.

## Borrow an address

Use `ResolvedSymbol.withUnsafeAddress` for a synchronous operation that requires the raw address. The closure keeps the containing image retained, but the pointer must not escape.

Calling a function still requires a correct signature, calling convention, argument ownership, and any function-pointer authentication required by the target ABI. Interpreting data requires the actual object's size and layout. The resolver supplies raw addresses; it does not authenticate or sign function pointers.

The image handle protects code and static storage belonging to that image. It does not retain an unrelated receiver, protect a borrowed object's lifetime, or satisfy a function's thread-affinity contract.

## Cache and loader lifetime

Call `removeCachedResults()` on the runtime to release its indexes. Existing `NativeImage` and `ResolvedSymbol` values continue to retain their images. New lookups rebuild the indexes they need.

Each image load has a process-local generation, so a later image at the same address cannot inherit the previous generation's identity. The native catalog registers process-lifetime dyld observers and pins the image containing their callback code. Individual image leases acquire loader references without loading missing code.

## Validation boundary

The test suite resolves C++ functions, data, and vtables from temporary native libraries, resolves a Swift declaration, checks ambiguous and missing lookups, and verifies that retained handles survive release of the original loader handle. It also checks unload/reload generations. Generic platform builds verify compilation; they do not establish runtime behavior on every supported device.
