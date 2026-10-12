# Acquiring images during lookup

Resolve declarations in an explicitly selected library without a separate loading step.

## Select a framework or executable

On a platform that provides JavaScriptCore, the framework does not need to be imported into the source file:

```swift
let create = try runtime.resolveCFunctionAndWait(
    named: "JSContextGroupCreate",
    as: (() -> UnsafeMutableRawPointer?).self,
    in: .framework(named: "JavaScriptCore")
)
```

Explicit framework and file-URL scopes default to ``ImageLoadingPolicy/ifNeeded``. The native loader acquires the selected image and performs its normal initialization before resolution proceeds. A catalog entry or process-lifetime mapping alone is not used as an initialization guarantee. Ordinary dyld reentrancy rules still apply when resolution is called from an initializer.

Loading runs on the resolution thread: the caller for synchronous lookup, or a worker for async preparation and resolution factories. If the library requires an initialization context, acquire it there and then use `loading: .loadedOnly`. See <doc:SymbolLookup> for choosing synchronous or async lookup.

Framework lookup first checks matching loaded images, then application and system public/private framework locations, including shared-cache-only images. Multiple candidates throw `ABIResolutionError.ambiguousImage`; use an executable URL to distinguish them. Discovery does not guarantee loadability.

```swift
let function = try runtime.resolveCXXFunctionAndWait(
    named: "Example::Renderer::version()",
    as: (() -> Int32).self,
    in: .path(binaryURL)
)
```

The URL identifies the Mach-O executable, not its enclosing framework directory. File URLs and framework names cannot contain embedded NULs. Loading a path is attempted even when filesystem checks cannot see a file, as is common for system shared-cache images.

## Use dyld install names

Use ``ImageSelector/installName(_:)`` for loader syntax rather than constructing a file URL from it:

```swift
let symbol = try runtime.resolveAndWait(
    declaration,
    in: .installName("@rpath/Example.framework/Example")
)
```

dyld expands `@rpath`, `@loader_path`, `@executable_path`, bare names, and relative paths. The loader call resides in ABIBridge's native image; when linked into a framework, `@loader_path` refers to that framework. Use an absolute URL when the caller's location must determine the target.

## Keep inspection loaded-only

Automatic scope never searches for an unloaded library by guessing from a declaration. Image enumeration and lazy-library metadata inspection also remain loaded-only observations.

To resolve within an explicit scope without requesting loading or initialization:

```swift
let symbol = try runtime.resolveAndWait(
    declaration, in: .path(binaryURL), loading: .loadedOnly
)
```

This policy does not certify initialization; the caller supplies the native preconditions for any subsequent unsafe invocation. A C++ receiver scope stores its selection and policy but does not acquire an image until member lookup. An existing Objective-C receiver or an explicit function address does not cause an additional load operation.

## Preserve lifetime and failure information

Resolved symbols, functions, types, and runtime indexes retain their image owners. Clearing a cache releases its references while existing handles remain valid. A final release balances ABIBridge's loader reference; physical unloading remains dyld's decision.

Loading may execute constructors and acquire dependencies even when the requested declaration is subsequently missing. These effects cannot be rolled back as a transaction. `ABIResolutionError.imageLoadFailed(target:message:)` preserves the original dyld diagnostic. Loader failures stop ordered fallback; they are not silently treated as a missing declaration. A later operation can retry acquisition after its cause is addressed.

Only the requested explicit target is acquired. ABIBridge uses its existing symbol indexes to locate definitions afterward; it does not treat the import names returned by `resolveLazyLibraries` or `resolveLazyLibrariesAndWait` as addresses or traverse mutable binding chains. Batch scope snapshots are refreshed after acquisition attempts, including failures that may have changed loader state.

## Native consumers

C++ and Objective-C++ use `Runtime::resolve(query, selector, image_loading::if_needed)` by default, or `image_loading::loaded_only` for inspection. `image_selector::install_name` carries dyld spellings. A `symbol_request` stores the same policy in `loading`.

Pass `ABIImageLoadIfNeeded` or `ABIImageLoadedOnly` before the failure output in `ABIResolveSymbol`, `ABIResolveSymbolWithNameForm`, and `ABIResolveCXXVTable`. Zero-initialized `ABISymbolRequest` values select the former. Rebuild C consumers when adopting changed headers or request layouts.

Platform loader and code-signing rules determine which targets can be acquired. Package build coverage does not establish runtime loading permission for every library on every Apple platform.
