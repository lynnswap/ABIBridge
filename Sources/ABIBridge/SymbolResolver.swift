import Synchronization
import Darwin

// Loader operations run outside the index lock: constructors and destructors
// may reenter the native API while dyld holds its own lock.
final class SymbolResolver: Sendable {
    static let shared = SymbolResolver()
    private let state = Mutex(ResolutionState())

    private struct Scope: Hashable {
        let selector: ImageSelector
        let loading: ImageLoadingPolicy
    }

    private struct LookupKey: Hashable, Sendable {
        let declaration: NativeDeclaration
        let extensionsOnly: Bool
    }

    // Results have their own lock. Retiring the node releases all image leases
    // outside the resolver lock, including after a concurrent cache clear.
    private final class AutomaticScope: Sendable {
        let revision: UInt64
        let images: [NativeImage]
        let results = Mutex<[LookupKey: Result<ResolvedSymbol, ABIResolutionError>]>([:])
        init(revision: UInt64, images: [NativeImage]) { self.revision = revision; self.images = images }
    }

    private enum SearchScope {
        case images([NativeImage])
        case automatic(AutomaticScope)
        var images: [NativeImage] {
            switch self { case .images(let images): images; case .automatic(let scope): scope.images }
        }
    }

    private func searchScope(_ selector: ImageSelector, loading: ImageLoadingPolicy) throws -> SearchScope {
        guard selector == .automatic else { return .images(try acquire(selector, loading: loading)) }
        let snapshot = try ImageSnapshot.catalog()
        if let cached = state.withLock({ $0.automatic }), cached.revision == snapshot.revision { return .automatic(cached) }
        let candidate = AutomaticScope(revision: snapshot.revision, images: try retain(snapshot.images))
        let (selected, retired) = state.withLock { state -> (AutomaticScope, AutomaticScope?) in
            if let existing = state.automatic {
                if existing.revision == candidate.revision { return (existing, nil) }
                if existing.revision > candidate.revision { return (candidate, nil) }
            }
            let previous = state.automatic
            state.automatic = candidate
            return (candidate, previous)
        }
        return withExtendedLifetime((candidate, retired)) { .automatic(selected) }
    }

    private func resolve(_ declaration: NativeDeclaration, in scope: SearchScope, extensionsOnly: Bool = false) throws -> ResolvedSymbol {
        guard !scope.images.isEmpty else { throw ABIResolutionError.imageNotLoaded }
        guard case .automatic(let cache) = scope else {
            return try unique(declaration, images: scope.images, extensionsOnly: extensionsOnly)
        }
        let key = LookupKey(declaration: declaration, extensionsOnly: extensionsOnly)
        if let cached = cache.results.withLock({ $0[key] }) { return try cached.get() }
        let result: Result<ResolvedSymbol, ABIResolutionError>
        do { result = .success(try unique(declaration, images: cache.images, extensionsOnly: extensionsOnly)) }
        catch let failure as ABIResolutionError {
            switch failure {
            case .declarationNotFound, .ambiguousDeclaration, .invalidAddress: result = .failure(failure)
            default: throw failure
            }
        }
        cache.results.withLock { results in
            // Never replace a cached symbol under the lock: releasing its last
            // lease could reenter dyld even when another call retained the image.
            if results[key] == nil { results[key] = result }
        }
        return try result.get()
    }

    private func acquire(_ selector: ImageSelector, loading: ImageLoadingPolicy) throws -> [NativeImage] {
        guard loading == .ifNeeded, selector != .automatic else { return try images(matching: selector) }
        try selector.validateTarget()
        switch selector {
        case .automatic: return try images(matching: selector)
        case .installName(let name):
            return [try NativeImage.opening(path: name)]
        case .path(let url):
            return [try NativeImage.opening(path: url.path)]
        case .framework(let name):
            let loaded = try images(matching: selector)
            if loaded.count == 1 { return [try loaded[0].opened()] }
            if loaded.count > 1 { throw ABIResolutionError.ambiguousImage(candidates: loaded.map(\.path)) }
            let candidates = FrameworkImages.candidates(named: name)
            guard candidates.count <= 1 else {
                throw ABIResolutionError.ambiguousImage(candidates: candidates.map(\.path))
            }
            guard let target = candidates.first else { return [] }
            return [try NativeImage.opening(path: target.path)]
        }
    }

    func images(matching selector: ImageSelector) throws -> [NativeImage] {
        let snapshots = try ImageSnapshot.matching(selector, in: ImageSnapshot.current())
        return try retain(snapshots)
    }

    private func retain(_ snapshots: [ImageSnapshot]) throws -> [NativeImage] {
        let retained = state.withLock { state in
            snapshots.map { state.indexes[$0.identity]?.image }
        }
        return try zip(snapshots, retained).compactMap { snapshot, cached in
            if let cached { return cached }
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

    func resolve(_ declaration: NativeDeclaration, in selector: ImageSelector, loading: ImageLoadingPolicy = .ifNeeded) throws -> ResolvedSymbol {
        try validate(declaration)
        return try resolve(declaration, in: searchScope(selector, loading: loading))
    }

    func resolve(_ declaration: NativeDeclaration, in image: NativeImage, loading: ImageLoadingPolicy = .ifNeeded) throws -> ResolvedSymbol {
        try validate(declaration)
        return try unique(declaration, images: [loading == .ifNeeded ? image.opened() : image])
    }

    func resolve(_ request: NativeSymbolRequest) throws -> ResolvedSymbol {
        var scopes: [Scope: Result<SearchScope, any Error>] = [:]
        return try resolve(request, scopes: &scopes)
    }

    func resolve(_ requests: [NativeSymbolRequest]) -> [Result<ResolvedSymbol, any Error>] {
        var scopes: [Scope: Result<SearchScope, any Error>] = [:]
        return requests.map { request in
            Result { try resolve(request, scopes: &scopes) }
        }
    }

    private func resolve(
        _ request: NativeSymbolRequest,
        scopes: inout [Scope: Result<SearchScope, any Error>]
    ) throws -> ResolvedSymbol {
        var missing: ABIResolutionError = .imageNotLoaded
        for (index, candidate) in ([request.declaration] + request.fallbacks).enumerated() {
            do {
                return try resolveAliases(
                    candidate, alternatives: index == 0 ? request.alternatives : [],
                    in: request.imageScopes, loading: request.loading, scopes: &scopes
                )
            } catch let error as ABIResolutionError {
                switch error {
                case .imageNotLoaded, .declarationNotFound:
                    if index == 0 { missing = error }
                default: throw error
                }
            }
        }
        throw missing
    }

    private func resolveAliases(
        _ primary: NativeDeclaration, alternatives: [NativeDeclaration],
        in imageScopes: [ImageSelector], loading: ImageLoadingPolicy,
        scopes: inout [Scope: Result<SearchScope, any Error>]
    ) throws -> ResolvedSymbol {
        for declaration in [primary] + alternatives { try validate(declaration) }
        var missing: ABIResolutionError = .imageNotLoaded
        for scope in imageScopes {
            let key = Scope(selector: scope, loading: loading)
            let scopeResult: Result<SearchScope, any Error>
            if let cached = scopes[key] {
                scopeResult = cached
            } else {
                // Even a failed dlopen can change the catalog through dependencies
                // or constructors. Later requests must see those changes.
                if loading == .ifNeeded && scope != .automatic { scopes.removeAll() }
                scopeResult = Result { try searchScope(scope, loading: loading) }
                scopes[key] = scopeResult
            }
            let search = try scopeResult.get()
            guard !search.images.isEmpty else { continue }
            var match: ResolvedSymbol?
            for declaration in [primary] + alternatives {
                do {
                    let found = try resolve(declaration, in: search)
                    if let previous = match {
                        guard previous.address == found.address,
                              previous.image.identity == found.image.identity else {
                            throw ABIResolutionError.ambiguousDeclaration(
                                primary,
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
            missing = .declarationNotFound(primary)
        }
        throw missing
    }

    func image(forSwiftClass type: AnyClass, lookup: () throws -> NativeImage) throws -> NativeImage {
        let key = ObjectIdentifier(type)
        if let cached = state.withLock({ $0.classImages[key] }) { return cached }
        let candidate = try lookup()
        return withExtendedLifetime(candidate) {
            state.withLock { state in
                if let cached = state.classImages[key] { return cached }
                state.classImages[key] = candidate
                return candidate
            }
        }
    }

    func resolveSwiftExtension(_ declaration: NativeDeclaration) throws -> ResolvedSymbol {
        try resolve(declaration, in: searchScope(.automatic, loading: .loadedOnly), extensionsOnly: true)
    }

    func removeCachedResults() {
        let removed = state.withLock { state in
            let indexes = (state.indexes, state.imports, state.virtualEntries, state.automatic, state.classImages, state.virtualTables)
            state.indexes = [:]
            state.imports = [:]
            state.virtualEntries = [:]
            state.virtualTables = [:]
            state.automatic = nil
            state.classImages = [:]
            return indexes
        }
        withExtendedLifetime(removed) {}
    }

    func importIndex(for image: NativeImage) throws -> ImportIndex {
        if let cached = state.withLock({ $0.imports[image.identity] }) { return cached }
        // File/cache discovery can enter dyld; keep it outside the resolver lock.
        let candidate = try ImportIndex(image: image)
        return withExtendedLifetime(candidate) {
            state.withLock { state in
                if let cached = state.imports[image.identity] { return cached }
                state.imports[image.identity] = candidate
                return candidate
            }
        }
    }

    func virtualEntry(named name: String, addressPoint: UInt, entryCount: Int) throws -> VirtualEntryResolution {
        let (size, overflow) = entryCount.multipliedReportingOverflow(by: MemoryLayout<UInt>.size)
        guard entryCount >= 0, !overflow, addressPoint != 0, UInt(size) <= UInt.max - addressPoint else {
            throw ABIResolutionError.invalidAddress
        }
        if let cached = state.withLock({ $0.virtualTables[addressPoint] }) {
            return try cached.match(named: name, addressPoint: addressPoint, entryCount: entryCount)
        }
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: addressPoint), &info) != 0, let header = info.dli_fbase,
              let snapshot = try ImageSnapshot.current().first(where: { $0.identity.headerAddress == UInt64(UInt(bitPattern: header)) }) else {
            throw ABIResolutionError.metadataUnavailable("The virtual table has no loaded-image metadata; supply explicit adapter metadata")
        }
        let cached = state.withLock { $0.virtualEntries[snapshot.identity] }
        let index: VirtualEntryIndex
        if let cached { index = cached }
        else {
            let candidate = try VirtualEntryIndex(image: snapshot.retain())
            index = withExtendedLifetime(candidate) {
                state.withLock { state in
                    if let cached = state.virtualEntries[snapshot.identity] { return cached }
                    state.virtualEntries[snapshot.identity] = candidate
                    return candidate
                }
            }
        }
        let result = try index.match(named: name, addressPoint: addressPoint, entryCount: entryCount)
        state.withLock { state in
            // The retained image prevents address reuse. A concurrent clear must
            // not let this lookup republish a retired metadata index.
            if state.virtualEntries[snapshot.identity] === index && state.virtualTables[addressPoint] == nil {
                state.virtualTables[addressPoint] = index
            }
        }
        return result
    }

    private func validate(_ declaration: NativeDeclaration) throws {
        guard declaration.language != .objectiveC || declaration.nameForm != .source else {
            throw ABIResolutionError.unsupportedDeclaration("Objective-C selectors require the invocation frontend.")
        }
    }

    private func unique(_ declaration: NativeDeclaration, images: [NativeImage], extensionsOnly: Bool = false) throws -> ResolvedSymbol {
        // Keep these indexes for the whole lookup even if another caller clears
        // the cache while shared-cache metadata is being read.
        let query = SymbolQuery(declaration)
        let candidates = state.withLock { state in images.map { state.index(for: $0) } }
        return try withExtendedLifetime(candidates) {
            let primary = try state.withLock { _ in
                try candidates.compactMap { try $0.resolve(query, source: .image, extensionsOnly: extensionsOnly) }
            }
            if !primary.isEmpty { return try select(declaration, from: primary) }

            loadSharedCacheSymbols(for: query, into: candidates)
            let fallback = try state.withLock { _ in
                return try candidates.compactMap { try $0.resolve(query, source: .sharedCache, extensionsOnly: extensionsOnly) }
            }
            return try select(declaration, from: fallback)
        }
    }

    func swiftNominalTypeName(at address: UInt64, in image: NativeImage, suggestedName: String) throws -> String? {
        let query = SymbolQuery(.init(
            name: "nominal type descriptor for " + suggestedName, language: .swift, kind: .data
        ))
        let index = state.withLock { $0.index(for: image) }
        return try withExtendedLifetime(index) {
            if let name = try state.withLock({ _ in
                try index.swiftNominalTypeName(at: address, matching: query, source: .image)
            }) { return name }
            loadSharedCacheSymbols(for: query, into: [index])
            return try state.withLock { _ in
                try index.swiftNominalTypeName(at: address, matching: query, source: .sharedCache)
            }
        }
    }

    private func loadSharedCacheSymbols(for query: SymbolQuery, into candidates: [SymbolIndex]) {
        let missing = state.withLock { _ in
            candidates.indices.filter { !candidates[$0].hasSharedCacheSymbols(for: query) }
                .map { ($0, !candidates[$0].hasSharedSwiftFallback) }
        }
        // Host-cache discovery may call dyld, so perform it outside the lock.
        let cache = SharedCacheSymbols()
        let additions = missing.map { index, includeFallback in
            (candidates[index], cache.symbols(in: candidates[index].image, matching: query,
                                              includingSwiftFallback: includeFallback))
        }
        state.withLock { _ in
            for (index, symbols) in additions where !index.hasSharedCacheSymbols(for: query) {
                index.appendSharedCacheSymbols(symbols, matching: query)
            }
        }
    }

    private func select(_ declaration: NativeDeclaration, from matches: [ResolvedSymbol]) throws -> ResolvedSymbol {
        guard let result = matches.first else { throw ABIResolutionError.declarationNotFound(declaration) }
        guard matches.count == 1 else {
            throw ABIResolutionError.ambiguousDeclaration(declaration, candidates: matches.map { $0.image.path })
        }
        return result
    }

    private struct ResolutionState {
        var automatic: AutomaticScope?
        var classImages: [ObjectIdentifier: NativeImage] = [:]
        var indexes: [NativeImageIdentity: SymbolIndex] = [:]
        var imports: [NativeImageIdentity: ImportIndex] = [:]
        var virtualEntries: [NativeImageIdentity: VirtualEntryIndex] = [:]
        var virtualTables: [UInt: VirtualEntryIndex] = [:]

        mutating func index(for image: NativeImage) -> SymbolIndex {
            if let cached = indexes[image.identity] { return cached }
            let index = SymbolIndex(image: image)
            indexes[image.identity] = index
            return index
        }
    }
}
