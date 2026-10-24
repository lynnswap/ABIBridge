# Symbols and images

Find native declarations, select their images, and manage loading and symbol lifetime.

## Overview

Start with <doc:SymbolLookup> to resolve a declaration by source-level name or exact symbol spelling. Use <doc:ImageLoading> to choose whether a lookup can acquire an image, <doc:ImageMetadata> to inspect its architecture and storage, and <doc:LazyLibraries> to inspect lazy-load metadata.

## Topics

### Symbol lookup

- <doc:SymbolLookup>
- ``ABIRuntime``
- ``ImageSelector``
- ``NativeDeclaration``
- ``NativeSymbolLookupRequest``
- ``NativeSymbolRequest``
- ``NativeSymbolNameForm``
- ``NativeLanguage``
- ``NativeSymbolKind``
- ``ResolvedSymbol``

### Image loading and lifetime

- <doc:ImageLoading>
- ``ImageLoadingPolicy``
- ``NativeImage``
- ``NativeImageIdentity``

### Loaded-image metadata

- <doc:ImageMetadata>
- ``NativeImageMetadata``
- ``NativeImageArchitecture``
- ``NativeImageSection``

### Lazy-load diagnostics

- <doc:LazyLibraries>
- ``NativeLazyLibrary``
- ``NativeLazySymbol``

### Resolution errors

- ``ABIResolutionError``
