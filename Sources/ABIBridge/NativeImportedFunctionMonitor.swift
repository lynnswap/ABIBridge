import ABIBridgeRuntime
import ABIBridgeCore
import Foundation

/// One image's asynchronous import-hook outcome. Identity and path do not retain the image; successful or partially published hooks retain their own leases.
public struct NativeImportedImageUpdate: Sendable {
    /// The outcome when this update was produced.
    public enum State: Sendable {
        /// Registration succeeded; slot status can subsequently change.
        case installed(NativeImportedFunctionHook)
        /// The selected image has no matching imported declaration/provider.
        case noMatchingImports
        /// Lookup or installation failed. Partial effects are preserved by `NativeImportedHookInstallationError` when publication was attempted.
        case failed(any Error)
        /// This generation disappeared from the observed catalog.
        case removed
    }
    /// Identity of this particular load, without a loader lease.
    public let image: NativeImageIdentity
    /// Copied executable path reported by the image catalog.
    public let path: String
    /// Installation or removal outcome when this value was produced.
    public let state: State

    init(_ value: ABIImportedImageUpdate, declaration: NativeDeclaration) {
        let snapshot = ImageSnapshot(value.image)
        image = snapshot.identity; path = snapshot.path
        switch value.state {
        case Int32(ABIImportedImageInstalled):
            state = .installed(NativeImportedFunctionHook(ABIRetainImportedHook(value.hook)!))
        case Int32(ABIImportedImageNoMatch): state = .noMatchingImports
        case Int32(ABIImportedImageRemoved): state = .removed
        default:
            let error = importedHookFailure(value.failure!, declaration: declaration)
            if let handle = value.hook {
                let hook = NativeImportedFunctionHook(ABIRetainImportedHook(handle)!)
                let index = ABIImportedHookGetFailedIndex(handle)
                state = .failed(
                    NativeImportedHookInstallationError(
                        underlyingError: error,
                        failedIndex: index < 0 ? nil : index,
                        registration: hook
                    )
                )
            } else {
                state = .failed(error)
            }
        }
    }
}

/// Owns asynchronous registration on current and subsequently loaded images. Drop the last owner or call `invalidate()` to stop applying its callback. Each acquirable selected load is attempted once; per-image failures remain observable. Images still initializing are acquired asynchronously when ready.
public final class NativeImportedFunctionMonitor: @unchecked Sendable {
    let handle: OpaquePointer
    let declaration: NativeDeclaration
    init(_ handle: OpaquePointer, declaration: NativeDeclaration) {
        self.handle = handle; self.declaration = declaration
    }

    /// Copies the latest observed selected-image outcomes. Active monitors prune removed generations; invalidated monitors keep their final snapshot. Short-lived images can disappear before observation, so this is not an exhaustive event history.
    public var images: [NativeImportedImageUpdate] {
        let snapshot = ABIImportedHookMonitorCopyImages(handle)!
        defer { ABIReleaseImportedImageList(snapshot) }
        return (0..<ABIImportedImageListGetCount(snapshot)).map {
            NativeImportedImageUpdate(
                ABIImportedImageListGetImage(snapshot, $0),
                declaration: declaration
            )
        }
    }

    /// Stops observation and disables new callback entry without waiting for in-flight calls or loader work. An already preparing installation may finish with an inert pass-through entry before cleanup completes. Published image/code leases retain their process-lifetime contract.
    public func invalidate() { ABIInvalidateImportedHookMonitor(handle) }
    deinit { ABIReleaseImportedHookMonitor(handle) }
}

private final class ImportedMonitorCallbacks {
    let callback: FunctionCallbackBox
    let declaration: NativeDeclaration
    let update: @Sendable (NativeImportedImageUpdate) -> Void
    init(
        _ callback: FunctionCallbackBox,
        declaration: NativeDeclaration,
        update: @escaping @Sendable (NativeImportedImageUpdate) -> Void
    ) {
        self.callback = callback; self.update = update; self.declaration = declaration
    }
}

extension ABIRuntime {
    /// Applies a typed imported-function callback to current and future importers.
    ///
    /// Initial and subsequent image application runs asynchronously, with results delivered to `onImageUpdate` on a serial queue. An unloaded explicit scope is valid. Neither selector loads missing images. Updates may begin before this method returns. Installation failures do not stop other images.
    ///
    /// Invocation callbacks and `onFailure` retain the calling-thread and C ABI contracts of `hookImportedCalls`. Constructor calls and calls made before asynchronous application completes are not guaranteed interception. An unresolved lazy import can fail its one attempt for that generation; bind it normally before creating a new monitor to retry.
    ///
    /// Registration preparation runs on a worker without blocking the caller's executor. The request must describe a fixed signature.
    @unsafe public nonisolated func monitorImportedCalls<Result, each Argument>(
        _ request: NativeRequest<NativeFunctionRequest<Result, repeat each Argument>>,
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        onImageUpdate: @escaping @Sendable (NativeImportedImageUpdate) -> Void,
        body:
            @escaping @Sendable (
                NativeImportedFunctionInvocation<Result, repeat each Argument>, repeat each Argument
            ) throws -> Result
    ) async throws -> NativeImportedFunctionMonitor {
        try await NativePreparation.run {
            try unsafe self.monitorImportedCallsAndWait(
                request,
                in: importer,
                from: provider,
                onFailure: onFailure,
                onImageUpdate: onImageUpdate,
                body: body
            )
        }
    }

    /// Prepares an imported-call registration synchronously on the caller's thread.
    ///
    /// Image selection, incoming-thread callbacks, lifetime, and failures follow
    /// `monitorImportedCalls`. Returning does not wait for asynchronous image application.
    @unsafe public nonisolated func monitorImportedCallsAndWait<Result, each Argument>(
        _ request: NativeRequest<NativeFunctionRequest<Result, repeat each Argument>>,
        in importer: ImageSelector,
        from provider: ImageSelector? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        onImageUpdate: @escaping @Sendable (NativeImportedImageUpdate) -> Void,
        body:
            @escaping @Sendable (
                NativeImportedFunctionInvocation<Result, repeat each Argument>, repeat each Argument
            ) throws -> Result
    ) throws -> NativeImportedFunctionMonitor {
        let declaration = request.declaration.nativeDeclaration
        let signature = ((repeat each Argument) -> Result).self
        guard request.declaration.variadicFrom == nil else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Imported-call hooks require a fixed C ABI signature."
            )
        }
        let query = try withRuntimeErrors {
            try RuntimeImportedFunctionQuery(
                declaration: declaration.runtimeValue,
                importer: importer.runtimeValue,
                provider: provider?.runtimeValue
            )
        }
        let callback = try prepareImportedCallback(
            declaration: declaration,
            as: signature,
            onFailure: onFailure,
            body: body
        )
        let context = Unmanaged.passRetained(
            ImportedMonitorCallbacks(callback, declaration: declaration, update: onImageUpdate)
        ).toOpaque()
        let parameters: [OpaquePointer?] = callback.parameters.map(\.handle)
        var error: OpaquePointer?
        let handle = withExtendedLifetime(callback) {
            parameters.withUnsafeBufferPointer { types in
                ABICreateImportedHookMonitor(
                    query.retainedHandle(),
                    callback.result.handle,
                    types.baseAddress,
                    types.count,
                    context,
                    { context, call, _ in
                        invokeFunctionCallback(
                            Unmanaged<ImportedMonitorCallbacks>.fromOpaque(context!)
                                .takeUnretainedValue().callback,
                            call!
                        )
                    },
                    { context, error in
                        Unmanaged<ImportedMonitorCallbacks>.fromOpaque(context!)
                            .takeUnretainedValue().callback.reportNativeFailure(error!)
                    },
                    { context, update in
                        let callbacks = Unmanaged<ImportedMonitorCallbacks>.fromOpaque(context!)
                            .takeUnretainedValue()
                        callbacks.update(
                            NativeImportedImageUpdate(update, declaration: callbacks.declaration)
                        )
                    },
                    { context in Unmanaged<ImportedMonitorCallbacks>.fromOpaque(context!).release()
                    },
                    &error
                )
            }
        }
        guard let handle else { throw consumeImportedHookFailure(error, declaration: declaration) }
        return NativeImportedFunctionMonitor(handle, declaration: declaration)
    }
}
