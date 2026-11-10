import Foundation

/// Resolves declarations using shared image and symbol indexes.
///
/// Use ``shared`` to reuse completed resolutions across callers, or create a runtime with independent caches. Search indexes are shared by overlapping lookups and released when the last lookup or ``prepare(_:)`` batch finishes. Explicit scopes acquire images by default. Image and symbol handles retain their images until the last owner releases them.
///
/// Searches prepare indexes on demand. Async resolution moves search and call preparation to a worker; bound Objective-C receiver callbacks and C++ virtual-slot capture stay on the caller's executor. `resolve…AndWait` factories run on the caller's thread and wait for any required work already in progress. Use `prepare(_:)` to start that work early without occupying the caller's actor.
///
/// See <doc:SymbolLookup> for search scopes and the raw-address contract.
public final class ABIRuntime: Sendable {
    /// Independently removable caches owned by a runtime.
    public enum Cache: CaseIterable, Hashable, Sendable {
        /// Symbol indexes, parsed declarations, image acquisitions, and symbol lookup results.
        /// Removing this cache preserves prepared Swift calls and types.
        case symbolLookup
        /// Completed Swift function, member, and key-path resolutions.
        case swiftResolutions
        /// Resolved Swift type handles.
        case swiftTypes
    }

    /// A runtime whose completed resolutions are shared across callers in this process.
    public static let shared = ABIRuntime(resolver: .shared, resolutionCache: .shared)

    let resolver: SymbolResolver
    let swiftTypeCache = SwiftTypeCache()
    let swiftResolutionCache: SwiftResolutionCache

    /// Creates a runtime with independent resolution caches.
    public init() {
        let cache = SwiftResolutionCache()
        swiftResolutionCache = cache
        resolver = SymbolResolver(resolutionCache: cache)
    }

    init(resolver: SymbolResolver, resolutionCache: SwiftResolutionCache = SwiftResolutionCache()) {
        swiftResolutionCache = resolutionCache
        self.resolver = SymbolResolver(resolver.runtime, resolutionCache: resolutionCache)
    }

    /// Returns retained handles for matching loaded images.
    ///
    /// Images that unload before a loader reference is acquired are omitted. Automatic enumeration also omits images whose initializers on another thread currently prevent acquiring a reference. Later calls can include them without an unload/reload or explicit cache reset.
    /// - Parameter selector: The search scope; defaults to all available loaded images.
    /// - Returns: Retained matching images, or an empty array when none are available.
    /// - Throws: A catalog error, or imageUnavailable if an explicitly selected
    ///   registered image cannot currently be retained.
    public func resolveImagesAndWait(
        matching selector: ImageSelector = .automatic
    ) throws -> [NativeImage] {
        try resolver.images(matching: selector)
    }

    /// Returns retained handles for matching loaded images on a worker queue.
    ///
    /// This has the same scope and ownership contract as `resolveImagesAndWait(matching:)`. The caller suspends while image enumeration runs independently of its actor.
    public func resolveImages(
        matching selector: ImageSelector = .automatic
    ) async throws -> [NativeImage] {
        try await NativePreparation.run { try self.resolveImagesAndWait(matching: selector) }
    }

    /// Finds a declaration, acquiring an explicitly selected image when permitted.
    ///
    /// Loaded-image definitions take precedence. Shared-cache local symbols are searched only when no loaded-image definition matches. Multiple distinct definitions at the selected level produce an ambiguity error.
    ///
    /// - Parameters:
    ///   - request: A language-qualified source-level or exact name and storage requirement.
    ///   - selector: The image scope; defaults to all loaded images.
    ///   - loading: Whether an explicit target may be acquired and initialized.
    /// - Returns: A symbol retaining its containing image.
    /// - Throws: ``ABIResolutionError`` for unavailable images, missing or
    ///   ambiguous declarations, unsupported languages, or invalid storage.
    public func resolveAndWait(
        _ request: NativeRequest<NativeSymbolLookupRequest>,
        in selector: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> ResolvedSymbol {
        try resolver.resolve(request.declaration.declaration, in: selector, loading: loading)
    }

    /// Finds a declaration in an already retained image.
    ///
    /// - Parameters:
    ///   - request: A language-qualified source-level or exact name and storage requirement.
    ///   - image: The retained image to search.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    /// - Returns: A resolved symbol retaining that image.
    /// - Throws: ``ABIResolutionError`` when the declaration cannot be resolved
    ///   unambiguously in the requested storage.
    public func resolveAndWait(
        _ request: NativeRequest<NativeSymbolLookupRequest>,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> ResolvedSymbol {
        try resolver.resolve(request.declaration.declaration, in: image, loading: loading)
    }

    /// Resolves a requirement with aliases and ordered image fallback.
    ///
    /// A later scope is tried only when an image or declaration is absent. Found aliases must agree on the address and image generation.
    /// - Parameter request: The declarations and ordered image scopes to search.
    /// - Returns: The first found declaration's symbol, retaining its image.
    /// - Throws: The lookup failure; ambiguity and invalid storage stop fallback.
    public func resolveAndWait(_ request: NativeSymbolRequest) throws -> ResolvedSymbol {
        try resolver.resolve(request)
    }

    /// Resolves independent requirements, preserving input order and partial success.
    ///
    /// Retained images and working symbol indexes are reused within this batch. Results are independent; the batch is not an atomic snapshot of loader activity.
    /// - Parameter requests: Requirements to resolve, or an empty array.
    /// - Returns: One owned symbol or lookup error for each input requirement.
    public func resolveAndWait(
        _ requests: [NativeSymbolRequest]
    ) -> [Result<ResolvedSymbol, any Error>] {
        resolver.resolve(requests)
    }

    /// Finds a declaration on a worker, performing or joining its required preparation.
    ///
    /// This has the same resolution and image-retention contract as `resolveAndWait(_:in:loading:)`. Search, image acquisition, and index preparation run independently of the caller's actor.
    public func resolve(
        _ request: NativeRequest<NativeSymbolLookupRequest>,
        in selector: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) async throws -> ResolvedSymbol {
        try await NativePreparation.run {
            try self.resolveAndWait(request, in: selector, loading: loading)
        }
    }

    /// Finds a declaration in a retained image on a worker queue.
    public func resolve(
        _ request: NativeRequest<NativeSymbolLookupRequest>,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) async throws -> ResolvedSymbol {
        try await NativePreparation.run {
            try self.resolveAndWait(request, in: image, loading: loading)
        }
    }

    /// Resolves aliases and ordered image fallback on a worker queue.
    public func resolve(_ request: NativeSymbolRequest) async throws -> ResolvedSymbol {
        try await NativePreparation.run { try self.resolveAndWait(request) }
    }

    /// Resolves independent requirements on a worker, preserving order and partial success.
    ///
    /// Each result retains its image. The batch is not an atomic snapshot of loader activity, and other searches join only their required preparation.
    public func resolve(
        _ requests: [NativeSymbolRequest]
    ) async -> [Result<ResolvedSymbol, any Error>] {
        await NativePreparation.run { self.resolveAndWait(requests) }
    }

    /// Prepares typed handles using the synchronous lookup APIs.
    ///
    /// The operation runs on a worker and shares lookup indexes for the duration of the closure. Indexes are released after the last overlapping lookup or preparation finishes. Native call interfaces, resolved Swift types, and completed Swift calls remain cached for reuse. Equivalent Swift requests reuse completed handles even when this operation's result is discarded. Lookup may load images and run their initializers on that worker. Calling a prepared function remains an explicit operation.
    ///
    /// - Parameter operation: Synchronous lookups to start before their results are needed.
    /// - Returns: The prepared value, which can be retained for later calls.
    /// - Throws: The operation's error. Failure does not disable later lookups.
    public func prepare<Value: Sendable>(
        _ operation: @escaping @Sendable (ABIRuntime) throws -> Value
    ) async throws -> Value {
        try await NativePreparation.run {
            try self.resolver.withCachedLookups { try operation(self) }
        }
    }

    /// Shares working lookup indexes across asynchronous preparation.
    ///
    /// The closure keeps the caller's actor isolation, including access to values
    /// that are not Sendable. Use asynchronous resolution inside it to keep
    /// symbol scanning off that actor. Indexes are released when the last
    /// overlapping lookup or batch finishes, including after an error.
    /// Completed resolutions remain available outside the batch.
    ///
    /// - Parameters:
    ///   - isolation: The caller's actor isolation, inherited by default.
    ///   - operation: Related lookups to prepare in one batch.
    /// - Returns: The closure's result, in the caller's isolation domain.
    public func prepare<Value>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: (ABIRuntime) async throws -> Value
    ) async rethrows -> Value {
        try await resolver.withCachedLookups(isolation: isolation) {
            try await operation(self)
        }
    }

    /// Releases all of this runtime's removable caches.
    ///
    /// Existing handles remain valid. Use ``removeCachedResults(in:)`` to retain unselected caches.
    public func removeCachedResults() {
        removeCachedResults(in: Set(Cache.allCases))
    }

    /// Releases the selected caches.
    ///
    /// Removing `.symbolLookup` invalidates file-path acquisitions synchronously. Select it after changing a managed library file or symbolic link when subsequent lookups must use the new target without waiting for file notifications.
    ///
    /// Existing image, symbol, and callable handles remain valid, and in-progress resolutions may finish. Subsequent lookups rebuild only the removed caches. This does not clear the process-shared call-interface cache or the native image catalog.
    ///
    /// Use `[.symbolLookup]` to release search indexes while retaining prepared Swift calls and types.
    /// Passing an empty set leaves all caches intact.
    /// - Parameter caches: The caches to remove.
    public func removeCachedResults(in caches: Set<Cache>) {
        if caches.contains(.swiftResolutions) || caches.contains(.swiftTypes) {
            swiftResolutionCache.removeCachedResults(in: caches)
        }
        if caches.contains(.swiftTypes) { swiftTypeCache.removeCachedResults() }
        if caches.contains(.symbolLookup) { resolver.removeCachedResults() }
    }

}
