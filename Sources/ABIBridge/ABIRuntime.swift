import Foundation

/// Shares loaded-image indexes and successful lookups across consumers.
/// Actor isolation keeps parsing and demangling off MainActor.
public actor ABIRuntime {
    public static let shared = ABIRuntime()

    private var indexes: [NativeImageIdentity: SymbolIndex] = [:]
    private let sharedCache = SharedCacheSymbols()

    public init() {}

    /// Returns matching loaded images and acquires loader references without loading new code.
    public func images(matching selector: ImageSelector = .automatic) throws -> [NativeImage] {
        try ImageSnapshot.current().filter { $0.matches(selector) }.map { snapshot in
            if let cached = indexes[snapshot.identity] { return cached.image }
            return try snapshot.retain()
        }
    }

    /// Resolves a source-level declaration among loaded-image symbols first.
    /// Shared-cache local symbols are searched only if no loaded-image definition matches.
    public func resolve(
        _ declaration: NativeDeclaration,
        in selector: ImageSelector = .automatic
    ) throws -> ResolvedSymbol {
        let images = try images(matching: selector)
        guard !images.isEmpty else { throw ABIResolutionError.imageNotLoaded }
        return try unique(declaration, images: images)
    }

    /// Resolves in an already retained image, reusing its symbol index.
    public func resolve(_ declaration: NativeDeclaration, in image: NativeImage) throws -> ResolvedSymbol {
        try unique(declaration, images: [image])
    }

    /// Drops indexes and cached results. Existing image and symbol handles remain valid.
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
