# Symbols and images

Find native declarations, select their images, and manage loading and symbol lifetime.

## Overview

Start with <doc:SymbolLookup> to resolve a declaration by source-level name or exact symbol spelling. Use <doc:ImageLoading> to choose whether a lookup can acquire an image, and <doc:LazyLibraries> to inspect lazy-load metadata.

## Topics

### Symbol lookup

- <doc:SymbolLookup>
- ``ABIRuntime``
- ``ImageSelector``
- ``NativeDeclaration``
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

### Lazy-load diagnostics

- <doc:LazyLibraries>
- ``NativeLazyLibrary``
- ``NativeLazySymbol``

### Resolution errors

- ``ABIResolutionError``
