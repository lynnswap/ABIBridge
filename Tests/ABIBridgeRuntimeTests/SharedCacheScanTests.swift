#if os(macOS) && DEBUG
@testable import ABIBridgeRuntime
import ABIBridgeTestSupport
import Foundation
import Synchronization
import Testing

private struct SharedCacheScanTestFailure: Error {
    let message: String
}

private final class SharedCacheScanGate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let reads = Mutex(0)
    var readCount: Int { reads.withLock { $0 } }

    @discardableResult func read() -> Int {
        let count = reads.withLock { count in
            count += 1; return count
        }
        if count == 1 {
            entered.signal()
            // The controller inspects resolver locks. A locking regression must
            // release this gate eventually so it can report the failure.
            #expect(
                release.wait(timeout: .now() + 60) == .success,
                "Releasing the captured-source scan"
            )
        }
        return count
    }

    func waitUntilEntered(until deadline: DispatchTime) throws {
        guard entered.wait(timeout: deadline) == .success else {
            throw SharedCacheScanTestFailure(message: "The captured-source scan did not start")
        }
    }
}

private final class SharedCacheScanWorker<Value: Sendable>: Sendable {
    private let name: String
    private let finished = DispatchGroup()
    private let result = Mutex<Result<Value, any Error>?>(nil)

    init(_ name: String, _ operation: @escaping @Sendable () throws -> Value) {
        self.name = name
        finished.enter()
        let worker = Thread { [self] in
            let value = Result { try operation() }
            result.withLock { $0 = value }
            finished.leave()
        }
        worker.qualityOfService = Thread.current.qualityOfService
        worker.start()
    }

    func value(until deadline: DispatchTime) throws -> Value {
        guard finished.wait(timeout: deadline) == .success else {
            throw SharedCacheScanTestFailure(message: "\(name) did not complete")
        }
        return try result.withLock { $0! }.get()
    }

    func waitForCleanup() {
        if finished.wait(timeout: .now() + 30) != .success {
            Issue.record(
                SharedCacheScanTestFailure(message: "\(name) did not finish during cleanup")
            )
        }
    }
}

private func capturedSources(
    named name: String,
    at address: UInt,
    gate: SharedCacheScanGate? = nil
)
    -> SharedCacheSymbols.CapturedSymbols
{
    SharedCacheSymbols.CapturedSymbols(
        slide: 0,
        readers: [
            { record in
                gate?.read()
                ("_" + name).withCString { record($0, UInt64(address)) }
            }
        ]
    )
}

struct SharedCacheScanTests {
    @Test func clearingCachesPreservesCapturedAndScannedCandidates() throws {
        let first = try FixtureLibrary(), second = try FixtureLibrary()
        defer { first.cleanup(); second.cleanup() }
        let firstAddress = try first.address(kind: 1)
        let secondAddress = try second.address(kind: 2)
        let firstURL = first.libraryURL, secondURL = second.libraryURL
        let images = RuntimeSymbolResolver()
        let firstIdentity = try #require(try images.images(matching: .path(firstURL)).first)
            .identity
        let secondIdentity = try #require(try images.images(matching: .path(secondURL)).first)
            .identity
        let declaration = RuntimeDeclaration(
            name: "ABIBridgeSnapshotCandidates",
            language: .c,
            kind: .data
        )
        let holder = Mutex<RuntimeSymbolResolver?>(nil)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: {
            image,
            requested,
            source in
            guard requested == declaration, source == .loaded else { return nil }
            if image.identity == firstIdentity {
                return capturedSources(named: requested.name, at: firstAddress)
            }
            if image.identity == secondIdentity {
                holder.withLock { $0 }?.removeCachedResults()
                return capturedSources(named: requested.name, at: secondAddress)
            }
            return nil
        })
        holder.withLock { $0 = resolver }
        defer { holder.withLock { $0 = nil } }
        _ = try resolver.resolve(declaration, in: .path(firstURL), loading: .loadedOnly)
        do {
            _ = try resolver.resolve(declaration)
            Issue.record("Both definitions must remain visible when a scan clears the caches")
        } catch RuntimeResolutionError.ambiguousDeclaration(_, let candidates) {
            #expect(candidates.count == 2)
        }
    }

    @Test func missingAliasesReuseCompletedSearchesOutsideBatch() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let address = try fixture.address(kind: 1)
        let declaration = RuntimeDeclaration(
            name: "ABIBridgeCachedAlias",
            language: .c,
            kind: .data
        )
        let reads = Mutex(0)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, requested, source in
            guard source == .loaded else { return nil }
            reads.withLock { $0 += 1 }
            return capturedSources(named: declaration.name, at: address)
        })
        let request = RuntimeSymbolRequest(
            declaration,
            alternatives: [.init(name: "ABIBridgeMissingAlias", language: .c, kind: .data)],
            in: [.path(fixture.libraryURL)],
            loading: .loadedOnly
        )
        #expect(try resolver.resolve(request).address == UInt64(address))
        let preparedReads = reads.withLock { $0 }
        #expect(preparedReads > 0)
        #expect(try resolver.resolve(request).address == UInt64(address))
        #expect(reads.withLock { $0 } == preparedReads)
    }

    @Test func overlappingBatchesKeepIndexesUntilTheLastBatchEnds() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let resolver = RuntimeSymbolResolver(keepingLookupIndexesFor: .zero)
        let declaration = RuntimeDeclaration(
            name: fixture.namespace + "::add(int, int)",
            language: .cxx
        )
        let libraryURL = fixture.libraryURL
        let entered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0), releaseSecond = DispatchSemaphore(value: 0)
        let first = SharedCacheScanWorker("First batch") {
            try resolver.withCachedLookups {
                _ = try resolver.resolve(declaration, in: .path(libraryURL))
                entered.signal()
                return releaseFirst.wait(timeout: .now() + 30)
            }
        }
        defer { releaseFirst.signal(); first.waitForCleanup() }
        #expect(entered.wait(timeout: .now() + 30) == .success)
        let second = SharedCacheScanWorker("Second batch") {
            try resolver.withCachedLookups {
                _ = try resolver.resolve(declaration, in: .path(libraryURL))
                entered.signal()
                return releaseSecond.wait(timeout: .now() + 30)
            }
        }
        defer { releaseSecond.signal(); second.waitForCleanup() }
        #expect(entered.wait(timeout: .now() + 30) == .success)
        releaseFirst.signal()
        #expect(try first.value(until: .now() + 30) == .success)
        #expect(!resolver.cachedSymbolIndexes.isEmpty)
        releaseSecond.signal()
        #expect(try second.value(until: .now() + 30) == .success)
        #expect(resolver.cachedSymbolIndexes.isEmpty)
    }

    @Test func memberValidationPreservesImageAndSharedCacheSearchScopes() throws {
        let module = "MemberValidation_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let source = """
            public struct Counter {
                public init() {}
                public func value() -> Int { 42 }
                public var count: Int { 42 }
            }
            public protocol Readable {}
            extension Readable { public func extended() -> Int { 42 } }
            """
        let definition = try FixtureLibrary(swiftModule: module, swiftSource: source)
        let addition = try FixtureLibrary(load: false)
        let competing = try FixtureLibrary(
            load: false,
            swiftModule: module,
            swiftSource: source.replacingOccurrences(of: "42", with: "84")
        )
        defer { definition.cleanup(); addition.cleanup(); competing.cleanup() }
        let local = Mutex<(image: RuntimeImageIdentity, address: UInt, name: String)?>(nil)
        let captures = Mutex(0)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { image, _, source in
            guard let local = local.withLock({ $0 }), image.identity == local.image,
                source == .loaded
            else { return nil }
            captures.withLock { $0 += 1 }
            return capturedSources(named: local.name, at: local.address)
        })
        let requests: [(String, Bool)] = [
            (module + ".Counter.value() -> Swift.Int", false),
            (module + ".Counter.count.getter : Swift.Int", false),
            (module + ".Counter.init() -> " + module + ".Counter", false),
            ("(extension in \(module)):\(module).Readable.extended() -> Swift.Int", true),
        ]
        let prepared = try requests.map { name, extensionsOnly in
            let result = try RuntimeCatalogDependency.recording {
                try resolver.swiftDeclarationCandidates(
                    RuntimeDeclaration(name: name, language: .swift),
                    in: .automatic,
                    loading: .loadedOnly,
                    extensionsOnly: extensionsOnly
                )
            }
            #expect(!result.value.isEmpty, "\(name)")
            #expect(result.value.allSatisfy { $0.symbol.source == .image && $0.record.runsOwnCode })
            return result
        }
        let implementation = try #require(prepared[0].value.first).record.identity
        #expect(implementation.hasSuffix("SiyF"))
        let overload = String(implementation.dropLast(4)) + "SSyF"
        let expanded = try RuntimeCatalogDependency.recording {
            try resolver.swiftDeclarationCandidates(
                RuntimeDeclaration(name: requests[0].0, language: .swift),
                in: .automatic,
                loading: .loadedOnly,
                includingSharedCache: true
            )
        }
        #expect(expanded.dependency.isCurrent)

        try addition.load()
        let image = try #require(try resolver.images(matching: .path(addition.libraryURL)).first)
        let address = try addition.address(kind: 0)
        local.withLock { $0 = (image.identity, address, overload) }
        for result in prepared { #expect(result.dependency.isCurrent) }
        #expect(captures.withLock { $0 } == 0)
        #expect(!expanded.dependency.isCurrent)
        #expect(captures.withLock { $0 } > 0)

        try competing.load()
        for result in prepared { #expect(!result.dependency.isCurrent) }
    }

    @Test func cachedImageDefinitionsLeaveSharedCacheUnreadAfterImageLoads() throws {
        let definition = try FixtureLibrary()
        let addition = try FixtureLibrary(load: false)
        defer { definition.cleanup(); addition.cleanup() }
        let addedImage = Mutex<RuntimeImageIdentity?>(nil)
        let captures = Mutex(0)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { image, _, _ in
            if image.identity == addedImage.withLock({ $0 }) { captures.withLock { $0 += 1 } }
            return nil
        })
        let declaration = RuntimeDeclaration(
            name: definition.namespace + "::add(int, int)",
            language: .cxx
        )
        let original = try resolver.resolve(declaration)
        #expect(original.source == .image)

        try addition.load()
        let image = try #require(try resolver.images(matching: .path(addition.libraryURL)).first)
        addedImage.withLock { $0 = image.identity }
        let resolved = try resolver.resolve(declaration)
        #expect(resolved.address == original.address)
        #expect(captures.withLock { $0 } == 0)
    }

    @Test func cachedSharedCacheDefinitionsYieldToNewImageDefinitions() throws {
        let name =
            "SharedReplacement_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let local = try FixtureLibrary()
        let addition = try FixtureLibrary(
            load: false,
            cxxSource: "extern \"C\" int \(name)() { return 84; }"
        )
        defer { local.cleanup(); addition.cleanup() }
        let localImage = try #require(
            try RuntimeSymbolResolver().images(matching: .path(local.libraryURL)).first
        ).identity
        let address = try local.address(kind: 0)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { image, _, source in
            guard image.identity == localImage, source == .loaded else { return nil }
            return capturedSources(named: name, at: address)
        })
        let declaration = RuntimeDeclaration(name: name, language: .c)
        #expect(try resolver.resolve(declaration).source == .sharedCache)

        try addition.load()
        let image = try #require(try resolver.images(matching: .path(addition.libraryURL)).first)
        let resolved = try resolver.resolve(declaration)
        #expect(resolved.source == .image)
        #expect(resolved.image.identity == image.identity)
    }

    @Test func wrongKindImageSymbolsDoNotBlockSharedCacheDefinitions() throws {
        let name =
            "SharedKindCollision_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let data = try FixtureLibrary(
            cxxSource: "static int value asm(\"_\(name)\") __attribute__((used)) = 42;"
        )
        let function = try FixtureLibrary()
        defer { data.cleanup(); function.cleanup() }
        let address = try function.address(kind: 0)
        let functionImage = try #require(
            try RuntimeSymbolResolver().images(matching: .path(function.libraryURL)).first
        ).identity
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { image, _, source in
            guard image.identity == functionImage, source == .loaded else { return nil }
            return capturedSources(named: name, at: address)
        })
        let symbol = try resolver.resolve(RuntimeDeclaration(name: name, language: .c))
        #expect(symbol.address == UInt64(address))
        #expect(symbol.source == .sharedCache)
    }

    @Test func malformedSharedCacheAddressesStillFailCrossImageResolution() throws {
        let name = "MalformedAddress_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let malformed = try FixtureLibrary()
        let function = try FixtureLibrary()
        defer { malformed.cleanup(); function.cleanup() }
        let address = try function.address(kind: 0)
        let lookup = RuntimeSymbolResolver()
        let malformedImage = try #require(
            try lookup.images(matching: .path(malformed.libraryURL)).first
        ).identity
        let functionImage = try #require(
            try lookup.images(matching: .path(function.libraryURL)).first
        ).identity
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { image, _, source in
            guard source == .loaded else { return nil }
            if image.identity == malformedImage { return capturedSources(named: name, at: 0) }
            guard image.identity == functionImage else { return nil }
            return capturedSources(named: name, at: address)
        })
        #expect(throws: RuntimeResolutionError.invalidAddress) {
            try resolver.resolve(RuntimeDeclaration(name: name, language: .c))
        }
    }

    @Test func batchLookupTraversesImageSymbolsOnceAndLeavesFallbacksLazy() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let address = UInt64(try fixture.address(kind: 0))
        let reads = Mutex(0)
        let names = [
            "_ABIBatchValue",
            "__ZN5First7Counter3oneEv",
            "__ZN5First7Counter3twoEv",
            "__ZN5First9Different3oneEv",
            "__ZN5First8Fallback3oneEv",
        ]
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { image, _, source in
            guard source == .loaded else { return nil }
            return SharedCacheSymbols.CapturedSymbols(
                slide: 0,
                readers: [
                    { record in
                        reads.withLock { $0 += 1 }
                        for name in names {
                            name.withCString { record($0, address) }
                        }
                    }
                ],
                imageIdentity: image.identity
            )
        })
        let selector = RuntimeImageSelector.path(fixture.libraryURL)
        let fallback = RuntimeDeclaration(name: "First::Fallback::one()", language: .cxx)
        let requests: [RuntimeSymbolRequest] = [
            .init(
                .init(name: "ABIBatchValue", language: .c),
                fallbacks: [fallback],
                in: [selector],
                loading: .loadedOnly
            ),
            .init(
                .init(name: "First::Counter::one()", language: .cxx),
                alternatives: [.init(machOName: "__ZN5First7Counter3oneEv", language: .cxx)],
                in: [selector],
                loading: .loadedOnly
            ),
            .init(
                .init(name: "First::Counter::two()", language: .cxx),
                in: [selector],
                loading: .loadedOnly
            ),
            .init(
                .init(name: "First::Different::one()", language: .cxx),
                in: [selector],
                loading: .loadedOnly
            ),
            .init(
                .init(name: "First::Missing::one()", language: .cxx),
                in: [selector],
                loading: .loadedOnly
            ),
        ]
        let results = resolver.resolve(requests)
        for result in results.dropLast() {
            #expect(try result.get().address == address)
        }
        #expect(throws: RuntimeResolutionError.declarationNotFound(requests.last!.declaration)) {
            try results.last!.get()
        }
        #expect(reads.withLock { $0 } == 1)
        #expect(
            try resolver.resolve(fallback, in: selector, loading: .loadedOnly).address == address
        )
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func concurrentLookupJoinsCapturedScan() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let address = try fixture.address(kind: 0)
        let gate = SharedCacheScanGate()
        let declaration = RuntimeDeclaration(name: "ABIBridgePreparedScanValue", language: .c)
        let selector = RuntimeImageSelector.path(fixture.libraryURL)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, requested, source in
            source == .loaded
                ? capturedSources(named: requested.name, at: address, gate: gate) : nil
        })
        let deadline = DispatchTime.now() + 30
        let prepared = SharedCacheScanWorker("Prepared lookup") {
            try resolver.resolve(declaration, in: selector, loading: .loadedOnly)
        }
        defer { gate.release.signal(); prepared.waitForCleanup() }
        try gate.waitUntilEntered(until: deadline)
        let invoked = SharedCacheScanWorker("Joining lookup") {
            try resolver.resolve(declaration, in: selector, loading: .loadedOnly)
        }
        defer { gate.release.signal(); invoked.waitForCleanup() }
        while !resolver.hasSharedCacheWaiters {
            guard DispatchTime.now() < deadline else {
                throw SharedCacheScanTestFailure(
                    message: "The second lookup did not join the running scan"
                )
            }
            await Task.yield()
        }
        #expect(gate.readCount == 1)
        gate.release.signal()
        #expect(try prepared.value(until: deadline).address == UInt64(address))
        #expect(try invoked.value(until: deadline).address == UInt64(address))
        #expect(gate.readCount == 1)
    }

    @Test func unrelatedLookupDoesNotWaitForWholeBatch() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let address = try fixture.address(kind: 0)
        let gate = SharedCacheScanGate()
        let first = RuntimeDeclaration(name: "ABIBridgeFirstPreparedValue", language: .c)
        let second = RuntimeDeclaration(name: "ABIBridgeSecondPreparedValue", language: .c)
        let selector = RuntimeImageSelector.path(fixture.libraryURL)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, requested, source in
            guard source == .loaded else { return nil }
            return capturedSources(
                named: requested.name,
                at: address,
                gate: requested == first ? gate : nil
            )
        })
        let deadline = DispatchTime.now() + 30
        let prepared = SharedCacheScanWorker("Prepared batch") {
            resolver.resolve(
                [first, second].map {
                    RuntimeSymbolRequest($0, in: [selector], loading: .loadedOnly)
                }
            )
        }
        defer { gate.release.signal(); prepared.waitForCleanup() }
        try gate.waitUntilEntered(until: deadline)
        let invoked = SharedCacheScanWorker("Unrelated lookup") {
            try resolver.resolve(second, in: selector, loading: .loadedOnly)
        }
        defer { gate.release.signal(); invoked.waitForCleanup() }
        #expect(try invoked.value(until: deadline).address == UInt64(address))
        gate.release.signal()
        let results = try prepared.value(until: deadline)
        #expect(results.count == 2)
        for result in results { #expect(try result.get().address == UInt64(address)) }
        #expect(gate.readCount == 1)
    }

    @Test func otherImagesAndCacheClearingDoNotWaitForIndexRead() throws {
        let gated = try FixtureLibrary(), other = try FixtureLibrary()
        defer { gated.cleanup(); other.cleanup() }
        let gatedIdentity = try #require(
            try RuntimeSymbolResolver().images(matching: .path(gated.libraryURL)).first
        ).identity
        let gate = SharedCacheScanGate()
        let resolver = RuntimeSymbolResolver(whileReadingIndex: { image in
            if image.identity == gatedIdentity { gate.read() }
        })
        let gatedAdd = RuntimeDeclaration(name: gated.namespace + "::add(int, int)", language: .cxx)
        let otherAdd = RuntimeDeclaration(name: other.namespace + "::add(int, int)", language: .cxx)
        let counter = RuntimeDeclaration(
            name: other.namespace + "::counter",
            language: .cxx,
            kind: .data
        )
        let gatedScope = RuntimeImageSelector.path(gated.libraryURL)
        let otherScope = RuntimeImageSelector.path(other.libraryURL)
        let warm = try resolver.resolve(otherAdd, in: otherScope, loading: .loadedOnly)
        let deadline = DispatchTime.now() + 30
        let blocked = SharedCacheScanWorker("Gated index read") {
            try resolver.resolve(gatedAdd, in: gatedScope, loading: .loadedOnly)
        }
        defer { gate.release.signal(); blocked.waitForCleanup() }
        try gate.waitUntilEntered(until: deadline)
        let unrelated = SharedCacheScanWorker("Lookups in another image") {
            let reused = try resolver.resolve(otherAdd, in: otherScope, loading: .loadedOnly)
            let scanned = try resolver.resolve(counter, in: otherScope, loading: .loadedOnly)
            resolver.removeCachedResults()
            return [reused.address, scanned.address]
        }
        defer { gate.release.signal(); unrelated.waitForCleanup() }
        #expect(
            try unrelated.value(until: deadline)
                == [warm.address, UInt64(try other.address(kind: 1))]
        )
        gate.release.signal()
        let expected = UInt64(try gated.address(kind: 0))
        #expect(try blocked.value(until: deadline).address == expected)
        // The read that the clear interrupted must not publish its symbol.
        #expect(
            try resolver.resolve(gatedAdd, in: gatedScope, loading: .loadedOnly).address == expected
        )
        #expect(gate.readCount == 2)
    }

    @Test func cacheClearDetachesRunningScan() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let oldAddress = try fixture.address(kind: 1)
        let currentAddress = try fixture.address(kind: 2)
        #expect(oldAddress != currentAddress)
        let gate = SharedCacheScanGate()
        let declaration = RuntimeDeclaration(
            name: "ABIBridgeClearedScanValue",
            language: .c,
            kind: .data
        )
        let selector = RuntimeImageSelector.path(fixture.libraryURL)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, requested, source in
            guard source == .loaded else { return nil }
            return SharedCacheSymbols.CapturedSymbols(
                slide: 0,
                readers: [
                    { record in
                        let read = gate.read()
                        let address = read == 1 ? oldAddress : currentAddress
                        ("_" + requested.name).withCString { record($0, UInt64(address)) }
                    }
                ]
            )
        })
        let deadline = DispatchTime.now() + 30
        let old = SharedCacheScanWorker("Old lookup") {
            try resolver.resolve(declaration, in: selector, loading: .loadedOnly)
        }
        defer { gate.release.signal(); old.waitForCleanup() }
        try gate.waitUntilEntered(until: deadline)
        resolver.removeCachedResults()
        let current = SharedCacheScanWorker("Lookup after cache clear") {
            try resolver.resolve(declaration, in: selector, loading: .loadedOnly)
        }
        defer { gate.release.signal(); current.waitForCleanup() }
        #expect(try current.value(until: deadline).address == UInt64(currentAddress))
        #expect(gate.readCount == 2)
        gate.release.signal()
        #expect(try old.value(until: deadline).address == UInt64(oldAddress))
        #expect(
            try resolver.resolve(declaration, in: selector, loading: .loadedOnly).address
                == UInt64(currentAddress)
        )
        #expect(gate.readCount == 2)
    }

    @Test func sourceCaptureCanReenterResolverAndClearCaches() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let address = try fixture.address(kind: 0)
        let holder = Mutex<RuntimeSymbolResolver?>(nil)
        let reentered = Mutex<Result<RuntimeSymbol, any Error>?>(nil)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, requested, source in
            guard source == .loaded else { return nil }
            let resolver = holder.withLock { $0! }
            let result = Result {
                try resolver.resolve(RuntimeDeclaration(name: "getpid", language: .c))
            }
            reentered.withLock { $0 = result }
            resolver.removeCachedResults()
            return capturedSources(named: requested.name, at: address)
        })
        holder.withLock { $0 = resolver }
        defer { holder.withLock { $0 = nil } }
        let selector = RuntimeImageSelector.path(fixture.libraryURL)
        let deadline = DispatchTime.now() + 30
        let lookup = SharedCacheScanWorker("Reentrant lookup") {
            try resolver.resolve(
                RuntimeDeclaration(name: "ABIBridgeReentrantScanValue", language: .c),
                in: selector,
                loading: .loadedOnly
            )
        }
        defer { lookup.waitForCleanup() }
        #expect(try lookup.value(until: deadline).address == UInt64(address))
        let result = try #require(reentered.withLock { $0 })
        #expect(try result.get().declaration.name == "getpid")
        resolver.removeCachedResults()
    }
}
#endif
