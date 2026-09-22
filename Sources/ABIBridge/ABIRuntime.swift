import Foundation

/// Resolves declarations using shared, actor-isolated image and symbol indexes.
///
/// Use ``shared`` to reuse indexes across callers, or create a runtime to own an
/// independent cache. Methods do not load missing frameworks. Image handles and
/// resolved symbols keep their images alive until the last owner releases them.
///
/// See <doc:SymbolLookup> for search scopes and the raw-address contract.
public actor ABIRuntime {
    /// A runtime whose indexes are shared across callers in this process.
    public static let shared = ABIRuntime()

    private var indexes: [NativeImageIdentity: SymbolIndex] = [:]
    private let sharedCache = SharedCacheSymbols()

    /// Creates a runtime with independent image and declaration indexes.
    public init() {}

    /// Returns retained handles for matching loaded images.
    ///
    /// - Parameter selector: The search scope; defaults to all loaded images.
    /// - Returns: Matching images, or an empty array when none are loaded.
    /// - Throws: A catalog error, or an image-change error if an image is
    ///   unloaded before a loader reference can be acquired.
    public func images(matching selector: ImageSelector = .automatic) throws -> [NativeImage] {
        try ImageSnapshot.current().filter { $0.matches(selector) }.map { snapshot in
            if let cached = indexes[snapshot.identity] { return cached.image }
            return try snapshot.retain()
        }
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
        let images = try images(matching: selector)
        guard !images.isEmpty else { throw ABIResolutionError.imageNotLoaded }
        return try unique(declaration, images: images)
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
        try unique(declaration, images: [image])
    }

    /// Releases cached image indexes.
    ///
    /// Existing image and symbol handles remain valid. Subsequent lookups rebuild
    /// indexes as needed. The process-lifetime native image catalog remains active.
    public func removeCachedResults() {
        indexes.removeAll()
    }

    private func unique(_ declaration: NativeDeclaration, images: [NativeImage]) throws -> ResolvedSymbol {
        guard declaration.language != .objectiveC else {
            throw ABIResolutionError.unsupportedDeclaration("Objective-C selectors require the invocation frontend.")
        }
        let candidates = images.map { image -> SymbolIndex in
            if let cached = indexes[image.identity] { return cached }
            let index = SymbolIndex(image: image)
            indexes[image.identity] = index
            return index
        }
        // Keep source precedence independent of whether an earlier query has
        // populated the shared-cache index for one image.
        var matches = try candidates.compactMap { try $0.resolve(declaration, source: .image) }
        if matches.isEmpty {
            for index in candidates where !index.sharedCacheLoaded {
                index.appendSharedCacheSymbols(sharedCache.symbols(in: index.image))
            }
            matches = try candidates.compactMap { try $0.resolve(declaration, source: .sharedCache) }
        }
        guard let result = matches.first else { throw ABIResolutionError.declarationNotFound(declaration) }
        guard matches.count == 1 else {
            throw ABIResolutionError.ambiguousDeclaration(declaration, candidates: matches.map { $0.image.path })
        }
        return result
    }
}
