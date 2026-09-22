#ifndef ABIBRIDGE_RUNTIME_H
#define ABIBRIDGE_RUNTIME_H

#include <ABIBridgeCore.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABISymbolRuntime ABISymbolRuntime;
typedef struct ABIResolvedSymbol ABIResolvedSymbol;
typedef struct ABIResolutionFailure ABIResolutionFailure;

/// Values accepted by ABIResolveSymbol's language argument.
enum {
    ABILanguageSwift = 0, ABILanguageObjectiveC = 1,
    ABILanguageC = 2, ABILanguageCXX = 3
};
/// Values accepted by ABIResolveSymbol's kind argument.
enum { ABISymbolFunction = 0, ABISymbolData = 1, ABISymbolVTable = 2 };
/// A framework selector omits ".framework"; a path selects the executable.
enum { ABIImageAutomatic = 0, ABIImageFramework = 1, ABIImagePath = 2 };
/// Stable failure categories; the message provides declaration-specific detail.
enum {
    ABIFailureImageUnavailable = 1, ABIFailureImageNotLoaded = 2,
    ABIFailureDeclarationNotFound = 3, ABIFailureAmbiguousDeclaration = 4,
    ABIFailureSignatureMismatch = 5, ABIFailureUnsupportedDeclaration = 6,
    ABIFailureMetadataUnavailable = 7, ABIFailureImageChanged = 8,
    ABIFailureInvalidAddress = 9, ABIFailureInvalidRequest = 10,
    ABIFailureOther = 11
};

/// Creates an independent resolver. The caller releases the returned reference.
ABISymbolRuntime *ABICreateSymbolRuntime(void);
/// Acquires a reference to the resolver shared with ABIRuntime.shared.
ABISymbolRuntime *ABICopySharedSymbolRuntime(void);
/// Releases a runtime reference. Existing symbol handles remain valid.
void ABIReleaseSymbolRuntime(ABISymbolRuntime *runtime);
/// Clears a runtime's indexes; safe to call concurrently with resolution.
void ABIRuntimeRemoveCachedResults(ABISymbolRuntime *runtime);

/// Resolves a UTF-8 declaration in loaded images. Does not load missing code.
/// The runtime and name must be non-null. Selector may be null only for
/// ABIImageAutomatic. On failure returns null and, if error is non-null, writes
/// an owned failure handle. On success writes null to error. The caller releases
/// either result. Resolution does not verify a function's signature or layout.
ABIResolvedSymbol *ABIResolveSymbol(
    ABISymbolRuntime *runtime, const char *name, int32_t language, int32_t kind,
    int32_t scope, const char *selector, ABIResolutionFailure **error);
/// Releases a symbol and its image reference.
void ABIReleaseResolvedSymbol(ABIResolvedSymbol *symbol);
/// Returns an unsigned address borrowed until symbol is released. Invocation
/// requires the actual native ABI and function-pointer signing where applicable.
const void *ABIResolvedSymbolAddress(const ABIResolvedSymbol *symbol);
/// Copies the image identity. The path is borrowed until symbol is released.
void ABIResolvedSymbolImage(const ABIResolvedSymbol *symbol, ABIImageInfo *image);

/// Returns a stable failure category.
int32_t ABIResolutionFailureCode(const ABIResolutionFailure *error);
/// Returns a UTF-8 message borrowed until error is released.
const char *ABIResolutionFailureMessage(const ABIResolutionFailure *error);
/// Releases a failure handle.
void ABIReleaseResolutionFailure(ABIResolutionFailure *error);

#ifdef __cplusplus
}
#endif
#endif
