#ifndef ABIBRIDGE_IMPORTED_HOOK_MONITORING_H
#define ABIBRIDGE_IMPORTED_HOOK_MONITORING_H
#include <ABIBridge/ImportedHooks.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABIImportedHookMonitor ABIImportedHookMonitor;
typedef struct ABIImportedImageList ABIImportedImageList;
enum { ABIImportedImageInstalled = 0, ABIImportedImageNoMatch = 1, ABIImportedImageFailed = 2, ABIImportedImageRemoved = 3 };
/// Fields are borrowed from the image-update callback or owning snapshot.
/// A failed installation may carry a hook with per-slot partial effects.
typedef struct {
    ABIImageInfo image;
    int32_t state;
    ABIImportedHook *hook;
    const ABIResolutionFailure *failure;
} ABIImportedImageUpdate;
typedef void (*ABIImportedImageHandler)(void *context, ABIImportedImageUpdate update);

/// Monitors current and subsequently loaded importers asynchronously. Unloaded
/// explicit scopes are valid. onImageUpdate reports per-image installation and
/// removal; onFailure reports invocation errors. Both handlers are required.
/// Constructor calls and short-lived loads that disappear before observation
/// are not guaranteed to be intercepted. Neither scope loads missing images.
///
/// Context ownership follows ABIInstallImportedFunctionHook. Returns null with
/// an owned failure on preparation failure. Updates may start before return.
ABIImportedHookMonitor *ABIMonitorImportedFunction(const ABIDeclaration *, ABIImageSelector importer,
    const ABIImageSelector *provider, const ABIValueType *result, const ABIValueType *const *parameters,
    size_t count, void *context, ABIImportedCallback, ABIImportedFailureHandler,
    ABIImportedImageHandler onImageUpdate, ABIImportedContextRelease, ABIResolutionFailure **error);
/// Stops observation and disables new callback entries without waiting for
/// loader work or in-flight calls. Pending preparation may publish an inert
/// pass-through entry before retiring. Published image/code leases remain
/// process-lived, following the ordinary imported-hook lifetime contract.
void ABIInvalidateImportedHookMonitor(ABIImportedHookMonitor *);
void ABIReleaseImportedHookMonitor(ABIImportedHookMonitor *);
/// Owned immutable snapshot of selected current image outcomes. Installed hooks
/// can still be invalidated or displaced after this copy. Free with its release.
ABIImportedImageList *ABICopyImportedHookMonitorImages(const ABIImportedHookMonitor *);
size_t ABIImportedImageListCount(const ABIImportedImageList *);
ABIImportedImageUpdate ABIImportedImageListGet(const ABIImportedImageList *, size_t index);
void ABIReleaseImportedImageList(ABIImportedImageList *);

// Internal request bridge. Query ownership transfers into create, including failure.
typedef struct ABIImportedQuery ABIImportedQuery;
void ABIReleaseImportedQuery(ABIImportedQuery *);
ABIImportSelection *ABICopyImportedSelectionForImage(const ABIImportedQuery *, ABIImageInfo, ABIResolutionFailure **);
ABIImportedHookMonitor *ABICreateImportedHookMonitor(ABIImportedQuery *, const ABIValueType *,
    const ABIValueType *const *, size_t, void *, ABIImportedCallback, ABIImportedFailureHandler,
    ABIImportedImageHandler, ABIImportedContextRelease, ABIResolutionFailure **);
#ifdef __cplusplus
}
#endif
#endif
