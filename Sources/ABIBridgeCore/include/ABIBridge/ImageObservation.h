#ifndef ABIBRIDGE_IMAGE_OBSERVATION_H
#define ABIBRIDGE_IMAGE_OBSERVATION_H
#include <ABIBridge/Inspection.h>

#ifdef __cplusplus
extern "C" {
#endif

// Internal asynchronous catalog boundary for ongoing import registrations.
typedef struct ABIImageObservation ABIImageObservation;
typedef void (*ABIImageObservationHandler)(void *context, const ABIImageList *snapshot);
typedef void (*ABIImageObservationRelease)(void *context);

/// Delivers an initial catalog snapshot and coalesced changes on a private serial
/// queue, outside dyld callbacks and catalog locks. The snapshot is borrowed only
/// during delivery and does not retain images. Transient loads may disappear
/// before delivery; this is current-state observation, not an event history.
///
/// A nonnull release transfers context on entry, including failure. A null
/// release rejects the request without taking context. Returns null with an
/// owned failure if initialization fails. Handler/release must not throw across
/// the native boundary and their code must outlive their retained context.
ABIImageObservation *ABIObserveLoadedImages(void *context, ABIImageObservationHandler handler,
    ABIImageObservationRelease release, ABIResolutionFailure **error);

/// Idempotent and callable from delivery or a library constructor. Stops future
/// snapshots without waiting for a callback already captured by the worker.
/// Context release runs outside locks after the final in-flight delivery ends.
void ABIInvalidateImageObservation(ABIImageObservation *observation);
/// Invalidates and frees one owner. Null is accepted; do not race release with
/// another operation on the same owner.
void ABIReleaseImageObservation(ABIImageObservation *observation);

#ifdef __cplusplus
}
#endif
#endif
