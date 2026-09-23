# Inspecting native images from C and C++

Resolve source-level declarations and retain their images from C, C++, or Objective-C++.

## Import and link

Add the `ABIBridge` product to the consumer target, then include:

```c
#include <ABIBridge/Inspection.h>
#include <stdio.h>
```

For example, a target in a separate Swift package can use:

```swift
.executableTarget(
    name: "Inspector",
    dependencies: [.product(name: "ABIBridge", package: "ABIBridge")]
)
```

The same product supplies the Swift implementation, native code, and their dependencies. The resolver uses the shared MachOKit-backed implementation and the Swift runtime; linking the internal C++ target alone does not provide the supported product. C consumers do not need to import a generated Swift header or enable C++ interoperability.

The declarations in `Inspection.h` and the C++20 wrappers in `Inspection.hpp` are supported consumer interfaces. Other native headers, invocation templates, and backend handles remain implementation details. Use this public header directly instead of the internal module umbrella.

## Use C++ ownership wrappers

Include `<ABIBridge/Inspection.hpp>` and set `cxxLanguageStandard: .cxx20` in the consumer package. The wrappers use the C interface and the same `ABIBridge` product.

```cpp
#include <ABIBridge/Inspection.hpp>

using namespace abi_bridge;

auto runtime = Runtime::current();
auto table = runtime.resolve(
    declaration::vtable_for("Example::Renderer"),
    image_selector::framework("Example")
);
const void *address = table.unsafe_address();
auto path = table.image_path(); // An owned std::string.
```

The example requires an already-loaded framework defining that type. Resolution throws `resolution_error`, whose `code()` preserves the C failure category and whose `what()` owns the message. Error objects can outlive the runtime and native failure handle. Names and image selectors use UTF-8; embedded NULs are rejected instead of resolving a truncated prefix.

Copies of `Runtime` share a resolver cache; default construction creates an independent resolver. Copies of `resolved_symbol` share the acquired symbol, keeping its implementation image alive after cache clearing or runtime destruction. The unsigned address remains borrowed; the C++ wrapper does not establish an invocation signature.

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

Copies share ownership of the underlying snapshot, lease, runtime, or symbol; their final owner releases the C handle. Moving a handle leaves the source empty. It can be tested with `operator bool`, reassigned, or destroyed; other methods require a live handle. A moved-from `std::optional<image_lease>` can remain engaged, so test the contained handle if it has been moved separately.

Objective-C++ can store these C++ values in instance variables under either ARC or manual reference counting. Their C++ destructors release the native handles when the enclosing object is destroyed. Keep an Objective-C owner alive through uses of borrowed pointers, for example with an `objc_precise_lifetime` local, or keep an independent C++ handle copy. Image retention still does not retain an unrelated native receiver or satisfy that receiver's thread/lifetime requirements.

## Resolve a vtable from C

For an already-loaded image containing an `Example::Renderer` type:

```c
ABISymbolRuntime *runtime = ABICreateSymbolRuntime();
ABIResolutionFailure *failure = NULL;
ABIResolvedSymbol *table = ABIResolveCXXVTable(
    runtime, "Example::Renderer", ABIImageFramework, "Example", &failure
);
if (!table) {
    fprintf(stderr, "%d: %s\n", (int)ABIResolutionFailureCode(failure),
            ABIResolutionFailureMessage(failure));
    ABIReleaseResolutionFailure(failure);
    ABIReleaseSymbolRuntime(runtime);
    return;
}

ABIImageInfo image;
ABIResolvedSymbolImage(table, &image);
const void *address = ABIResolvedSymbolAddress(table);
// Inspect address using the type's actual layout while table remains alive.
ABIReleaseSymbolRuntime(runtime);
// The table handle independently retains its image.
ABIReleaseResolvedSymbol(table);
```

C names omit the Mach-O underscore; C++ and Swift names use demangled declarations. Language, storage-kind, and image-scope constants are declared in the header. Objective-C selector dispatch is not provided through this symbol-lookup API.

Framework and executable-path scopes only search loaded images. Automatic scope reports distinct matching definitions as an ambiguity. A vtable symbol's address is not necessarily its first virtual-function slot; the consumer supplies the actual address-point offset and layout.

## Resolve an exact native spelling

Source-level declarations remain the default. For explicit ABI variants, C++ provides `declaration::linker_name` and `declaration::mach_o_name`:

```cpp
auto symbol = runtime.resolve(abi_bridge::declaration::linker_name(
    "_ZN7Example4Math3addEii", abi_bridge::language::cxx
));
```

Linker form adds one Mach-O underscore without examining the prefix. Mach-O form uses the literal symbol-table spelling unchanged. Neither form demangles or normalizes the name. Image selection, storage validation, ambiguity, and ownership use the ordinary resolver.

C uses `ABIResolveSymbolWithNameForm` with `ABINameSource`, `ABINameLinker`, or `ABINameMachO`. `ABIResolveSymbol` remains the source-form convenience entry point. Batch declarations carry the same choice in `ABIDeclaration.nameForm`; zero selects source form. Initialize all fields or use zero-initialized C aggregates. C++ declarations preserve their form when used in batches.

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
    fprintf(stderr, "%s\\n", ABIResolutionFailureMessage(result.failure));
    ABIReleaseResolutionFailure(result.failure);
}
```

Each output contains exactly one owned symbol or failure. Release old output references before reusing storage; the call overwrites them without releasing them. At count zero, both input and output arrays may be null. Request strings and nested arrays are borrowed only for the duration of the call. Invalid fields fail their request independently.

Scopes are tried in order only when an image or declaration is absent. Missing aliases are ignored; all found aliases must agree on address and image generation. Ambiguity or invalid storage stops fallback. Empty scopes match no images. Scope results are reused within the batch, using the same backend as Swift; the operation does not claim an atomic loader snapshot.

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

The original reference must stay alive during retention. Each acquired C reference must be released once; copying its numeric pointer alone does not acquire ownership. `native_handle()` borrows the C pointer from the C++ wrapper.

In the other direction, Swift's `ResolvedSymbol(retainingNativeHandle:)` imports a live borrowed C handle without consuming it. It preserves the same resolved metadata and independently retains the image. No handoff repeats lookup, and the original Swift value, C handle, or runtime cache can be released once the receiving owner has acquired its reference.

## Track image identity

`ABICopyLoadedImages()` returns an immutable snapshot with a count and indexed `ABIImageInfo` entries. Each load has a generation that changes on reload. Snapshots contain descriptions rather than loader references: an image can disappear after the snapshot is taken.

Call `ABIRetainLoadedImage(info.generation)` to acquire a separate loader lease. A null result means the generation disappeared or could not be retained. A non-null lease keeps the image loaded until `ABIReleaseImage`; the platform may independently keep it loaded longer. This operation does not load a missing image.

If catalog initialization cannot retain the callback image, snapshot creation returns null without a detailed error object. A valid empty snapshot is distinct from this failure.

## Ownership

| Value | Owner and lifetime |
| --- | --- |
| Runtime returned by create/copy | One acquired reference, released with `ABIReleaseSymbolRuntime` |
| Resolved symbol | One owned reference, released with `ABIReleaseResolvedSymbol`; independently retains its image |
| Image snapshot | Released with `ABIFreeImageList`; owns the paths in its entries |
| Image lease | Released with `ABIReleaseImage`; retains code/data, not strings owned by other handles |
| Failure | Released with `ABIReleaseResolutionFailure`; owns its message |
| `ABIResolvedSymbolAddress` result | Borrowed; keep the symbol or a separate image lease alive |
| `ABIResolvedSymbolImage` path | Borrowed from the symbol even if a separate lease keeps the image loaded |

Copying a handle pointer does not acquire another reference. Each call to `ABICopySharedSymbolRuntime` does acquire one, sharing the backend with Swift's `ABIRuntime.shared`. Independent runtimes own independent caches.

Clearing caches or releasing a runtime does not invalidate existing symbol handles. Keep the relevant owner alive through reads and cleanup that use its addresses. Retaining an image does not retain an object found inside it or establish a pointee's lifetime.

## Errors and concurrent use

Resolution returns null on failure and an owned error when the optional error output is supplied. Success writes null to that output. An existing output value is overwritten without being released; release or save the previous owned error before reusing the variable. Unknown enum values and missing required selectors produce `ABIFailureInvalidRequest`. Missing declarations, unavailable images, ambiguity, and invalid symbol storage remain distinct categories.

Runtimes, immutable symbols, and snapshots can be read from multiple threads while their owners remain alive. Resolution and cache clearing synchronize through the same backend used by Swift. Callers synchronize final release against uses of the released reference. Valid handles, in-range snapshot indices, and null-terminated input strings remain caller requirements.

An unsigned resolved address is suitable for inspection. Native invocation additionally needs the correct calling convention, parameter/result layout, pointer authentication, and target thread requirements. This interface does not infer object layout or discover receivers inside arbitrary memory.
