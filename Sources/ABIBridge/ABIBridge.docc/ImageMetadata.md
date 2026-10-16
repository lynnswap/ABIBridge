# Inspecting loaded-image metadata

Read a retained image's architecture, sections, and recorded function starts through the `ABIBridge` product.

## Read an image

```swift
import ABIBridge

let runtime = ABIRuntime.shared
let images = try await runtime.resolveImages(matching: .framework(named: "Example"))
if let image = images.first {
    let metadata = try await runtime.resolveImageMetadata(in: image)
    print(metadata.architecture.cpuType, metadata.architecture.cpuSubtype)

    for section in metadata.sections where section.name == "__cstring" {
        print(section.segmentName, section.addressRange)
    }

    if let starts = metadata.functionStartAddresses {
        print("Recorded function starts:", starts)
    }
}
```

`resolveImages` selects already-loaded images. `resolveImageMetadata` copies the selected image's metadata on a worker while the caller suspends. Use `resolveImageMetadataAndWait(in:)` for synchronous inspection on the caller's thread. Neither form requires `prepare`, loads a dependency, or builds a symbol index.

The CPU type and subtype retain their raw values, including architecture flags and subtype capability bits. `is64Bit` describes the Mach-O header format; it does not establish the pointer size of values stored in the image.

## Use section and function addresses

Section ranges and function-start addresses already include the source image's slide. Do not add it again. Sections retain their segment and section names in load-command order, including empty ranges for zero-length sections.

`functionStartAddresses` comes from `LC_FUNCTION_STARTS`. Nil means the command is absent; an empty array means it records no function starts. A present but malformed or unreadable table throws `ABIResolutionError.metadataUnavailable` and fails the entire metadata request.

An entry establishes that the image records a start at that address. It does not establish a function's size, signature, ownership convention, or pointer-authentication requirements. Symbol resolution continues to use its existing storage rules without requiring a function-start table. See <doc:SymbolLookup> and <doc:NativeFunctionInvocation> for resolving and calling native declarations.

## Keep the image alive while reading

``NativeImageMetadata/image`` retains the same loaded image generation independently of runtime caches and the original image handle. The copied names and numeric addresses can be passed between actors with the metadata value.

Extracting an address array or section range does not retain the image. Keep the metadata or its `image` alive through address use. For a bounded copy, construct ``NativeMemoryRegion`` with `retaining: metadata.image` and check the read result as described in <doc:NativeMemory>. A section range describes recorded storage; it does not guarantee that every byte is currently readable or provide synchronization for mutable data.
