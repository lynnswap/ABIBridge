import Foundation

/// Resolves declarations using shared image and symbol indexes.
///
/// Use ``shared`` to reuse indexes across callers, or create a runtime to own an
/// independent cache. Methods do not load missing frameworks. Image handles and
/// resolved symbols keep their images alive until the last owner releases them.
///
/// See <doc:SymbolLookup> for search scopes and the raw-address contract.
public actor ABIRuntime {
    /// A runtime whose indexes are shared across callers in this process.
    public static let shared = ABIRuntime(resolver: .shared)

    let resolver: SymbolResolver
    var swiftTypes: [SwiftTypeCacheKey: NativeSwiftType] = [:]

    /// Creates a runtime with independent image and declaration indexes.
    public init() { resolver = SymbolResolver() }

    private init(resolver: SymbolResolver) { self.resolver = resolver }

    /// Returns retained handles for matching loaded images.
    ///
    /// Images that unload before a loader reference is acquired are omitted.
    /// - Parameter selector: The search scope; defaults to all loaded images.
    /// - Returns: Matching images, or an empty array when none are loaded.
    /// - Throws: A catalog error, or an image-change error if a still-loaded
    ///   generation cannot be retained.
    public func images(matching selector: ImageSelector = .automatic) throws -> [NativeImage] {
        try resolver.images(matching: selector)
    }

    /// Finds a declaration within a loaded-image search scope.
    ///
    /// Loaded-image definitions take precedence. Shared-cache local symbols are
    /// searched only when no loaded-image definition matches. Multiple distinct
    /// definitions at the selected level produce an ambiguity error.
    ///
    /// - Parameters:
    ///   - declaration: A source-level name and storage requirement.
    ///   - selector: The image scope; defaults to all loaded images.
    /// - Returns: A symbol retaining its containing image.
    /// - Throws: ``ABIResolutionError`` for unavailable images, missing or
    ///   ambiguous declarations, unsupported languages, or invalid storage.
    public func resolve(
        _ declaration: NativeDeclaration,
        in selector: ImageSelector = .automatic
    ) throws -> ResolvedSymbol {
        try resolver.resolve(declaration, in: selector)
    }

    /// Finds a declaration in an already retained image.
    ///
    /// - Parameters:
    ///   - declaration: A source-level name and storage requirement.
    ///   - image: The retained image whose index can be reused.
    /// - Returns: A resolved symbol retaining that image.
    /// - Throws: ``ABIResolutionError`` when the declaration cannot be resolved
    ///   unambiguously in the requested storage.
    public func resolve(_ declaration: NativeDeclaration, in image: NativeImage) throws -> ResolvedSymbol {
        try resolver.resolve(declaration, in: image)
    }

    /// Resolves a requirement with aliases and ordered image fallback.
    ///
    /// A later scope is tried only when an image or declaration is absent.
    /// Found aliases must agree on the address and image generation.
    /// - Parameter request: The declarations and ordered image scopes to search.
    /// - Returns: The first found declaration's symbol, retaining its image.
    /// - Throws: The lookup failure; ambiguity and invalid storage stop fallback.
    public func resolve(_ request: NativeSymbolRequest) throws -> ResolvedSymbol {
        try resolver.resolve(request)
    }

    /// Resolves independent requirements, preserving input order and partial success.
    ///
    /// Retained images for each scope are reused within this batch, and symbol
    /// indexes use this runtime's existing cache. Results are independent; the
    /// batch is not an atomic snapshot of loader activity.
    /// - Parameter requests: Requirements to resolve, or an empty array.
    /// - Returns: One owned symbol or lookup error for each input requirement.
    public func resolve(
        _ requests: [NativeSymbolRequest]
    ) -> [Result<ResolvedSymbol, any Error>] {
        resolver.resolve(requests)
    }

    /// Releases cached image indexes.
    ///
    /// Existing image and symbol handles remain valid. Subsequent lookups rebuild
    /// indexes as needed. The process-lifetime native image catalog remains active.
    public func removeCachedResults() {
        swiftTypes.removeAll()
        resolver.removeCachedResults()
    }

}
