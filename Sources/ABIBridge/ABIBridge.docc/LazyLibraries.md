# Inspecting lazy-load dependencies

Read the libraries and imports recorded in `LC_LAZY_LOAD_DYLIB_INFO` without loading them.

## Read a loaded image

```swift
let runtime = ABIRuntime.shared
let images = try await runtime.images(matching: .framework(named: "Example"))
if let image = images.first {
    let libraries = try await runtime.lazyLibraries(in: image)
    for library in libraries {
        print(library.path ?? "Unavailable path")
        print(library.isInitialized as Any)
        print(library.areSymbolsPrebound as Any)
        for symbol in library.symbols ?? [] {
            print(symbol.name ?? "Unavailable name")
        }
    }
}
```

The source image stays retained while metadata is copied. Returned values own their strings and may outlive the image. Swift and C++ mangling is decoded where supported; `rawName` retains the exact recorded spelling. An import name does not establish a symbol's storage kind, function signature, or current address.

These diagnostics neither acquire dependencies nor prepare calls. Ordinary resolution handles explicit-target acquisition according to its loading policy; see <doc:ImageLoading>. A recorded dependency path can contain loader tokens such as `@rpath`, and does not prove that the dependency is present or loadable.

## Interpret unavailable information

An empty result means there are no lazy-load commands. A command with an unreadable payload remains in the result with nil fields. If its symbol array is readable, invalid individual strings remain as entries with nil names; other names are preserved. `commandOffset` identifies the load command relative to its Mach-O header.

`isOptional == false` means the dependency is required. A nil value means that the metadata could not be read. Likewise, `symbols == nil` means unavailable metadata, while an empty array records zero symbols.

`areSymbolsPrebound` and `isInitialized` describe different observations. Symbols can be prebound without the library being initialized. The initialized flag is copied from live memory; it is not a synchronization operation with dyld or a guarantee about subsequent operations.

## Inspect a file

```swift
let libraries = try await runtime.lazyLibraries(inFileAt: binaryURL)
```

File inspection accepts a thin Mach-O file and reads it into owned storage. It does not accept universal/fat containers. File-reading failures propagate to the caller, and an invalid header or command table reports `ABIResolutionError.metadataUnavailable`. Individual malformed dependency payloads do not discard valid commands.

`isInitialized` is always nil for file results. A flag stored on disk cannot establish initialization in the current process.

## Inspect from C++ or Objective-C++

Here, `image` is an `image_description` from `image_snapshot`, and `binary_path` identifies a thin Mach-O file.

```cpp
#include <ABIBridge/Inspection.hpp>

auto snapshot = abi_bridge::lazy_library_snapshot::capture(image.identity.load_generation);
for (std::size_t i = 0; i < snapshot.size(); ++i) {
    auto library = snapshot.at(i);
    if (library.path) {
        // library and its strings can outlive snapshot.
    }
}
auto recorded = abi_bridge::lazy_library_snapshot::read_file(binary_path);
```

The C interface in `Inspection.h` supplies `ABICopyLazyLibrariesForImage` and `ABICopyLazyLibrariesInFile`. Free each successful result with `ABIFreeLazyLibraryList`. Getter strings remain borrowed from that snapshot. Optional Boolean fields use `ABIDiagnosticUnknown`, `ABIDiagnosticFalse`, and `ABIDiagnosticTrue`. C++ descriptions copy the strings and use `std::optional` for unavailable fields.

## Binding chains and validation scope

Diagnostics do not expose binding locations or traverse live binding chains. dyld can overwrite a chain concurrently, and loaded or prebound entries may no longer contain their original encoded bind information. Reading the initialized flag cannot make traversal atomic. Use normal symbol resolution to obtain a callable handle after the required library is loaded.

Payload layout comes from MachOKit. The prebound flag follows MachOKit 0.53.0's interpretation, whose verification against a published dyld implementation remains an upstream follow-up. Parsing this metadata does not establish arm64e.x1 invocation support.
