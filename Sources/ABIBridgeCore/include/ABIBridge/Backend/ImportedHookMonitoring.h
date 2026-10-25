#pragma once
#include <ABIBridge/ImportedHookMonitoring.h>
#include <ABIBridge/Backend/ImportedHooks.h>

#ifdef __cplusplus
extern "C" {
#endif

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
