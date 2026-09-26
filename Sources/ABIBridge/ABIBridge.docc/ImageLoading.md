# Acquiring images during lookup

Resolve declarations in an explicitly selected library without a separate loading step.

## Select a framework or executable

On a platform that provides JavaScriptCore, the framework does not need to be imported into the source file:

```swift
let create = try await runtime.cFunction(
    named: "JSContextGroupCreate",
    as: (() -> UnsafeMutableRawPointer?).self,
    in: .framework(named: "JavaScriptCore")
)
```

Explicit framework and file-URL scopes default to ``ImageLoadingPolicy/ifNeeded``. The native loader acquires the selected image and performs its normal initialization before resolution proceeds. A catalog entry or process-lifetime mapping alone is not used as an initialization guarantee. Ordinary dyld reentrancy rules still apply when resolution is called from an initializer.

Loading occurs during resolution, on that operation's executor or thread. `ABIRuntime` is an actor and does not promise to execute native initializers on the caller's actor. If a library requires a particular initialization context, acquire it there before using `loading: .loadedOnly`.

Framework names first select matching loaded images. Otherwise, discovery checks the application's framework directories and the system's public/private framework locations, including shared-cache-only images. Multiple candidates report `ABIResolutionError.ambiguousImage`; use a concrete executable URL to distinguish them. Presence in a directory or cache does not establish loadability.

```swift
let function = try await runtime.cxxFunction(
    named: "Example::Renderer::version()",
    as: (() -> Int32).self,
    in: .path(binaryURL)
)
```

The URL identifies the Mach-O executable, not its enclosing framework directory. File URLs and framework names cannot contain embedded NULs. Loading a path is attempted even when filesystem checks cannot see a file, as is common for system shared-cache images.

## Use dyld install names

Use ``ImageSelector/installName(_:)`` for loader syntax rather than constructing a file URL from it:

```swift
let symbol = try await runtime.resolve(
    declaration,
    in: .installName("@rpath/Example.framework/Example")
)
```

`@rpath`, `@loader_path`, `@executable_path`, bare names, and relative paths follow dyld's rules. The loader call resides in ABIBridge's native code. If that code is linked into a framework, `@loader_path` refers to that framework's image, not the Swift source file that called an async method. Use an absolute URL when that distinction matters. ABIBridge does not recreate dyld's path expansion or decode opaque loader handles.

## Keep inspection loaded-only

Automatic scope never searches for an unloaded library by guessing from a declaration. Image enumeration and lazy-library metadata inspection also remain loaded-only observations.

To resolve within an explicit scope without requesting loading or initialization:

```swift
let symbol = try await runtime.resolve(
    declaration, in: .path(binaryURL), loading: .loadedOnly
)
```

This policy does not certify initialization; the caller supplies the native preconditions for any subsequent unsafe invocation. A C++ receiver scope stores its selection and policy but does not acquire an image until member lookup. An existing Objective-C receiver or an explicit function address does not cause an additional load operation.

## Preserve lifetime and failure information

Resolved symbols, functions, types, and runtime indexes retain their image owners. Clearing a cache releases its references while existing handles remain valid. A final release balances ABIBridge's loader reference; physical unloading remains dyld's decision.

Loading may execute constructors and acquire dependencies even when the requested declaration is subsequently missing. These effects cannot be rolled back as a transaction. `ABIResolutionError.imageLoadFailed(target:message:)` preserves the original dyld diagnostic. Loader failures stop ordered fallback; they are not silently treated as a missing declaration. A later operation can retry acquisition after its cause is addressed.

Only the requested explicit target is acquired. ABIBridge uses its existing symbol indexes to locate definitions afterward; it does not treat the import names returned by `lazyLibraries` as addresses or traverse mutable binding chains. Batch scope snapshots are refreshed after acquisition attempts, including failures that may have changed loader state.

## Native consumers

C++ and Objective-C++ use `Runtime::resolve(query, selector, image_loading::if_needed)` by default, or `image_loading::loaded_only` for inspection. `image_selector::install_name` carries dyld spellings. A `symbol_request` stores the same policy in `loading`.

The C entry points `ABIResolveSymbol`, `ABIResolveSymbolWithNameForm`, and `ABIResolveCXXVTable` accept a loading argument before the failure output. Pass `ABIImageLoadIfNeeded` or `ABIImageLoadedOnly`; zero-initialized `ABISymbolRequest` values use the former. Rebuild C consumers against the updated declarations and request layout. These are source-distributed interfaces, not a binary compatibility layer for older headers.

Platform loader and code-signing rules determine which targets can be acquired. Package build coverage does not establish runtime loading permission for every library on every Apple platform.
