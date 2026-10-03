#ifndef ABIBRIDGE_SWIFT_CALLBACKS_H
#define ABIBRIDGE_SWIFT_CALLBACKS_H
#include <ABIBridge/SwiftInvocation.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ABISwiftCallback ABISwiftCallback;
typedef struct ABISwiftIncomingCall ABISwiftIncomingCall;
typedef struct ABISwiftClosureCallback ABISwiftClosureCallback;

/// Moves an initialized native result value into the caller's uninitialized
/// indirect output storage. Called only after successful callback completion.
/// logicalOffset and size select a prepared projection of the logical result;
/// they do not establish type compatibility. source and destination contain one
/// complete native value or field, never a partial register/optional carrier.
/// The operation cannot fail and leaves source uninitialized. It may use value
/// witnesses retained by context; the call-interface cache owns no metadata.
/// Zero-sized outputs need no storage transfer and do not call this initializer.
/// A null initializer retains the low-level API's bitwise-transfer contract.
typedef void (*ABISwiftResultInitializer)(void *context, size_t logicalOffset, size_t size,
                                        void *destination, void *source);

/// The callback borrows native Swift argument storage and must initialize one
/// owned result with the prepared signature. It cannot fail or throw through
/// this nonthrowing Swift boundary.
typedef struct ABISwiftClosureCallbackFunctions {
    void (*invoke)(void *context, void *const *arguments, void *result);
    /// Dispatch using the native Swift context instead of the registration context.
    /// The native context must own this callback's entry through its final call.
    bool usesNativeContext;
    void (*releaseContext)(void *context);
    /// Returns a retained Swift class instance holding code leases, or null.
    /// It must not retain callback captures. The caller uses swift_release.
    void *(*copyCodeOwner)(void *context);
    /// Optional retained Swift owner for preparing this body with another ABI.
    /// Unlike code leases, it may retain captures and belongs only to live closures.
    void *(*copyBodyOwner)(void *context);
    ABISwiftResultInitializer initializeResult;
} ABISwiftClosureCallbackFunctions;

/// Returns true after initializing an owned error, false after initializing
/// the ordinary result. Error storage is null for a nonthrowing interface.
typedef struct ABISwiftThrowingClosureCallbackFunctions {
    bool (*invoke)(void *context, void *const *arguments, void *result, void *errorResult);
    bool usesNativeContext;
    void (*releaseContext)(void *context);
    /// Same code-only ownership contract as ABISwiftClosureCallbackFunctions.
    void *(*copyCodeOwner)(void *context);
    /// Optional retained Swift owner for preparing this body with another ABI.
    /// Unlike code leases, it may retain captures and belongs only to live closures.
    void *(*copyBodyOwner)(void *context);
    ABISwiftResultInitializer initializeResult;
} ABISwiftThrowingClosureCallbackFunctions;
ABISwiftClosureCallback *ABICreateSwiftThrowingClosureCallback(ABISwiftCallInterface *interface,
    ABISwiftThrowingClosureCallbackFunctions functions, void *context, ABIResolutionFailure **error);

/// Owns generated concrete closure entry code. Unlike a hook, this entry has
/// no predecessor or invalidation operation. Success consumes context; failure
/// consumes neither context nor its release responsibility.
ABISwiftClosureCallback *ABICreateSwiftClosureCallback(ABISwiftCallInterface *interface,
    ABISwiftClosureCallbackFunctions functions, void *context, ABIResolutionFailure **error);
ABIUnmanagedFunction ABISwiftClosureCallbackFunction(const ABISwiftClosureCallback *callback);
/// Requires that the last native closure context and all in-flight calls have ended.
void ABIReleaseSwiftClosureCallback(ABISwiftClosureCallback *callback);
/// Whether this live entry belongs to the closure allocator. Such a closure's
/// native heap context owns its callback code and captures.
bool ABIIsSwiftClosureCallbackFunction(ABIUnmanagedFunction function);
/// Copies a callback's code-only Swift owner, if supplied. The live native
/// closure must remain retained during this operation. Release with swift_release.
void *ABICopySwiftClosureCallbackCodeOwner(ABIUnmanagedFunction function, void *nativeContext);
void *ABICopySwiftClosureCallbackBodyOwner(ABIUnmanagedFunction function, void *nativeContext);

typedef struct ABISwiftAsyncClosureCallback ABISwiftAsyncClosureCallback;
typedef struct ABISwiftAsyncClosureCallbackFunctions {
    /// Returns an owned compiler-stored () async -> Void body with the
    /// interface's caller-isolated or concurrent convention. Its generic
    /// representation has an indirect empty result. The body
    /// initializes result or errorResult and sets didThrow before completing.
    /// All borrowed argument storage remains live through that completion.
    ABISwiftClosureValue (*createBody)(void *context, void *const *arguments,
                                      void *result, void *errorResult, bool *didThrow);
    bool usesNativeContext;
    void (*releaseContext)(void *context);
    void *(*copyCodeOwner)(void *context);
    /// Optional retained Swift owner for preparing this body with another ABI.
    /// Unlike code leases, it may retain captures and belongs only to live closures.
    void *(*copyBodyOwner)(void *context);
    ABISwiftResultInitializer initializeResult;
} ABISwiftAsyncClosureCallbackFunctions;
/// Success consumes context; failure consumes neither context nor its release
/// responsibility. Native closure contexts keep the callback alive through all calls.
ABISwiftAsyncClosureCallback *ABICreateSwiftAsyncClosureCallback(ABISwiftAsyncCallInterface *interface,
    ABISwiftAsyncClosureCallbackFunctions functions, void *context, ABIResolutionFailure **error);
const void *ABISwiftAsyncClosureCallbackDescriptor(const ABISwiftAsyncClosureCallback *callback);
void ABIReleaseSwiftAsyncClosureCallback(ABISwiftAsyncClosureCallback *callback);
bool ABIIsSwiftAsyncClosureCallbackFunction(ABIUnmanagedFunction function);
void *ABICopySwiftAsyncClosureCallbackCodeOwner(ABIUnmanagedFunction function, void *nativeContext);
void *ABICopySwiftAsyncClosureCallbackBodyOwner(ABIUnmanagedFunction function, void *nativeContext);

/// Functions describing one callback and its native value ownership. None may
/// throw a language exception through this C boundary. The borrowed invocation
/// is usable only during invoke, on its entering thread.
typedef struct ABISwiftCallbackFunctions {
    void (*invoke)(void *context, ABISwiftIncomingCall *call);
    void (*releaseContext)(void *context);
    /// Destroys an owned native result that was superseded or not returned.
    /// Null is appropriate for trivially destructible result storage.
    void (*destroyResult)(void *context, void *result);
    /// Releases incoming consumed arguments/self when the untouched fallback
    /// did not consume them. Ordinary guaranteed arguments need no destructor.
    void (*destroyConsumedArguments)(void *context, const void *receiver, void *const *arguments, size_t count);
} ABISwiftCallbackFunctions;

/// Creates a native Swift entry from a copied concrete call interface and a
/// nonnull fallback with the same physical ABI. Executable bytes are precompiled
/// and remapped; no generated writable executable code is used.
/// On success this takes ownership of context and fallbackOwner through their
/// release functions; failure consumes neither. Keep fallback code alive via
/// fallbackOwner or a lifetime managed by the caller.
ABISwiftCallback *ABICreateSwiftCallback(ABISwiftCallInterface *interface,
    ABIUnmanagedFunction fallback, ABISwiftCallbackFunctions functions, void *context,
    void *fallbackOwner, void (*releaseFallbackOwner)(void *), ABIResolutionFailure **error);
/// Borrows code while the callback remains alive. A published entry's owner must
/// outlive all saved native pointers, including after logical invalidation.
ABIUnmanagedFunction ABISwiftCallbackFunction(const ABISwiftCallback *callback);
/// Releases captures once already-entered callbacks finish. Future entries call
/// the fallback with their original register/stack arguments and Swift context.
void ABIClearSwiftCallback(ABISwiftCallback *callback);
/// Requires no future or in-flight users of the borrowed code address.
void ABIReleaseSwiftCallback(ABISwiftCallback *callback);

size_t ABISwiftIncomingArgumentCount(const ABISwiftIncomingCall *call);
const void *ABISwiftIncomingContext(const ABISwiftIncomingCall *call);
bool ABISwiftIncomingReadArgument(ABISwiftIncomingCall *call, size_t index,
    void *output, size_t size, ABIResolutionFailure **error);
/// Calls the captured fallback with supplied storage and receiver context. Each
/// successful completion replaces the previous completed result. It does not
/// change the incoming arguments used by automatic fallback. Consumed values
/// and self require independently owned copies for each call.
bool ABISwiftIncomingProceed(ABISwiftIncomingCall *call, void *const *arguments, size_t count,
    const void *receiver, ABIResolutionFailure **error);
/// Copies borrowed result bits. Nontrivial callers make their own value copy;
/// the invocation still owns this result until it is replaced or returned.
bool ABISwiftIncomingCopyResult(ABISwiftIncomingCall *call, void *output, size_t size,
    ABIResolutionFailure **error);
/// Transfers an independently owned result into this invocation on success.
/// The source must not subsequently destroy the transferred value. No result
/// assignment means the latest completed result, or untouched fallback if none.
bool ABISwiftIncomingSetResult(ABISwiftIncomingCall *call, const void *value, size_t size,
    ABIResolutionFailure **error);

#ifdef __cplusplus
}
#endif
#endif
