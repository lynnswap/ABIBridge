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
    private let pathObservations = RuntimePathObservation.Pool()

    #if DEBUG
    private let sharedCacheCapture:
        (
            @Sendable (
                RuntimeImage, RuntimeDeclaration, SharedCacheSymbols.Source
            ) -> SharedCacheSymbols.CapturedSymbols?
        )?
    package enum CachePublication: Sendable {
        case automaticScope, importIndex, virtualEntries, pathImage
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
        state.withLock { state in
            state.lookups.indexes.values.contains(where: \.hasSharedCacheWaiters)
        }
    }
    package var cachedSymbolIndexes: [SymbolIndex] {
        state.withLock { Array($0.lookups.indexes.values) }
    }
    #endif

    private struct Scope: Hashable {
        let selector: RuntimeImageSelector
        let loading: RuntimeImageLoadingPolicy
    }

    private final class PathImage: Sendable {
        let identity: RuntimeImagePathIdentity
        let image: RuntimeImage
        let acquiringThread: UInt?
        let observation: RuntimePathObservation?

        init(
            identity: RuntimeImagePathIdentity,
            image: RuntimeImage,
            acquiringThread: UInt?,
            observation: RuntimePathObservation?
        ) {
            self.identity = identity
            self.image = image
            self.acquiringThread = acquiringThread
            self.observation = observation
        }
    }

    private struct RetainedImage {
        let image: RuntimeImage
        var acquiringThread: UInt?
    }

    // Results have their own lock. Retiring the node releases all image leases
    // outside the resolver lock, including after a concurrent cache clear.
    private final class AutomaticScope: Sendable {
        struct ResultEntry: Sendable {
            let result: Result<RuntimeSymbol, RuntimeResolutionError>
            let dependency: RuntimeCatalogDependency
        }
        let catalog: RuntimeImageCatalogSnapshot
        var revision: UInt64 { catalog.revision }
        let images: [RuntimeImage]
        let imageIdentities: Set<RuntimeImageIdentity>
        let results: Mutex<[RuntimeDeclaration: ResultEntry]>
        init(
            catalog: RuntimeImageCatalogSnapshot,
            images: [RuntimeImage],
            previous: AutomaticScope?
        ) {
            self.catalog = catalog; self.images = images
            imageIdentities = Set(images.map(\.identity))
            results = Mutex(previous?.results.withLock { $0 } ?? [:])
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
        guard retained.isComplete else {
            RuntimeCatalogDependency.unstable.record()
            return .partial(retained.images)
        }
        let candidate = AutomaticScope(catalog: snapshot, images: retained.images, previous: cached)
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
            if case .images(let images) = scope {
                let key = SearchKey(images: images.map(\.identity), declaration: declaration)
                let (cached, generation) = state.withLock {
                    ($0.explicitResolutions[key], $0.cacheGeneration)
                }
                if let cached { return try cached.get() }
                let result: Result<RuntimeSymbol, RuntimeResolutionError>
                do {
                    result = .success(
                        try unique(declaration, images: images, relatedQueries: relatedQueries)
                    )
                } catch let failure as RuntimeResolutionError {
                    switch failure {
                    case .declarationNotFound, .ambiguousDeclaration, .invalidAddress:
                        result = .failure(failure)
                    default: throw failure
                    }
                }
                state.withLock { state in
                    if state.cacheGeneration == generation, state.explicitResolutions[key] == nil {
                        state.explicitResolutions[key] = result
                    }
                }
                return try result.get()
            }
            do {
                return try unique(declaration, images: scope.images, relatedQueries: relatedQueries)
            } catch RuntimeResolutionError.declarationNotFound {
                throw RuntimeResolutionError.imageUnavailable
            }
        }
        let key = declaration
        if let cached = cache.results.withLock({ $0[key] }), cached.dependency.isCurrent {
            cached.dependency.record()
            return try cached.result.get()
        }
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
        let requiredImages: Set<RuntimeImageIdentity>
        let includingSharedCache: Bool
        switch result {
        case .success(let symbol):
            requiredImages = [symbol.image.identity]
            includingSharedCache = symbol.source == .sharedCache
        case .failure:
            requiredImages = cache.imageIdentities
            includingSharedCache = true
        }
        let dependency = RuntimeCatalogDependency.observing(
            cache.catalog,
            requiredImages: requiredImages
        ) { [weak self] additions in
            guard let self else { return true }
            let retained = try self.retain(additions, skippingUnavailable: false)
            do {
                _ = try self.unique(
                    declaration,
                    images: retained.images,
                    includingSharedCache: includingSharedCache
                )
                return true
            } catch RuntimeResolutionError.declarationNotFound { return false }
        }
        dependency.record()
        let retired = cache.results.withLock { results in
            results.updateValue(.init(result: result, dependency: dependency), forKey: key)
        }
        withExtendedLifetime(retired) {}
        return try result.get()
    }

    private func acquire(
        _ selector: RuntimeImageSelector,
        loading: RuntimeImageLoadingPolicy
    ) throws -> [RuntimeImage] {
        switch selector {
        case .automatic: return try images(matching: selector)
        case .installName(let name):
            guard loading == .ifNeeded else { return try images(matching: selector) }
            try selector.validateTarget()
            return [try RuntimeImage.opening(path: name)]
        case .path(let url):
            try selector.validateTarget()
            return try acquirePath(url.path, selector: selector, loading: loading)
        case .framework(let name):
            guard loading == .ifNeeded else { return try images(matching: selector) }
            try selector.validateTarget()
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

    private func acquirePath(
        _ path: String,
        selector: RuntimeImageSelector,
        loading: RuntimeImageLoadingPolicy
    ) throws -> [RuntimeImage] {
        let key = Array(path.utf8)
        let thread = UInt(bitPattern: pthread_self())
        let (cached, generation) = state.withLock { ($0.pathImages[key], $0.cacheGeneration) }
        if let cached, cached.observation?.isCurrent != false,
            cached.acquiringThread == nil || cached.acquiringThread == thread
        {
            return [cached.image]
        }
        if let cached, cached.observation?.isCurrent == false {
            let retired = state.withLock { state -> PathImage? in
                guard state.pathImages[key] === cached else { return nil }
                return state.pathImages.removeValue(forKey: key)
            }
            withExtendedLifetime(retired) {}
        }
        guard loading == .ifNeeded else { return try images(matching: selector) }
        let identity = RuntimeImagePathIdentity(path: path)
        let observation = identity == .sharedCache ? nil : pathObservations.observe(path)
        let image = try RuntimeImage.opening(path: path)
        // A path can change while dlopen runs constructors. Publish only the
        // file identity observed on both sides of that acquisition.
        guard let identity, identity == RuntimeImagePathIdentity(path: path) else {
            return [image]
        }
        #if DEBUG
        beforeCachePublication?(.pathImage, self)
        #endif
        let retired = state.withLock { state -> PathImage? in
            guard state.cacheGeneration == generation else { return nil }
            // A recursive dlopen can return inside this image's initializer.
            // Another thread's successful acquisition confirms initialization
            // before the cached lease becomes reusable on every thread.
            let previous = state.pathImages[key]
            let verified =
                previous?.identity == identity
                && previous?.image.identity == image.identity
                && previous?.acquiringThread != thread
            let candidate = PathImage(
                identity: identity,
                image: image,
                acquiringThread: verified ? nil : thread,
                observation: observation
            )
            return state.pathImages.updateValue(candidate, forKey: key)
        }
        return withExtendedLifetime(retired) { [image] }
    }

    package func acquireImages(
        _ selector: RuntimeImageSelector,
        loading: RuntimeImageLoadingPolicy
    ) throws -> [RuntimeImage] {
        beginLookup()
        defer { endLookup() }
        return try acquire(selector, loading: loading)
    }

    package func images(matching selector: RuntimeImageSelector) throws -> [RuntimeImage] {
        beginLookup()
        defer { endLookup() }
        let catalog = try RuntimeImageSnapshot.catalog()
        let snapshots = try RuntimeImageSnapshot.matching(
            selector,
            in: catalog.images
        )
        let retained = try retain(snapshots, skippingUnavailable: selector == .automatic)
        if !retained.isComplete {
            RuntimeCatalogDependency.unstable.record()
        } else {
            RuntimeCatalogDependency.observing(
                catalog,
                requiredImages: Set(snapshots.map(\.identity))
            ) { additions in
                try !RuntimeImageSnapshot.matching(selector, in: additions).isEmpty
            }.record()
        }
        return retained.images
    }

    private func retain(
        _ snapshots: [RuntimeImageSnapshot],
        skippingUnavailable: Bool
    ) throws -> (images: [RuntimeImage], isComplete: Bool) {
        let thread = UInt(bitPattern: pthread_self())
        let (retained, generation) = state.withLock { state in
            (snapshots.map { state.retainedImages[$0.identity] }, state.cacheGeneration)
        }
        var images: [RuntimeImage] = []
        var isComplete = true
        for (snapshot, cached) in zip(snapshots, retained) {
            if let cached, cached.acquiringThread == nil || cached.acquiringThread == thread {
                images.append(cached.image)
                continue
            }
            do {
                let image = try snapshot.retain()
                if let cached {
                    // A second thread's successful acquisition proves that a
                    // lease captured by a recursive initializer is now ready.
                    state.withLock { state in
                        if state.cacheGeneration == generation,
                            state.retainedImages[snapshot.identity]?.image.lease
                                === cached.image.lease
                        {
                            state.retainedImages[snapshot.identity]?.acquiringThread = nil
                        }
                    }
                    images.append(cached.image)
                    withExtendedLifetime(image) {}
                } else {
                    images.append(image)
                }
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
        beginLookup()
        defer { endLookup() }
        try validate(declaration)
        return try resolve(declaration, in: searchScope(selector, loading: loading))
    }

    package func resolve(
        _ declaration: RuntimeDeclaration,
        in image: RuntimeImage,
        loading: RuntimeImageLoadingPolicy = .ifNeeded
    ) throws -> RuntimeSymbol {
        beginLookup()
        defer { endLookup() }
        try validate(declaration)
        return try resolve(
            declaration,
            in: .images([loading == .ifNeeded ? image.opened() : image])
        )
    }

    package func resolve(_ request: RuntimeSymbolRequest) throws -> RuntimeSymbol {
        beginLookup()
        defer { endLookup() }
        var scopes: [Scope: Result<SearchScope, any Error>] = [:]
        return try resolve(request, scopes: &scopes)
    }

    package func resolve(_ requests: [RuntimeSymbolRequest]) -> [Result<RuntimeSymbol, any Error>] {
        beginLookup()
        defer { endLookup() }
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
        beginLookup()
        defer { endLookup() }
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

    /// The candidates of the member that a complete or qualified declaration
    /// spells.
    ///
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
        beginLookup()
        defer { endLookup() }
        try validate(declaration)
        guard let match = SwiftMemberMatch(declaration: declaration.name) else { return [] }
        return try swiftMemberCandidates(
            match,
            owner: declaration.name,
            in: selector,
            loading: loading,
            extensionsOnly: extensionsOnly,
            includingSharedCache: includingSharedCache
        )
    }

    /// The candidates of the member that a complete or qualified declaration
    /// spells, in one image.
    ///
    /// - Parameter module: The module whose symbols are read instead of the
    ///   declaration's own, such as a conforming type's module for its witnesses.
    package func swiftDeclarationCandidates(
        _ declaration: RuntimeDeclaration,
        in image: RuntimeImage?,
        loading: RuntimeImageLoadingPolicy = .loadedOnly,
        module: String? = nil,
        extensionsOnly: Bool = false,
        includingSharedCache: Bool = false
    ) throws -> [RuntimeSwiftCandidate] {
        beginLookup()
        defer { endLookup() }
        try validate(declaration)
        guard let match = SwiftMemberMatch(declaration: declaration.name) else { return [] }
        return try swiftMemberCandidates(
            match,
            owner: declaration.name,
            in: image,
            loading: loading,
            module: module,
            extensionsOnly: extensionsOnly,
            includingSharedCache: includingSharedCache
        )
    }

    package func swiftDeclarationCandidates(
        _ declaration: RuntimeDeclaration,
        in images: [RuntimeImage],
        extensionsOnly: Bool = false,
        includingSharedCache: Bool = false
    ) throws -> [RuntimeSwiftCandidate] {
        beginLookup()
        defer { endLookup() }
        try validate(declaration)
        guard let match = SwiftMemberMatch(declaration: declaration.name) else { return [] }
        return try swiftMemberCandidates(
            match,
            owner: declaration.name,
            in: .images(images),
            extensionsOnly: extensionsOnly,
            includingSharedCache: includingSharedCache
        )
    }

    /// The candidates of a member, whose records `match` accepts.
    ///
    /// - Parameters:
    ///   - owner: The name of the member's owner, whose module's symbols are
    ///     read.
    ///   - includingSharedCache: Also returns code that only the shared
    ///     cache's local symbols describe, even when the images contain other
    ///     candidates.
    package func swiftMemberCandidates(
        _ match: SwiftMemberMatch,
        owner: String,
        in selector: RuntimeImageSelector,
        loading: RuntimeImageLoadingPolicy,
        extensionsOnly: Bool = false,
        includingSharedCache: Bool = false
    ) throws -> [RuntimeSwiftCandidate] {
        beginLookup()
        defer { endLookup() }
        return try swiftMemberCandidates(
            match,
            owner: owner,
            in: searchScope(selector, loading: loading),
            extensionsOnly: extensionsOnly,
            includingSharedCache: includingSharedCache
        )
    }

    /// The candidates of a member in one image, or in the loaded images.
    ///
    /// - Parameter module: The module whose symbols are read instead of the
    ///   owner's, such as a conforming type's module for its witnesses.
    package func swiftMemberCandidates(
        _ match: SwiftMemberMatch,
        owner: String,
        in image: RuntimeImage?,
        loading: RuntimeImageLoadingPolicy = .loadedOnly,
        module: String? = nil,
        extensionsOnly: Bool = false,
        includingSharedCache: Bool = false
    ) throws -> [RuntimeSwiftCandidate] {
        beginLookup()
        defer { endLookup() }
        let scope =
            try image.map { SearchScope.images([loading == .ifNeeded ? try $0.opened() : $0]) }
            ?? searchScope(.automatic, loading: .loadedOnly)
        return try swiftMemberCandidates(
            match,
            owner: owner,
            in: scope,
            module: module,
            extensionsOnly: extensionsOnly,
            includingSharedCache: includingSharedCache
        )
    }

    private func swiftMemberCandidates(
        _ match: SwiftMemberMatch,
        owner: String,
        in scope: SearchScope,
        module: String? = nil,
        extensionsOnly: Bool,
        includingSharedCache: Bool,
        searchingSharedCache: Bool = true
    ) throws -> [RuntimeSwiftCandidate] {
        beginLookup()
        defer { endLookup() }
        func record(
            _ candidates: [RuntimeSwiftCandidate],
            searchingSharedCache: Bool
        ) -> [RuntimeSwiftCandidate] {
            if case .automatic(let automatic) = scope {
                RuntimeCatalogDependency.observing(
                    automatic.catalog,
                    requiredImages: Set(candidates.map { $0.symbol.image.identity })
                ) { [weak self] additions in
                    guard let self else { return true }
                    let retained = try self.retain(additions, skippingUnavailable: false)
                    return try !self.swiftMemberCandidates(
                        match,
                        owner: owner,
                        in: .images(retained.images),
                        module: module,
                        extensionsOnly: extensionsOnly,
                        includingSharedCache: includingSharedCache,
                        searchingSharedCache: searchingSharedCache
                    ).isEmpty
                }.record()
            }
            return candidates
        }
        // The owner's name selects the module whose symbols are read, and the
        // entry the sections that hold it.
        let query = SymbolQuery(
            .init(
                name: owner,
                language: .swift,
                kind: match.entry == .propertyDescriptor ? .data : .function
            ),
            module: module
        )
        let indexes = state.withLock { state in scope.images.map { state.index(for: $0) } }
        func matches(
            _ source: RuntimeSymbol.Source,
            in indexes: [SymbolIndex]
        ) -> [RuntimeSwiftCandidate] {
            state.withLock { _ in
                indexes.flatMap {
                    $0.swiftDeclarationCandidates(
                        match,
                        query: query,
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
        // A completed image-tier lookup only depends on new image candidates.
        // An empty addition must not widen that lookup to shared-cache locals.
        guard searchingSharedCache else { return primary }
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
            return record(primary + fallback, searchingSharedCache: true)
        }
        let dispatched = primary.filter {
            !$0.record.runsOwnCode && !implemented.contains($0.record.identity)
        }
        guard !dispatched.isEmpty else { return record(primary, searchingSharedCache: false) }
        let images = Set(dispatched.map(\.symbol.image))
        let owners = indexes.filter { images.contains($0.image) }
        let identities = Set(dispatched.map(\.record.identity))
        loadSharedCacheSymbols(for: query, into: owners)
        return record(
            primary
                + matches(.sharedCache, in: owners).filter {
                    $0.record.role == .implementation && identities.contains($0.record.identity)
                },
            searchingSharedCache: false
        )
    }

    /// Reuses lookup indexes for a synchronous batch. Overlapping batches share indexes
    /// until the last active lookup ends; returned symbols retain their own images.
    package func withCachedLookups<Value>(_ operation: () throws -> Value) rethrows -> Value {
        beginLookup()
        defer { endLookup() }
        return try operation()
    }

    private func beginLookup() {
        state.withLock { $0.activeLookups += 1 }
    }

    private func endLookup() {
        let removed = state.withLock { state -> LookupIndexes? in
            state.activeLookups -= 1
            return state.activeLookups == 0 ? state.removeLookupIndexes() : nil
        }
        withExtendedLifetime(removed) {}
    }

    package func removeCachedResults() {
        let removed = state.withLock { $0.removeCachedResults() }
        withExtendedLifetime(removed) {}
    }

    package func importIndex(for image: RuntimeImage) throws -> ImportIndex {
        beginLookup()
        defer { endLookup() }
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
        beginLookup()
        defer { endLookup() }
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

    private enum LookupCandidate {
        case symbol(RuntimeSymbol)
        case index(SymbolIndex)
    }

    private func unique(
        _ declaration: RuntimeDeclaration,
        images: [RuntimeImage],
        includingSharedCache: Bool = true,
        relatedQueries: [SymbolQuery] = []
    ) throws -> RuntimeSymbol {
        beginLookup()
        defer { endLookup() }
        // A lookup keeps one snapshot through explicit invalidation, including
        // symbols cached before the lookup began and indexes it still has to scan.
        let (cachedQuery, candidates, generation) = state.withLock { state in
            let candidates = images.map { image -> LookupCandidate in
                let primary = SymbolKey(
                    image: image.identity,
                    declaration: declaration,
                    source: .image
                )
                let shared = SymbolKey(
                    image: image.identity,
                    declaration: declaration,
                    source: .sharedCache
                )
                if let symbol = state.resolvedSymbols[primary] { return .symbol(symbol) }
                if let symbol = state.resolvedSymbols[shared] { return .symbol(symbol) }
                return .index(state.index(for: image))
            }
            return (state.lookups.queries[declaration], candidates, state.cacheGeneration)
        }
        let indexes = candidates.compactMap { candidate -> SymbolIndex? in
            if case .index(let index) = candidate { return index }
            return nil
        }
        func cachedSymbols(_ source: RuntimeSymbol.Source) -> [RuntimeSymbol] {
            candidates.compactMap { candidate in
                if case .symbol(let symbol) = candidate, symbol.source == source { return symbol }
                return nil
            }
        }
        let cachedPrimary = cachedSymbols(.image)
        if indexes.isEmpty {
            let matches =
                !cachedPrimary.isEmpty
                ? cachedPrimary
                : includingSharedCache ? cachedSymbols(.sharedCache) : []
            return try select(declaration, from: matches)
        }
        let query = cachedQuery ?? SymbolQuery(declaration)
        if cachedQuery == nil {
            state.withLock { state in
                if state.cacheGeneration == generation {
                    state.lookups.queries[declaration] = query
                }
            }
        }
        var hasKindMismatch = false
        func matches(_ source: RuntimeSymbol.Source) throws -> [RuntimeSymbol] {
            try state.withLock { state in
                var symbols = cachedSymbols(source)
                for index in indexes {
                    switch try index.resolveCandidate(query, source: source) {
                    case .missing: break
                    case .kindMismatch: hasKindMismatch = true
                    case .symbol(let symbol):
                        let key = SymbolKey(
                            image: index.image.identity,
                            declaration: declaration,
                            source: source
                        )
                        if state.cacheGeneration == generation, state.resolvedSymbols[key] == nil {
                            state.resolvedSymbols[key] = symbol
                        }
                        symbols.append(symbol)
                    }
                }
                return symbols
            }
        }
        let primary = try matches(.image)
        if !primary.isEmpty || !includingSharedCache {
            return try select(declaration, from: primary)
        }
        loadSharedCacheSymbols(for: query, into: indexes, relatedQueries: relatedQueries)
        let fallback = try matches(.sharedCache)
        if fallback.isEmpty && hasKindMismatch { throw RuntimeResolutionError.invalidAddress }
        return try select(declaration, from: fallback)
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
        beginLookup()
        defer { endLookup() }
        let index = state.withLock { $0.index(for: image) }
        return withExtendedLifetime(index) {
            state.withLock { _ in index.exportedSwiftTypeDeclaration(at: address) }
        }
    }

    /// The witnesses that `image`'s symbol table holds for the conformance
    /// whose descriptor is at `descriptor`.
    package func swiftWitnesses(
        ofConformanceAt descriptor: UInt64,
        in image: RuntimeImage
    ) -> [RuntimeSwiftCandidate] {
        beginLookup()
        defer { endLookup() }
        let index = state.withLock { $0.index(for: image) }
        return withExtendedLifetime(index) {
            state.withLock { _ in index.swiftWitnesses(ofConformanceAt: descriptor) }
        }
    }

    /// The address of the protocol conformance descriptor that `image` names
    /// `name`, as the remangler spells it.
    package func swiftConformanceDescriptor(named name: String, in image: RuntimeImage) -> UInt64? {
        beginLookup()
        defer { endLookup() }
        let index = state.withLock { $0.index(for: image) }
        return withExtendedLifetime(index) {
            state.withLock { _ in index.swiftConformanceDescriptor(named: name) }
        }
    }

    /// The requirements that method descriptor symbols of `image` name at
    /// `address`, as the remangler spells them.
    package func swiftMethodDescriptorRequirements(
        at address: UInt64,
        in image: RuntimeImage
    ) -> Set<String> {
        beginLookup()
        defer { endLookup() }
        let index = state.withLock { $0.index(for: image) }
        return withExtendedLifetime(index) {
            state.withLock { _ in index.swiftMethodDescriptorRequirements(at: address) }
        }
    }

    /// The declaration, such as `8ProbeLib1P33_…LLV`, under which `image`
    /// names the Swift nominal type descriptor at `address`, in its exports
    /// or its symbol table. Only local symbols name the descriptor of a
    /// private or local type, and stripping the image removes them.
    package func swiftTypeDeclaration(at address: UInt64, in image: RuntimeImage) -> String? {
        beginLookup()
        defer { endLookup() }
        let index = state.withLock { $0.index(for: image) }
        return withExtendedLifetime(index) {
            state.withLock { _ in index.swiftTypeDeclaration(at: address) }
        }
    }

    /// Whether `image` holds a trivial property descriptor for a stored `var`
    /// of a struct or class that `module` declares. A module built without
    /// library evolution by Swift 6.0 or later gives every stored property
    /// with a descriptor a trivial one, and a library-evolution module never
    /// gives one to a stored `var`.
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/SILGen/SILGen.cpp
    ///
    /// - Parameter module: The module's name, such as `ProbeLib`. A type
    ///   declared in an extension belongs to the extension's module.
    package func hasTrivialStoredVariableDescriptor(
        declaredBy module: String,
        in image: RuntimeImage
    ) -> Bool {
        beginLookup()
        defer { endLookup() }
        let index = state.withLock { $0.index(for: image) }
        return withExtendedLifetime(index) {
            state.withLock { _ in index.hasTrivialStoredVariableDescriptor(declaredBy: module) }
        }
    }

    /// The instance properties of the struct, enum, or class whose nominal
    /// type descriptor is at `address` that a symbol in `image`'s exports or
    /// symbol table spells, each mapped to whether a spelled declared type
    /// contains an opaque type. A field record holds an opaque property's
    /// underlying type instead.
    package func swiftPropertyDeclarations(
        ofTypeAt address: UInt64,
        in image: RuntimeImage
    ) -> [String: Bool] {
        beginLookup()
        defer { endLookup() }
        let index = state.withLock { $0.index(for: image) }
        return withExtendedLifetime(index) {
            state.withLock { _ in index.swiftPropertyDeclarations(ofTypeAt: address) }
        }
    }

    /// The symbols `image` exports with names starting with `prefix`.
    package func exportedSymbols(
        withPrefix prefix: String,
        in image: RuntimeImage
    ) -> [IndexedSymbol] {
        beginLookup()
        defer { endLookup() }
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
        beginLookup()
        defer { endLookup() }
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
        guard matches.count > 1 else { return result }
        if let definition = try RuntimeUniquedRecord.representative(of: matches) {
            return definition
        }
        throw RuntimeResolutionError.ambiguousDeclaration(
            declaration,
            candidates: matches.map { $0.image.path }
        )
    }

    private struct SearchKey: Hashable {
        let images: [RuntimeImageIdentity]
        let declaration: RuntimeDeclaration
    }

    private struct SymbolKey: Hashable {
        let image: RuntimeImageIdentity
        let declaration: RuntimeDeclaration
        let source: RuntimeSymbol.Source
    }

    private struct LookupIndexes {
        var indexes: [RuntimeImageIdentity: SymbolIndex] = [:]
        var queries: [RuntimeDeclaration: SymbolQuery] = [:]
    }

    private struct ResolutionState {
        // Explicit invalidation also retires candidates prepared outside the lock.
        var cacheGeneration: UInt64 = 0
        var activeLookups = 0
        var lookups = LookupIndexes()
        var automatic: AutomaticScope?
        var classImages: [ObjectIdentifier: RuntimeImage] = [:]
        var pathImages: [[UInt8]: PathImage] = [:]
        var resolvedSymbols: [SymbolKey: RuntimeSymbol] = [:]
        var explicitResolutions: [SearchKey: Result<RuntimeSymbol, RuntimeResolutionError>] = [:]
        var retainedImages: [RuntimeImageIdentity: RetainedImage] = [:]
        var imports: [RuntimeImageIdentity: ImportIndex] = [:]
        var virtualEntries: [RuntimeImageIdentity: VirtualEntryIndex] = [:]
        var virtualTables: [UInt: VirtualEntryIndex] = [:]

        mutating func removeLookupIndexes() -> LookupIndexes {
            let removed = lookups
            lookups = LookupIndexes()
            return removed
        }

        mutating func removeCachedResults() -> Self {
            let removed = self
            self = Self()
            cacheGeneration = removed.cacheGeneration &+ 1
            activeLookups = removed.activeLookups
            return removed
        }

        mutating func index(for image: RuntimeImage) -> SymbolIndex {
            if let cached = lookups.indexes[image.identity] { return cached }
            let retained =
                retainedImages[image.identity]
                ?? RetainedImage(
                    image: image,
                    acquiringThread: UInt(bitPattern: pthread_self())
                )
            retainedImages[image.identity] = retained
            let index = SymbolIndex(image: retained.image)
            lookups.indexes[image.identity] = index
            return index
        }
    }
}
