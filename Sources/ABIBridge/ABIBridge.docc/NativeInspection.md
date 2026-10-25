# Inspecting native images from C and C++

Resolve source-level declarations and retain their images from C, C++, or Objective-C++.

## Import and link

Add the `ABIBridge` product to the consumer target, then include:

```c
#include <ABIBridge/ABIBridge.h>
#include <stdio.h>
```

For example, a target in a separate Swift package can use:

```swift
.executableTarget(
    name: "Inspector",
    dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]
)
```

The product supplies the Swift implementation, native code, and dependencies, including the Swift runtime and MachOKit-backed resolver. Use `<ABIBridge/ABIBridge.h>` for the C interface or `<ABIBridge/ABIBridge.hpp>` for C++20. The same C interface works in Objective-C; Objective-C++ can also use the typed wrappers. See <doc:NativeInterfaces> for the feature headers.

## Use C++ ownership wrappers

Include `<ABIBridge/Inspection.hpp>` and set `cxxLanguageStandard: .cxx20` in the consumer package. The wrappers use the C interface and the same `ABIBridge` product.

```cpp
#include <ABIBridge/Inspection.hpp>

using namespace abi_bridge;

auto runtime = runtime::current();
auto table = runtime.resolve(
    declaration::vtable_for("Example::Renderer"),
    image_selector::framework("Example")
);
const void *address = table.unsafe_address();
auto path = table.image_path(); // An owned std::string.
```

The example acquires the framework when needed. To search only loaded images, pass `image_loading::loaded_only` as the third argument; see <doc:ImageLoading>. Resolution throws `resolution_error` with the C failure category in `code()` and an owned message in `what()`. Names and selectors use UTF-8 and reject embedded NULs. Errors can outlive the runtime and native failure handle.

Copies of `runtime` share a resolver cache; default construction creates an independent resolver. Copies of `resolved_symbol` share the acquired symbol, keeping its implementation image alive after cache clearing or runtime destruction. The unsigned address remains borrowed; the C++ wrapper does not establish an invocation signature.

Snapshots and independent loader leases are also values with automatic lifetime management:

```cpp
auto snapshot = image_snapshot::capture();
for (std::size_t index = 0; index < snapshot.size(); ++index) {
    auto image = snapshot.at(index);
    auto lease = image_lease::acquire(image.identity.load_generation);
    if (!lease) continue;
    // Inspect this image while the lease is alive.
}
```

`image_description` owns its path and UUID but does not retain the image. It can outlive the snapshot. `at()` throws `std::out_of_range` for an invalid index; capture throws `resolution_error` if the catalog is unavailable. Lease acquisition returns `std::nullopt` when the generation disappeared or cannot be retained, matching the C API's lack of a detailed lease failure.

Copies share their C handle; the final owner releases it. Moving leaves an empty handle that can be tested, reassigned, or destroyed. Other methods require a live handle. A moved-from `std::optional<image_lease>` may remain engaged, so test its contained handle if moved separately.

Objective-C++ can store these C++ values in instance variables under either ARC or manual reference counting. Their C++ destructors release the native handles when the enclosing object is destroyed. Keep an Objective-C owner alive through uses of borrowed pointers, for example with an `objc_precise_lifetime` local, or keep an independent C++ handle copy. Image retention still does not retain an unrelated native receiver or satisfy that receiver's thread/lifetime requirements.

## Resolve a vtable from C

For a framework containing an `Example::Renderer` type:

```c
ABISymbolRuntime *runtime = ABICreateSymbolRuntime();
ABIResolutionFailure *failure = NULL;
ABIResolvedSymbol *table = ABIResolveCXXVTable(
    runtime, "Example::Renderer", (ABIImageSelector){ABIImageFramework, "Example"},
    ABIImageLoadIfNeeded, &failure
);
if (!table) {
    fprintf(stderr, "%d: %s\n", (int)ABIResolutionFailureGetCode(failure),
            ABIResolutionFailureGetMessage(failure));
    ABIReleaseResolutionFailure(failure);
    ABIReleaseSymbolRuntime(runtime);
    return;
}

ABIImageInfo image;
ABIResolvedSymbolGetImage(table, &image);
const void *address = ABIResolvedSymbolGetAddress(table);
// Inspect address using the type's actual layout while table remains alive.
ABIReleaseSymbolRuntime(runtime);
// The table handle independently retains its image.
ABIReleaseResolvedSymbol(table);
```

C names omit the Mach-O underscore; C++ and Swift names use demangled declarations. Language, storage-kind, and image-scope constants are declared in the header. Objective-C selector dispatch is not provided through this symbol-lookup API.

Explicit framework and executable-path scopes acquire the target with `ABIImageLoadIfNeeded`; `ABIImageLoadedOnly` limits them to loaded images. Automatic scope searches loaded images and reports distinct definitions as ambiguous. For vtables, supply the actual address-point offset and layout; the symbol need not start at the first function slot.

## Resolve an exact native spelling

Source-level declarations remain the default. For explicit ABI variants, C++ provides `declaration::linker_name` and `declaration::mach_o_name`:

```cpp
auto symbol = runtime.resolve(abi_bridge::declaration::linker_name(
    "_ZN7Example4Math3addEii", abi_bridge::language::cxx
));
```

Linker form adds one Mach-O underscore without examining the prefix. Mach-O form uses the literal symbol-table spelling unchanged. Neither form demangles or normalizes the name. Image selection, storage validation, ambiguity, and ownership use the ordinary resolver.

C sets `ABIDeclaration.nameForm` to `ABINameSource`, `ABINameLinker`, or `ABINameMachO`. Both `ABIResolveSymbol` and `ABIResolveSymbols` take `ABISymbolRequest`, preserving each declaration's language, storage kind, and name form. Zero selects source form; initialize all fields or use zero-initialized C aggregates. C++ declarations preserve their form when used in batches.

The language is retained as metadata for exact spellings, so a mangled C++ or Swift name does not need to be labeled as C. Exact Objective-C symbols can also be inspected; Objective-C selector invocation still uses the separate Swift frontend.

## Resolve batches and ordered alternatives

C++ uses `symbol_request` for a primary declaration, alternative spellings, and ordered image scopes:

```cpp
std::vector<abi_bridge::symbol_request> requests{
    {{"Example::Renderer::refresh()", abi_bridge::language::cxx}, {},
     {abi_bridge::image_selector::framework("Example"),
      abi_bridge::image_selector::framework("ExampleSupport")}},
    {{"Example::counter", abi_bridge::language::cxx, abi_bridge::symbol_kind::data}, {},
     {abi_bridge::image_selector::framework("Example")}}
};
auto results = runtime.resolve(requests);
for (const auto& result : results) {
    if (const auto* symbol = std::get_if<abi_bridge::resolved_symbol>(&result)) {
        auto path = symbol->image_path();
    } else {
        const auto& error = std::get<abi_bridge::resolution_error>(result);
        // Handle error.code() and error.what().
    }
}
```

Each `resolution_result` owns either a symbol or an error. A single `symbol_request` can also be passed to `resolve`, which returns a symbol or throws. Batch lookup errors stay with their corresponding request; allocation failures may still throw.

C uses `ABISymbolRequest` and a count-element `ABISymbolResult` output array:

```c
ABIImageSelector scopes[] = {{ABIImageFramework, "Example"}};
ABISymbolRequest request = {
    {"Example::counter", ABILanguageCXX, ABISymbolData},
    NULL, 0, scopes, 1
};
ABISymbolResult result = {0};
ABIResolveSymbols(runtime, &request, 1, &result);
if (result.symbol) {
    // This independently owned symbol can be kept after the batch ends.
    ABIReleaseResolvedSymbol(result.symbol);
} else {
    fprintf(stderr, "%s\\n", ABIResolutionFailureGetMessage(result.failure));
    ABIReleaseResolutionFailure(result.failure);
}
```

The same request resolves individually with `ABIResolveSymbol(runtime, &request, &failure)`. Success returns one owned `ABIResolvedSymbol *` and clears the failure output; release that symbol with `ABIReleaseResolvedSymbol`.

Each batch output contains exactly one owned symbol or failure. Release old output references before reusing storage; the call overwrites them without releasing them. At count zero, both input and output arrays may be null. Request strings and nested arrays are borrowed only for the duration of the call. Invalid fields fail their request independently.

Scopes advance only when an image or declaration is absent. Missing aliases are ignored; found aliases must agree on address and image generation. Ambiguity or invalid storage stops lookup. Empty scopes match no images. Batches reuse scope results through the Swift backend without an atomic loader snapshot.

### Lazy name fallback

The `fallbacks` member is distinct from strict `alternatives`. Each fallback is resolved only when earlier candidates are absent:

```cpp
abi_bridge::symbol_request request{
    abi_bridge::declaration::linker_name(
        "_ZN7Example7counterE", abi_bridge::language::cxx, abi_bridge::symbol_kind::data),
    {},
    {abi_bridge::image_selector::framework("Example")},
    {{"Example::counter", abi_bridge::language::cxx, abi_bridge::symbol_kind::data}}
};
auto symbol = runtime.resolve(request);
```

C supplies these candidates through `ABISymbolRequest.fallbacks` and `fallbackCount`. Initialize every field, or zero-initialize before assigning fields. Rebuild consumers when adopting changes to this source-distributed request layout.

The primary and aliases search all scopes, followed by each fallback in order. Success stops lookup; substantive errors also stop it. Validation covers the entire request, including unused candidates. If all are absent, the error identifies the primary. See <doc:SymbolLookup> for the shared precedence rules.

## Pass symbols between Swift and native adapters

Swift can export a resolved result with `symbol.copyNativeHandle()`. The returned pointer owns one C reference. A C adapter releases it with `ABIReleaseResolvedSymbol`; C++ can take ownership with `resolved_symbol::adopt`:

```cpp
// owned is the ABIResolvedSymbol* transferred by the caller.
auto symbol = abi_bridge::resolved_symbol::adopt(owned);
```

Adoption consumes that reference, including if wrapper allocation throws. To acquire ownership from a borrowed handle instead, call `ABIRetainResolvedSymbol` in C or `resolved_symbol::retain` in C++:

```cpp
auto retained = abi_bridge::resolved_symbol::retain(symbol.native_handle());
```

Keep the original reference alive during retention. `native_handle()` borrows from the C++ wrapper; use the ownership rules below for acquired references.

Swift's `ResolvedSymbol(retainingNativeHandle:)` imports a borrowed C handle with independent ownership. Handoffs preserve metadata without repeating lookup. After the receiving owner acquires its reference, the original owner or cache can be released.

## Track image identity

`ABICopyLoadedImages()` returns an immutable snapshot with a count and indexed `ABIImageInfo` entries. Each load has a generation that changes on reload. Snapshots contain descriptions rather than loader references: an image can disappear after the snapshot is taken.

Call `ABIAcquireImageLease(info.generation)` to acquire a separate loader lease. A null result means the generation disappeared or could not be retained. A non-null lease keeps the image loaded until `ABIReleaseImageLease`; the platform may independently keep it loaded longer. This operation does not load a missing image.

If catalog initialization cannot retain the callback image, snapshot creation returns null without a detailed error object. A valid empty snapshot is distinct from this failure.

## Ownership

| Value | Owner and lifetime |
| --- | --- |
| Runtime returned by create/copy | One acquired reference, released with `ABIReleaseSymbolRuntime` |
| Resolved symbol | One owned reference, released with `ABIReleaseResolvedSymbol`; independently retains its image |
| Image snapshot | Released with `ABIReleaseImageList`; owns the paths in its entries |
| Image lease | Released with `ABIReleaseImageLease`; retains code/data, not strings owned by other handles |
| Failure | Released with `ABIReleaseResolutionFailure`; owns its message |
| `ABIResolvedSymbolGetAddress` result | Borrowed; keep the symbol or a separate image lease alive |
| `ABIResolvedSymbolGetImage` path | Borrowed from the symbol even if a separate lease keeps the image loaded |

Opaque owners use `Release` functions. Property accessors use `Get` for borrowed pointers or copied scalar descriptions, and `Copy` for an independently owned result. Predicate queries use `Is` or `Equal`.

Copying a handle pointer does not acquire another reference. Each call to `ABICopySharedSymbolRuntime` does acquire one, sharing the backend with Swift's `ABIRuntime.shared`. Independent runtimes own independent caches.

Symbol handles survive cache clearing and runtime release. Keep their owner alive through address use and cleanup. Image retention keeps code and static storage loaded; unrelated objects and pointees need their own owners.

## Errors and concurrent use

Resolution returns null on failure and an owned error when the optional error output is supplied. Success writes null to that output. An existing output value is overwritten without being released; release or save the previous owned error before reusing the variable. Unknown enum values and missing required selectors produce `ABIFailureInvalidRequest`. Missing declarations, unavailable images, ambiguity, and invalid symbol storage remain distinct categories.

Runtimes, immutable symbols, and snapshots can be read from multiple threads while their owners remain alive. Resolution and cache clearing synchronize through the same backend used by Swift. Callers synchronize final release against uses of the released reference. Valid handles, in-range snapshot indices, and null-terminated input strings remain caller requirements.

An unsigned resolved address is suitable for inspection. Native invocation additionally needs the correct calling convention, parameter/result layout, pointer authentication, and target thread requirements. This interface does not infer object layout or discover receivers inside arbitrary memory.
