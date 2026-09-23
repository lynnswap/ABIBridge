import Synchronization

// Loader operations run outside the index lock: constructors and destructors
// may reenter the native API while dyld holds its own lock.
final class SymbolResolver: Sendable {
    static let shared = SymbolResolver()
    private let state = Mutex(ResolutionState())

    func images(matching selector: ImageSelector) throws -> [NativeImage] {
        let snapshots = try ImageSnapshot.current().filter { $0.matches(selector) }
        return try snapshots.compactMap { snapshot in
            if let cached = state.withLock({ $0.indexes[snapshot.identity]?.image }) {
                return cached
            }
            do {
                return try snapshot.retain()
            } catch ABIResolutionError.imageChanged {
                // An unrelated load can disappear before its lease is acquired.
                // Preserve failures for a generation that is still in the catalog.
                let current = try ImageSnapshot.current()
                if current.contains(where: { $0.identity.loadGeneration == snapshot.identity.loadGeneration }) {
                    throw ABIResolutionError.imageChanged
                }
                return nil
            }
        }
    }

    func resolve(_ declaration: NativeDeclaration, in selector: ImageSelector) throws -> ResolvedSymbol {
        let images = try images(matching: selector)
        guard !images.isEmpty else { throw ABIResolutionError.imageNotLoaded }
        return try unique(declaration, images: images)
    }

    func resolve(_ declaration: NativeDeclaration, in image: NativeImage) throws -> ResolvedSymbol {
        try unique(declaration, images: [image])
    }

    func resolve(_ request: NativeSymbolRequest) throws -> ResolvedSymbol {
        var scopes: [ImageSelector: Result<[NativeImage], any Error>] = [:]
        return try resolve(request, scopes: &scopes)
    }

    func resolve(_ requests: [NativeSymbolRequest]) -> [Result<ResolvedSymbol, any Error>] {
        var scopes: [ImageSelector: Result<[NativeImage], any Error>] = [:]
        return requests.map { request in
            Result { try resolve(request, scopes: &scopes) }
        }
    }

    private func resolve(
        _ request: NativeSymbolRequest,
        scopes: inout [ImageSelector: Result<[NativeImage], any Error>]
    ) throws -> ResolvedSymbol {
        var missing: ABIResolutionError = .imageNotLoaded
        for scope in request.imageScopes {
            let scopeResult: Result<[NativeImage], any Error>
            if let cached = scopes[scope] {
                scopeResult = cached
            } else {
                scopeResult = Result { try self.images(matching: scope) }
                scopes[scope] = scopeResult
            }
            let images = try scopeResult.get()
            guard !images.isEmpty else { continue }
            var match: ResolvedSymbol?
            for declaration in [request.declaration] + request.alternatives {
                do {
                    let found = try unique(declaration, images: images)
                    if let previous = match {
                        guard previous.address == found.address,
                              previous.image.identity == found.image.identity else {
                            throw ABIResolutionError.ambiguousDeclaration(
                                request.declaration,
                                candidates: [previous.declaration.name, found.declaration.name]
                            )
                        }
                    } else {
                        match = found
                    }
                } catch ABIResolutionError.declarationNotFound {
                    continue
                }
            }
            if let match { return match }
            missing = .declarationNotFound(request.declaration)
        }
        throw missing
    }

    func resolveSwiftExtension(_ declaration: NativeDeclaration) throws -> ResolvedSymbol {
        try unique(declaration, images: images(matching: .automatic), extensionsOnly: true)
    }

    func removeCachedResults() {
        let removed = state.withLock { state in
            let indexes = state.indexes
            state.indexes = [:]
            return indexes
        }
        withExtendedLifetime(removed) {}
    }

    private func unique(_ declaration: NativeDeclaration, images: [NativeImage], extensionsOnly: Bool = false) throws -> ResolvedSymbol {
        guard declaration.language != .objectiveC || declaration.nameForm != .source else {
            throw ABIResolutionError.unsupportedDeclaration("Objective-C selectors require the invocation frontend.")
        }
        // Keep these indexes for the whole lookup even if another caller clears
        // the cache while shared-cache metadata is being read.
        let candidates = state.withLock { state in images.map { state.index(for: $0) } }
        return try withExtendedLifetime(candidates) {
            let primary = try state.withLock { _ in
                try candidates.compactMap { try $0.resolve(declaration, source: .image, extensionsOnly: extensionsOnly) }
            }
            if !primary.isEmpty { return try select(declaration, from: primary) }

            let missing = state.withLock { _ in candidates.indices.filter { !candidates[$0].sharedCacheLoaded } }
            // MachOKit's host-cache discovery may call the dynamic loader.
            // Reuse file mappings within this lookup; retained per-image
            // indexes cache the resulting symbols across future lookups.
            let cache = SharedCacheSymbols()
            let additions = missing.map { (candidates[$0], cache.symbols(in: candidates[$0].image)) }
            let fallback = try state.withLock { _ in
                for (index, symbols) in additions where !index.sharedCacheLoaded {
                    index.appendSharedCacheSymbols(symbols)
                }
                return try candidates.compactMap { try $0.resolve(declaration, source: .sharedCache, extensionsOnly: extensionsOnly) }
            }
            return try select(declaration, from: fallback)
        }
    }

    private func select(_ declaration: NativeDeclaration, from matches: [ResolvedSymbol]) throws -> ResolvedSymbol {
        guard let result = matches.first else { throw ABIResolutionError.declarationNotFound(declaration) }
        guard matches.count == 1 else {
            throw ABIResolutionError.ambiguousDeclaration(declaration, candidates: matches.map { $0.image.path })
        }
        return result
    }
}

private struct ResolutionState {
    var indexes: [NativeImageIdentity: SymbolIndex] = [:]

    mutating func index(for image: NativeImage) -> SymbolIndex {
        if let cached = indexes[image.identity] { return cached }
        let index = SymbolIndex(image: image)
        indexes[image.identity] = index
        return index
    }
}
