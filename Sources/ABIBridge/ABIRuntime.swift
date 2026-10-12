import Foundation

/// Resolves declarations using shared image and symbol indexes.
///
/// Use ``shared`` to reuse indexes across callers, or create a runtime to own an
/// independent cache. Explicit resolution scopes acquire images by default. Image handles and
/// resolved symbols keep their images alive until the last owner releases them.
/// Searches prepare their indexes on demand. Swift function factories offer
/// async overloads that run search and ABI preparation on an independent worker.
/// Use `prepare(_:)` to start the same work early without occupying the caller's actor.
///
/// See <doc:SymbolLookup> for search scopes and the raw-address contract.
public actor ABIRuntime {
    /// A runtime whose indexes are shared across callers in this process.
    public static let shared = ABIRuntime(resolver: .shared)

    nonisolated let resolver: SymbolResolver
    nonisolated let swiftTypeCache = SwiftTypeCache()

    /// Creates a runtime with independent image and declaration indexes.
    public init() { resolver = SymbolResolver() }

    private init(resolver: SymbolResolver) { self.resolver = resolver }

    /// Returns retained handles for matching loaded images.
    ///
    /// Images that unload before a loader reference is acquired are omitted.
    /// Automatic enumeration also omits images whose initializers on another
    /// thread currently prevent acquiring a reference. Later calls can include
    /// them without an unload/reload or explicit cache reset.
    /// - Parameter selector: The search scope; defaults to all available loaded images.
    /// - Returns: Retained matching images, or an empty array when none are available.
    /// - Throws: A catalog error, or imageUnavailable if an explicitly selected
    ///   registered image cannot currently be retained.
    public nonisolated func images(
        matching selector: ImageSelector = .automatic
    ) throws -> [NativeImage] {
        try resolver.images(matching: selector)
    }

    /// Finds a declaration, acquiring an explicitly selected image when permitted.
    ///
    /// Loaded-image definitions take precedence. Shared-cache local symbols are
    /// searched only when no loaded-image definition matches. Multiple distinct
    /// definitions at the selected level produce an ambiguity error.
    ///
    /// - Parameters:
    ///   - declaration: A source-level or exact name and storage requirement.
    ///   - selector: The image scope; defaults to all loaded images.
    ///   - loading: Whether an explicit target may be acquired and initialized.
    /// - Returns: A symbol retaining its containing image.
    /// - Throws: ``ABIResolutionError`` for unavailable images, missing or
    ///   ambiguous declarations, unsupported languages, or invalid storage.
    public nonisolated func resolve(
        _ declaration: NativeDeclaration,
        in selector: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> ResolvedSymbol {
        try resolver.resolve(declaration, in: selector, loading: loading)
    }

    /// Finds a declaration in an already retained image.
    ///
    /// - Parameters:
    ///   - declaration: A source-level or exact name and storage requirement.
    ///   - image: The retained image whose index can be reused.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    /// - Returns: A resolved symbol retaining that image.
    /// - Throws: ``ABIResolutionError`` when the declaration cannot be resolved
    ///   unambiguously in the requested storage.
    public nonisolated func resolve(
        _ declaration: NativeDeclaration,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> ResolvedSymbol {
        try resolver.resolve(declaration, in: image, loading: loading)
    }

    /// Resolves a requirement with aliases and ordered image fallback.
    ///
    /// A later scope is tried only when an image or declaration is absent.
    /// Found aliases must agree on the address and image generation.
    /// - Parameter request: The declarations and ordered image scopes to search.
    /// - Returns: The first found declaration's symbol, retaining its image.
    /// - Throws: The lookup failure; ambiguity and invalid storage stop fallback.
    public nonisolated func resolve(_ request: NativeSymbolRequest) throws -> ResolvedSymbol {
        try resolver.resolve(request)
    }

    /// Resolves independent requirements, preserving input order and partial success.
    ///
    /// Retained images for each scope are reused within this batch, and symbol
    /// indexes use this runtime's existing cache. Results are independent; the
    /// batch is not an atomic snapshot of loader activity.
    /// - Parameter requests: Requirements to resolve, or an empty array.
    /// - Returns: One owned symbol or lookup error for each input requirement.
    public nonisolated func resolve(
        _ requests: [NativeSymbolRequest]
    ) -> [Result<ResolvedSymbol, any Error>] {
        resolver.resolve(requests)
    }

    /// Resolves a requirement early, warming the indexes used by later searches.
    ///
    /// Preparation is optional. Ordinary searches perform missing work and share
    /// any index construction already in progress. Preparation runs on an
    /// independent worker; awaiting it does not occupy the caller's actor.
    /// Ordinary synchronous searches may block their caller while preparing.
    /// This prepares symbol lookup, while typed factories prepare their call ABI.
    /// - Parameter request: The declarations and image scopes to prepare.
    /// - Returns: The resolved symbol, retaining its image.
    /// - Throws: The same lookup failures as ordinary resolution.
    public nonisolated func prepare(_ request: NativeSymbolRequest) async throws -> ResolvedSymbol {
        try await prepare { try $0.resolve(request) }
    }

    /// Prepares independent requirements, preserving input order and partial success.
    ///
    /// Each requirement shares the indexes used by ordinary searches. A search
    /// can reuse a completed index before this entire batch finishes.
    /// - Parameter requests: Requirements to prepare, or an empty array.
    /// - Returns: One owned symbol or lookup error for each input requirement.
    public nonisolated func prepare(
        _ requests: [NativeSymbolRequest]
    ) async -> [Result<ResolvedSymbol, any Error>] {
        await NativePreparation.run { self.resolve(requests) }
    }

    /// Prepares typed handles using the ordinary synchronous lookup APIs.
    ///
    /// The operation runs on an independent worker, using this runtime's indexes
    /// and shared native call interfaces. A synchronous lookup can reuse completed
    /// preparation or join the required index or call-interface work without waiting
    /// for the rest of this operation. Image loading and metadata discovery remain
    /// outside joinable work so native initialization can reenter the runtime.
    /// Native invocation is not performed unless the operation explicitly calls it.
    /// - Parameter operation: Synchronous lookups to start before their results are needed.
    /// - Returns: The prepared value, which can be retained for later synchronous calls.
    /// - Throws: The operation's error. Failure does not disable later lookups.
    public nonisolated func prepare<Value: Sendable>(
        _ operation: @escaping @Sendable (ABIRuntime) throws -> Value
    ) async throws -> Value {
        let result: Result<Value, any Error> = await NativePreparation.run {
            Result { try operation(self) }
        }
        return try result.get()
    }

    /// Releases cached declarations and image indexes.
    ///
    /// Existing image and symbol handles remain valid. Subsequent lookups rebuild
    /// indexes as needed. The process-lifetime native image catalog remains active.
    public nonisolated func removeCachedResults() {
        swiftTypeCache.removeCachedResults()
        resolver.removeCachedResults()
    }

}
