import Synchronization
import Darwin

// Loader operations run outside the index lock: constructors and destructors
// may reenter the native API while dyld holds its own lock.
package final class RuntimeSymbolResolver: Sendable {
    package init() {
        #if DEBUG
        sharedCacheCapture = nil
        beforeCachePublication = nil
        #endif
    }
    package static let shared = RuntimeSymbolResolver()
    private let state = Mutex(ResolutionState())

    #if DEBUG
    private let sharedCacheCapture:
        (
            @Sendable (
                RuntimeImage, RuntimeDeclaration, SharedCacheSymbols.Source
            ) -> SharedCacheSymbols.CapturedSymbols?
        )?
    package enum CachePublication: Sendable {
        case automaticScope, importIndex, virtualEntries
    }
    private let beforeCachePublication:
        (
            @Sendable (
                CachePublication, RuntimeSymbolResolver
            ) -> Void
        )?

    package init(
        capturingSharedCacheSymbols capture:
            @escaping @Sendable (
                RuntimeImage, RuntimeDeclaration, SharedCacheSymbols.Source
            ) -> SharedCacheSymbols.CapturedSymbols?
    ) {
        sharedCacheCapture = capture
        beforeCachePublication = nil
    }

    package init(
        beforePublishingCache callback:
            @escaping @Sendable (
                CachePublication, RuntimeSymbolResolver
            ) -> Void
    ) {
        sharedCacheCapture = nil
        beforeCachePublication = callback
    }

    package var hasSharedCacheWaiters: Bool {
        state.withLock { state in state.indexes.values.contains(where: \.hasSharedCacheWaiters) }
    }
    #endif

    private struct Scope: Hashable {
        let selector: RuntimeImageSelector
        let loading: RuntimeImageLoadingPolicy
    }

    // Results have their own lock. Retiring the node releases all image leases
    // outside the resolver lock, including after a concurrent cache clear.
    private final class AutomaticScope: Sendable {
        let revision: UInt64
        let images: [RuntimeImage]
        let results = Mutex<[RuntimeDeclaration: Result<RuntimeSymbol, RuntimeResolutionError>]>([:])
        init(revision: UInt64, images: [RuntimeImage]) {
            self.revision = revision; self.images = images
        }
    }

    private enum SearchScope {
        case images([RuntimeImage])
        case automatic(AutomaticScope)
        case partial([RuntimeImage])
        var images: [RuntimeImage] {
            switch self {
            case .images(let images), .partial(let images): images
            case .automatic(let scope): scope.images
            }
        }
        var isComplete: Bool {
            if case .partial = self { return false }
            return true
        }
    }

    private func searchScope(
        _ selector: RuntimeImageSelector,
        loading: RuntimeImageLoadingPolicy
    ) throws -> SearchScope {
        guard selector == .automatic else {
            return .images(try acquire(selector, loading: loading))
        }
        let (cached, generation) = state.withLock { ($0.automatic, $0.cacheGeneration) }
        let snapshot = try RuntimeImageSnapshot.catalog()
        if let cached, cached.revision == snapshot.revision {
            return .automatic(cached)
        }
        let retained = try retain(snapshot.images, skippingUnavailable: true)
        // Initializer completion has no add/remove notification. A partial
        // scope must be reacquired even if the catalog revision stays the same.
        guard retained.isComplete else { return .partial(retained.images) }
        let candidate = AutomaticScope(revision: snapshot.revision, images: retained.images)
        #if DEBUG
        beforeCachePublication?(.automaticScope, self)
        #endif
        let (selected, retired) = state.withLock { state -> (AutomaticScope, AutomaticScope?) in
            guard state.cacheGeneration == generation else { return (candidate, nil) }
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

    private func resolve(
        _ declaration: RuntimeDeclaration,
        in scope: SearchScope,
        relatedQueries: [SymbolQuery] = []
    ) throws -> RuntimeSymbol {
        guard !scope.images.isEmpty else {
            throw scope.isComplete
                ? RuntimeResolutionError.imageNotLoaded : RuntimeResolutionError.imageUnavailable
        }
        guard case .automatic(let cache) = scope else {
            do {
                return try unique(
                    declaration,
                    images: scope.images,
                    relatedQueries: relatedQueries
                )
            } catch RuntimeResolutionError.declarationNotFound where !scope.isComplete {
                throw RuntimeResolutionError.imageUnavailable
            }
        }
        let key = declaration
        if let cached = cache.results.withLock({ $0[key] }) { return try cached.get() }
        let result: Result<RuntimeSymbol, RuntimeResolutionError>
        do {
            result = .success(
                try unique(
                    declaration,
                    images: cache.images,
                    relatedQueries: relatedQueries
                )
            )
        } catch let failure as RuntimeResolutionError {
            switch failure {
            case .declarationNotFound, .ambiguousDeclaration, .invalidAddress:
                result = .failure(failure)
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

    private func acquire(
        _ selector: RuntimeImageSelector,
        loading: RuntimeImageLoadingPolicy
    ) throws -> [RuntimeImage] {
        guard loading == .ifNeeded, selector != .automatic else {
            return try images(matching: selector)
        }
        try selector.validateTarget()
        switch selector {
        case .automatic: return try images(matching: selector)
        case .installName(let name):
            return [try RuntimeImage.opening(path: name)]
        case .path(let url):
            return [try RuntimeImage.opening(path: url.path)]
        case .framework(let name):
            let loaded = try images(matching: selector)
            if loaded.count == 1 { return [try loaded[0].opened()] }
            if loaded.count > 1 {
                throw RuntimeResolutionError.ambiguousImage(candidates: loaded.map(\.path))
            }
            let candidates = FrameworkImages.candidates(named: name)
            guard candidates.count <= 1 else {
                throw RuntimeResolutionError.ambiguousImage(candidates: candidates.map(\.path))
            }
            guard let target = candidates.first else { return [] }
            return [try RuntimeImage.opening(path: target.path)]
        }
    }

    package func images(matching selector: RuntimeImageSelector) throws -> [RuntimeImage] {
        let snapshots = try RuntimeImageSnapshot.matching(
            selector,
            in: RuntimeImageSnapshot.current()
        )
        return try retain(snapshots, skippingUnavailable: selector == .automatic).images
    }

    private func retain(
        _ snapshots: [RuntimeImageSnapshot],
        skippingUnavailable: Bool
    ) throws -> (images: [RuntimeImage], isComplete: Bool) {
        let retained = state.withLock { state in
            snapshots.map { state.indexes[$0.identity]?.image }
        }
        var images: [RuntimeImage] = []
        var isComplete = true
        for (snapshot, cached) in zip(snapshots, retained) {
            if let cached { images.append(cached); continue }
            do {
                images.append(try snapshot.retain())
            } catch RuntimeResolutionError.imageChanged {
                // This generation disappeared; add/remove already advances the revision.
                continue
            } catch RuntimeResolutionError.imageUnavailable where skippingUnavailable {
                isComplete = false
            }
        }
        return (images, isComplete)
    }

    package func resolve(
        _ declaration: RuntimeDeclaration,
        in selector: RuntimeImageSelector = .automatic,
        loading: RuntimeImageLoadingPolicy = .ifNeeded
    ) throws -> RuntimeSymbol {
        try validate(declaration)
        return try resolve(declaration, in: searchScope(selector, loading: loading))
    }

    package func resolve(
        _ declaration: RuntimeDeclaration,
        in image: RuntimeImage,
        loading: RuntimeImageLoadingPolicy = .ifNeeded
    ) throws -> RuntimeSymbol {
        try validate(declaration)
        return try unique(declaration, images: [loading == .ifNeeded ? image.opened() : image])
    }

    package func resolve(_ request: RuntimeSymbolRequest) throws -> RuntimeSymbol {
        var scopes: [Scope: Result<SearchScope, any Error>] = [:]
        return try resolve(request, scopes: &scopes)
    }

    package func resolve(_ requests: [RuntimeSymbolRequest]) -> [Result<RuntimeSymbol, any Error>] {
        var scopes: [Scope: Result<SearchScope, any Error>] = [:]
        var relatedQueries: [Scope: [SymbolQuery]] = [:]
        for request in requests {
            let queries = ([request.declaration] + request.alternatives).map(SymbolQuery.init)
            for selector in request.imageScopes {
                relatedQueries[Scope(selector: selector, loading: request.loading), default: []] +=
                    queries
            }
        }
        return requests.map { request in
            Result { try resolve(request, scopes: &scopes, relatedQueries: relatedQueries) }
        }
    }

    private func resolve(
        _ request: RuntimeSymbolRequest,
        scopes: inout [Scope: Result<SearchScope, any Error>],
        relatedQueries: [Scope: [SymbolQuery]] = [:]
    ) throws -> RuntimeSymbol {
        var missing: RuntimeResolutionError = .imageNotLoaded
        for (index, candidate) in ([request.declaration] + request.fallbacks).enumerated() {
            do {
                return try resolveAliases(
                    candidate,
                    alternatives: index == 0 ? request.alternatives : [],
                    in: request.imageScopes,
                    loading: request.loading,
                    scopes: &scopes,
                    relatedQueries: relatedQueries
                )
            } catch let error as RuntimeResolutionError {
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
        _ primary: RuntimeDeclaration,
        alternatives: [RuntimeDeclaration],
        in imageScopes: [RuntimeImageSelector],
        loading: RuntimeImageLoadingPolicy,
        scopes: inout [Scope: Result<SearchScope, any Error>],
        relatedQueries: [Scope: [SymbolQuery]]
    ) throws -> RuntimeSymbol {
        for declaration in [primary] + alternatives { try validate(declaration) }
        var missing: RuntimeResolutionError = .imageNotLoaded
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
                if case .success(let search) = scopeResult, search.isComplete {
                    scopes[key] = scopeResult
                }
            }
            let search = try scopeResult.get()
            guard !search.images.isEmpty else {
                if !search.isComplete { throw RuntimeResolutionError.imageUnavailable }
                continue
            }
            var match: RuntimeSymbol?
            for declaration in [primary] + alternatives {
                do {
                    let found = try resolve(
                        declaration,
                        in: search,
                        relatedQueries: relatedQueries[key] ?? []
                    )
                    if let previous = match {
                        guard previous.address == found.address,
                            previous.image.identity == found.image.identity
                        else {
                            throw RuntimeResolutionError.ambiguousDeclaration(
                                primary,
                                candidates: [previous.declaration.name, found.declaration.name]
                            )
                        }
                    } else {
                        match = found
                    }
                } catch RuntimeResolutionError.declarationNotFound {
                    continue
                } catch RuntimeResolutionError.imageUnavailable where !search.isComplete {
                    // Unavailable images do not hide an alias already found in
                    // this scope, or prevent another available alias matching.
                    continue
                }
            }
            if let match { return match }
            if !search.isComplete { throw RuntimeResolutionError.imageUnavailable }
            missing = .declarationNotFound(primary)
        }
        throw missing
    }

    package func image(
        forSwiftClass type: AnyClass,
        lookup: () throws -> RuntimeImage
    ) throws -> RuntimeImage {
        let key = ObjectIdentifier(type)
        let (cached, generation) = state.withLock { ($0.classImages[key], $0.cacheGeneration) }
        if let cached { return cached }
        let candidate = try lookup()
        return withExtendedLifetime(candidate) {
            state.withLock { state in
                guard state.cacheGeneration == generation else { return candidate }
                if let cached = state.classImages[key] { return cached }
                state.classImages[key] = candidate
                return candidate
            }
        }
    }

    /// - Parameter includingSharedCache: Also returns code that only the
    ///   shared cache's local symbols describe, even when the images contain
    ///   other candidates.
    package func swiftDeclarationCandidates(
        _ declaration: RuntimeDeclaration,
        in selector: RuntimeImageSelector,
        loading: RuntimeImageLoadingPolicy,
        extensionsOnly: Bool = false,
        includingSharedCache: Bool = false
    ) throws -> [RuntimeSwiftCandidate] {
        try validate(declaration)
        return try swiftDeclarationCandidates(
            declaration,
            in: searchScope(selector, loading: loading),
            extensionsOnly: extensionsOnly,
            includingSharedCache: includingSharedCache
        )
    }

    package func swiftDeclarationCandidates(
        _ declaration: RuntimeDeclaration,
        in image: RuntimeImage?,
        loading: RuntimeImageLoadingPolicy = .loadedOnly,
        extensionsOnly: Bool = false,
        includingSharedCache: Bool = false
    ) throws -> [RuntimeSwiftCandidate] {
        try validate(declaration)
        let scope =
            try image.map { SearchScope.images([loading == .ifNeeded ? try $0.opened() : $0]) }
            ?? searchScope(.automatic, loading: .loadedOnly)
        return try swiftDeclarationCandidates(
            declaration,
            in: scope,
            extensionsOnly: extensionsOnly,
            includingSharedCache: includingSharedCache
        )
    }

    private func swiftDeclarationCandidates(
        _ declaration: RuntimeDeclaration,
        in scope: SearchScope,
        extensionsOnly: Bool,
        includingSharedCache: Bool
    ) throws -> [RuntimeSwiftCandidate] {
        let query = SymbolQuery(declaration)
        let indexes = state.withLock { state in scope.images.map { state.index(for: $0) } }
        func matches(
            _ source: RuntimeSymbol.Source,
            in indexes: [SymbolIndex]
        ) -> [RuntimeSwiftCandidate] {
            state.withLock { _ in
                indexes.flatMap {
                    $0.swiftDeclarationCandidates(
                        query,
                        source: source,
                        extensionsOnly: extensionsOnly
                    )
                }
            }
        }
        // Image symbols take precedence; shared-cache local symbols describe
        // code that the images do not. A class member's dispatch thunk is not
        // that code, so images that export only such thunks still consult the
        // shared cache.
        let primary = matches(.image, in: indexes)
        let implemented = Set(primary.lazy.filter(\.record.runsOwnCode).map(\.record.identity))
        guard !implemented.isEmpty, !includingSharedCache else {
            loadSharedCacheSymbols(for: query, into: indexes)
            // Images and the shared cache can both describe the same code.
            let fallback = matches(.sharedCache, in: indexes).filter {
                !implemented.contains($0.record.identity)
            }
            if fallback.isEmpty && implemented.isEmpty && !scope.isComplete {
                throw RuntimeResolutionError.imageUnavailable
            }
            return primary + fallback
        }
        let dispatched = primary.filter {
            !$0.record.runsOwnCode && !implemented.contains($0.record.identity)
        }
        guard !dispatched.isEmpty else { return primary }
        let images = Set(dispatched.map(\.symbol.image))
        let owners = indexes.filter { images.contains($0.image) }
        let identities = Set(dispatched.map(\.record.identity))
        loadSharedCacheSymbols(for: query, into: owners)
        return primary
            + matches(.sharedCache, in: owners).filter {
                $0.record.role == .implementation && identities.contains($0.record.identity)
            }
    }

    package func removeCachedResults() {
        let removed = state.withLock { state in
            let indexes = (
                state.indexes, state.imports, state.virtualEntries, state.automatic,
                state.classImages, state.virtualTables
            )
            state.cacheGeneration &+= 1
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

    package func importIndex(for image: RuntimeImage) throws -> ImportIndex {
        let (cached, generation) = state.withLock {
            ($0.imports[image.identity], $0.cacheGeneration)
        }
        if let cached { return cached }
        // File/cache discovery can enter dyld; keep it outside the resolver lock.
        let candidate = try ImportIndex(image: image)
        #if DEBUG
        beforeCachePublication?(.importIndex, self)
        #endif
        return withExtendedLifetime(candidate) {
            state.withLock { state in
                guard state.cacheGeneration == generation else { return candidate }
                if let cached = state.imports[image.identity] { return cached }
                state.imports[image.identity] = candidate
                return candidate
            }
        }
    }

    package func virtualEntry(
        named name: String,
        addressPoint: UInt,
        entryCount: Int
    ) throws -> RuntimeVirtualEntryResolution {
        let (size, overflow) = entryCount.multipliedReportingOverflow(by: MemoryLayout<UInt>.size)
        guard entryCount >= 0, !overflow, addressPoint != 0, UInt(size) <= UInt.max - addressPoint
        else {
            throw RuntimeResolutionError.invalidAddress
        }
        if let cached = state.withLock({ $0.virtualTables[addressPoint] }) {
            return try cached.match(named: name, addressPoint: addressPoint, entryCount: entryCount)
        }
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: addressPoint), &info) != 0,
            let header = info.dli_fbase,
            let snapshot = try RuntimeImageSnapshot.current().first(where: {
                $0.identity.headerAddress == UInt64(UInt(bitPattern: header))
            })
        else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The virtual table has no loaded-image metadata; supply explicit adapter metadata"
            )
        }
        let (cached, generation) = state.withLock {
            ($0.virtualEntries[snapshot.identity], $0.cacheGeneration)
        }
        let index: VirtualEntryIndex
        if let cached {
            index = cached
        } else {
            let candidate = try VirtualEntryIndex(image: snapshot.retain())
            #if DEBUG
            beforeCachePublication?(.virtualEntries, self)
            #endif
            index = withExtendedLifetime(candidate) {
                state.withLock { state in
                    guard state.cacheGeneration == generation else { return candidate }
                    if let cached = state.virtualEntries[snapshot.identity] { return cached }
                    state.virtualEntries[snapshot.identity] = candidate
                    return candidate
                }
            }
        }
        let result = try index.match(
            named: name,
            addressPoint: addressPoint,
            entryCount: entryCount
        )
        state.withLock { state in
            // The retained image prevents address reuse. A concurrent clear must
            // not let this lookup republish a retired metadata index.
            if state.virtualEntries[snapshot.identity] === index
                && state.virtualTables[addressPoint] == nil
            {
                state.virtualTables[addressPoint] = index
            }
        }
        return result
    }

    private func validate(_ declaration: RuntimeDeclaration) throws {
        guard declaration.language != .objectiveC || declaration.nameForm != .source else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "Objective-C selectors require the invocation frontend."
            )
        }
    }

    private func unique(
        _ declaration: RuntimeDeclaration,
        images: [RuntimeImage],
        relatedQueries: [SymbolQuery] = []
    ) throws -> RuntimeSymbol {
        // Keep these indexes for the whole lookup even if another caller clears
        // the cache while shared-cache metadata is being read.
        let query = SymbolQuery(declaration)
        let candidates = state.withLock { state in images.map { state.index(for: $0) } }
        return try withExtendedLifetime(candidates) {
            func matches(_ source: RuntimeSymbol.Source) throws -> [RuntimeSymbol] {
                try state.withLock { _ in
                    try candidates.compactMap { try $0.resolve(query, source: source) }
                }
            }
            let primary = try matches(.image)
            if !primary.isEmpty { return try select(declaration, from: primary) }

            loadSharedCacheSymbols(for: query, into: candidates, relatedQueries: relatedQueries)
            return try select(declaration, from: try matches(.sharedCache))
        }
    }

    /// The declaration, such as `8ProbeLib5PointV`, under which `image`
    /// exports the Swift nominal type descriptor at `address`.
    ///
    /// A runtime type name can spell a declaration differently from its
    /// symbols: it omits the generic signature of a constrained extension.
    package func exportedSwiftTypeDeclaration(
        at address: UInt64,
        in image: RuntimeImage
    ) -> String? {
        let index = state.withLock { $0.index(for: image) }
        return withExtendedLifetime(index) {
            state.withLock { _ in index.exportedSwiftTypeDeclaration(at: address) }
        }
    }

    /// The symbols `image` exports with names starting with `prefix`.
    package func exportedSymbols(
        withPrefix prefix: String,
        in image: RuntimeImage
    ) -> [IndexedSymbol] {
        let index = state.withLock { $0.index(for: image) }
        return withExtendedLifetime(index) {
            state.withLock { _ in index.exportedSymbols(withPrefix: prefix) }
        }
    }

    package func swiftNominalTypeName(
        at address: UInt64,
        in image: RuntimeImage,
        suggestedName: String
    ) throws -> String? {
        let query = SymbolQuery(
            .init(
                name: "nominal type descriptor for " + suggestedName,
                language: .swift,
                kind: .data
            )
        )
        let index = state.withLock { $0.index(for: image) }
        return try withExtendedLifetime(index) {
            if let name = try state.withLock({ _ in
                try index.swiftNominalTypeName(at: address, matching: query, source: .image)
            }) {
                return name
            }
            loadSharedCacheSymbols(for: query, into: [index])
            return try state.withLock { _ in
                try index.swiftNominalTypeName(at: address, matching: query, source: .sharedCache)
            }
        }
    }

    private func loadSharedCacheSymbols(
        for query: SymbolQuery,
        into candidates: [SymbolIndex],
        relatedQueries: [SymbolQuery] = []
    ) {
        let missing = state.withLock { _ in
            candidates.indices.filter { !candidates[$0].hasSharedCacheSymbols(for: query) }
                .map { ($0, !candidates[$0].hasSharedSwiftFallback) }
        }
        // Discovery can enter dyld. Only scans of captured sources become
        // joinable, and each image/scope is independent of the rest of a batch.
        let cache = SharedCacheSymbols()
        func capture(
            _ index: SymbolIndex,
            source: SharedCacheSymbols.Source
        )
            -> SharedCacheSymbols.CapturedSymbols?
        {
            #if DEBUG
            if let sharedCacheCapture {
                return sharedCacheCapture(index.image, query.declaration, source)
            }
            #endif
            return cache.capture(in: index.image, source: source)
        }
        for (position, includeFallback) in missing {
            let index = candidates[position]
            if state.withLock({ _ in index.hasSharedCacheSymbols(for: query) }) { continue }
            let related = state.withLock { _ in
                relatedQueries.filter { !index.hasSharedCacheSymbols(for: $0) }
            }
            var symbols: [IndexedSymbol] = []
            var coveredQueries = [query]
            if let sources = capture(index, source: .loaded) {
                guard
                    let loaded = scanSharedCacheSymbols(
                        sources,
                        source: .loaded,
                        for: query,
                        in: index,
                        includingSwiftFallback: includeFallback,
                        relatedQueries: related
                    )
                else { continue }
                symbols = loaded.symbols
                coveredQueries = loaded.coveredQueries
                if !loaded.foundDefinitions, let sources = capture(index, source: .file),
                    let file = scanSharedCacheSymbols(
                        sources,
                        source: .file,
                        for: query,
                        in: index,
                        includingSwiftFallback: includeFallback,
                        relatedQueries: related
                    )
                {
                    symbols += file.symbols
                    coveredQueries = file.coveredQueries
                }
            }
            let retired = state.withLock { _ in
                if !index.hasSharedCacheSymbols(for: query) {
                    index.appendSharedCacheSymbols(symbols, matching: coveredQueries)
                }
                return index.removeSharedCacheScans(for: query)
            }
            withExtendedLifetime(retired) {}
        }
    }

    private func scanSharedCacheSymbols(
        _ sources: SharedCacheSymbols.CapturedSymbols,
        source: SharedCacheSymbols.Source,
        for query: SymbolQuery,
        in index: SymbolIndex,
        includingSwiftFallback: Bool,
        relatedQueries: [SymbolQuery]
    ) -> SharedCacheSymbols.Extraction? {
        let scan = withExtendedLifetime(sources) {
            state.withLock { _ -> SharedCacheSymbolScan? in
                if index.hasSharedCacheSymbols(for: query) { return nil }
                return index.sharedCacheScan(
                    for: query,
                    source: source,
                    includingSwiftFallback: includingSwiftFallback,
                    capturing: sources,
                    relatedQueries: relatedQueries
                )
            }
        }
        return scan?.result()
    }

    private func select(
        _ declaration: RuntimeDeclaration,
        from matches: [RuntimeSymbol]
    ) throws -> RuntimeSymbol {
        guard let result = matches.first else {
            throw RuntimeResolutionError.declarationNotFound(declaration)
        }
        guard matches.count == 1 else {
            throw RuntimeResolutionError.ambiguousDeclaration(
                declaration,
                candidates: matches.map { $0.image.path }
            )
        }
        return result
    }

    private struct ResolutionState {
        // Catalog revisions track image changes; this generation also retires
        // candidates being built outside the lock when callers clear caches.
        var cacheGeneration: UInt64 = 0
        var automatic: AutomaticScope?
        var classImages: [ObjectIdentifier: RuntimeImage] = [:]
        var indexes: [RuntimeImageIdentity: SymbolIndex] = [:]
        var imports: [RuntimeImageIdentity: ImportIndex] = [:]
        var virtualEntries: [RuntimeImageIdentity: VirtualEntryIndex] = [:]
        var virtualTables: [UInt: VirtualEntryIndex] = [:]

        mutating func index(for image: RuntimeImage) -> SymbolIndex {
            if let cached = indexes[image.identity] { return cached }
            let index = SymbolIndex(image: image)
            indexes[image.identity] = index
            return index
        }
    }
}
