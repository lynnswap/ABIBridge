#ifndef ABIBRIDGE_INSPECTION_H
#define ABIBRIDGE_INSPECTION_H

#include <ABIBridge/Memory.h>
#include <ABIBridge/PointerSearch.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// An owned immutable catalog snapshot. Free it with ABIFreeImageList.
/// Snapshot entries describe loads but do not keep those images loaded.
typedef struct ABIImageList ABIImageList;
/// An owned loader reference to one image generation.
typedef struct ABIImageLease ABIImageLease;
/// An owned resolver reference. Independent runtimes have independent caches.
typedef struct ABISymbolRuntime ABISymbolRuntime;
/// An owned immutable symbol that keeps its implementation image loaded.
typedef struct ABIResolvedSymbol ABIResolvedSymbol;
/// An owned failure with an immutable category and UTF-8 message.
typedef struct ABIResolutionFailure ABIResolutionFailure;

/// A description of one image load. Copying this value does not retain an image.
/// Strings and addresses are borrowed; their owners are documented by each getter.
typedef struct {
    /// In-process address of the Mach-O header.
    uintptr_t header;
    /// Displacement applied to link-time virtual addresses.
    intptr_t slide;
    /// Process-local load identity. A later load receives a new generation.
    uint64_t generation;
    /// LC_UUID bytes, or zero bytes when the image has no UUID.
    uint8_t uuid[16];
    /// Null-terminated path borrowed from the snapshot or resolved symbol.
    const char *path;
} ABIImageInfo;

/// Source-language values for ABIResolveSymbol.
enum {
    ABILanguageSwift = 0,
    /// Reserved for Objective-C declarations; symbol lookup currently reports
    /// ABIFailureUnsupportedDeclaration. Selector dispatch uses the Swift API.
    ABILanguageObjectiveC = 1,
    ABILanguageC = 2,
    ABILanguageCXX = 3
};
/// Required storage kind. A symbol in an incompatible section is not returned.
enum { ABISymbolFunction = 0, ABISymbolData = 1, ABISymbolVTable = 2 };
/// Loaded-image search scope. A framework selector omits ".framework"; a path
/// selector names the executable. None of these values loads a missing image.
enum { ABIImageAutomatic = 0, ABIImageFramework = 1, ABIImagePath = 2 };
/// Failure categories. Preserve the message for declaration-specific detail.
/// Callers should handle unknown future categories as unspecified failures.
enum {
    ABIFailureImageUnavailable = 1, ABIFailureImageNotLoaded = 2,
    ABIFailureDeclarationNotFound = 3, ABIFailureAmbiguousDeclaration = 4,
    ABIFailureSignatureMismatch = 5, ABIFailureUnsupportedDeclaration = 6,
    ABIFailureMetadataUnavailable = 7, ABIFailureImageChanged = 8,
    ABIFailureInvalidAddress = 9, ABIFailureInvalidRequest = 10,
    ABIFailureOther = 11
};

/// Copies the current catalog. The caller frees a non-null result with
/// ABIFreeImageList. Returns null if the catalog/callback image cannot be
/// initialized and retained; this operation has no detailed failure output.
ABIImageList *ABICopyLoadedImages(void);
/// Returns the entry count. The list must be non-null and remain alive.
size_t ABIImageListCount(const ABIImageList *list);
/// Copies an entry. The non-null list must remain alive, and index must be less
/// than its count. The returned path remains valid until the list is freed.
/// The image itself may unload; acquire a lease before using its addresses.
ABIImageInfo ABIImageListGet(const ABIImageList *list, size_t index);
/// Releases a snapshot and its path strings. Null is accepted.
void ABIFreeImageList(ABIImageList *list);

/// Acquires an independent loader reference to the given generation without
/// loading a missing image. Returns null if the generation disappeared or its
/// loader reference could not be acquired. Release success with ABIReleaseImage.
ABIImageLease *ABIRetainLoadedImage(uint64_t generation);
/// Releases one loader reference. Null is accepted. The loader/runtime decides
/// whether the image can physically unload when the last reference is released.
void ABIReleaseImage(ABIImageLease *lease);

/// Creates an owned independent resolver. Release it with ABIReleaseSymbolRuntime.
ABISymbolRuntime *ABICreateSymbolRuntime(void);
/// Acquires an owned reference to the resolver shared with ABIRuntime.shared.
/// Release every acquired reference, even if two references have equal addresses.
ABISymbolRuntime *ABICopySharedSymbolRuntime(void);
/// Releases an acquired non-null runtime reference. Existing symbol handles
/// remain valid. Do not race release of a reference with operations using it.
void ABIReleaseSymbolRuntime(ABISymbolRuntime *runtime);
/// Clears cached results on a live non-null runtime. Existing symbols remain
/// valid. Resolution and cache clearing may be performed concurrently.
void ABIRuntimeRemoveCachedResults(ABISymbolRuntime *runtime);

/// Resolves a source-level declaration in loaded images. Name and non-null
/// runtime must remain valid for the call. Strings are null-terminated UTF-8;
/// C++/Swift names are demangled declarations, and C names omit the Mach-O "_".
///
/// Automatic scope ignores selector, which may be null. Framework/path scope
/// requires selector. Invalid enum values or a missing required selector report
/// ABIFailureInvalidRequest. Ambiguity is reported rather than selecting a load.
///
/// On success, returns an owned symbol and writes null to error when supplied.
/// On failure, returns null and writes an owned failure when error is supplied.
/// The previous value in *error is overwritten, not released. Each non-null
/// result/failure has exactly one owned reference; release it with its matching
/// function. Pass null for error when no failure detail is needed.
///
/// Calls may share a live runtime concurrently. Lookup reuses the Swift
/// frontend's backend and does not establish a call signature, object layout,
/// pointer-authentication schema, or pointee lifetime.
ABIResolvedSymbol *ABIResolveSymbol(
    ABISymbolRuntime *runtime, const char *name, int32_t language, int32_t kind,
    int32_t scope, const char *selector, ABIResolutionFailure **error);
/// Releases a non-null owned symbol and its image reference. A copied handle
/// pointer is borrowed, not another owned reference. Do not race final release
/// with operations using the same symbol.
void ABIReleaseResolvedSymbol(ABIResolvedSymbol *symbol);
/// Returns the non-null unsigned address borrowed from a live non-null symbol.
/// Keep the symbol or an independent image lease alive while using the address.
/// Calling code at this address additionally requires the actual native ABI
/// and any function-pointer authentication required by the calling convention.
const void *ABIResolvedSymbolAddress(const ABIResolvedSymbol *symbol);
/// Copies image identity into non-null output storage. The symbol must be live
/// and non-null. The path is borrowed from the symbol until it is released,
/// even when an independent image lease keeps the underlying image loaded.
void ABIResolvedSymbolImage(const ABIResolvedSymbol *symbol, ABIImageInfo *image);

/// Returns the category of a live non-null failure.
int32_t ABIResolutionFailureCode(const ABIResolutionFailure *error);
/// Returns a UTF-8 message borrowed until the live non-null failure is released.
/// Copy the message if it needs to outlive the failure handle.
const char *ABIResolutionFailureMessage(const ABIResolutionFailure *error);
/// Releases an owned failure. Null is accepted.
void ABIReleaseResolutionFailure(ABIResolutionFailure *error);

#ifdef __cplusplus
}
#endif
#endif
