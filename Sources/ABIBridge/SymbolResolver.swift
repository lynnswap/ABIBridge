import Synchronization

// The Swift actor and native synchronous callers share this owner. No native
// call blocks waiting for a Swift task, and index mutation stays under one lock.
final class SymbolResolver: Sendable {
    static let shared = SymbolResolver()
    private let state = Mutex(ResolutionState())

    func images(matching selector: ImageSelector) throws -> [NativeImage] {
        try state.withLock { try $0.images(matching: selector) }
    }

    func resolve(_ declaration: NativeDeclaration, in selector: ImageSelector) throws -> ResolvedSymbol {
        try state.withLock { try $0.resolve(declaration, in: selector) }
    }

    func resolve(_ declaration: NativeDeclaration, in image: NativeImage) throws -> ResolvedSymbol {
        try state.withLock { try $0.unique(declaration, images: [image]) }
    }

    func removeCachedResults() {
        let removed = state.withLock { state in
            let indexes = state.indexes
            state.indexes = [:]
            return indexes
        }
        // Releasing a loader lease can run library destructors, which may
        // themselves resolve symbols. Do not hold the resolver lock then.
        withExtendedLifetime(removed) {}
    }
}

private struct ResolutionState {
    var indexes: [NativeImageIdentity: SymbolIndex] = [:]
    let sharedCache = SharedCacheSymbols()

    mutating func images(matching selector: ImageSelector) throws -> [NativeImage] {
        try ImageSnapshot.current().filter { $0.matches(selector) }.map { snapshot in
            if let cached = indexes[snapshot.identity] { return cached.image }
            return try snapshot.retain()
        }
    }

    mutating func resolve(_ declaration: NativeDeclaration, in selector: ImageSelector) throws -> ResolvedSymbol {
        let images = try images(matching: selector)
        guard !images.isEmpty else { throw ABIResolutionError.imageNotLoaded }
        return try unique(declaration, images: images)
    }

    mutating func unique(_ declaration: NativeDeclaration, images: [NativeImage]) throws -> ResolvedSymbol {
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
