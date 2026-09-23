# Inspecting native images from C

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

The declarations in `Inspection.h` are the supported C interface. Other native headers, invocation templates, and backend handles remain implementation details. Use this public header directly instead of the internal module umbrella.

## Resolve a vtable

For an already-loaded image containing an `Example::Renderer` type:

```c
ABISymbolRuntime *runtime = ABICreateSymbolRuntime();
ABIResolutionFailure *failure = NULL;
ABIResolvedSymbol *table = ABIResolveSymbol(
    runtime, "vtable for Example::Renderer",
    ABILanguageCXX, ABISymbolVTable,
    ABIImageFramework, "Example", &failure
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
