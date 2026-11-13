import ABIBridgeTestSupport
#if os(macOS) && DEBUG
@testable import ABIBridgeRuntime
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct AutomaticLookupCacheTests {
    @Test func repeatedMissingInstallNameLookupDoesNotReloadTheImage() throws {
        let counter = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: counter) }
        let fixture = try FixtureLibrary(
            load: false,
            cxxSource: """
                #include <stdio.h>
                __attribute__((constructor)) static void countLoad() {
                    FILE *file = fopen("\(counter.path)", "a");
                    if (file) { fputs("1", file); fclose(file); }
                }
                """
        )
        defer { fixture.cleanup() }
        let resolver = RuntimeSymbolResolver()
        let declaration = RuntimeDeclaration(name: "ABIBridgeAbsentConstructorProbe", language: .c)
        for _ in 0..<2 {
            #expect(throws: RuntimeResolutionError.declarationNotFound(declaration)) {
                try resolver.resolve(declaration, in: .installName(fixture.libraryURL.path))
            }
        }
        #expect(try String(contentsOf: counter, encoding: .utf8) == "1")
    }

    @Test(arguments: [false, true], [false, true])
    func lookupIndexesAreReleasedAfterBatch(throwing: Bool, asynchronous: Bool) async throws {
        enum BatchFailure: Error { case expected }
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let resolver = RuntimeSymbolResolver(keepingLookupIndexesFor: .zero)
        let declaration = RuntimeDeclaration(
            name: fixture.namespace + "::add(int, int)",
            language: .cxx
        )
        weak var index: SymbolIndex?
        var symbol: RuntimeSymbol?
        func resolve() throws {
            symbol = try resolver.resolve(declaration, in: .path(fixture.libraryURL))
            index = resolver.cachedSymbolIndexes.first
            #expect(index != nil)
        }
        func verify() throws {
            try resolver.withCachedLookups {
                _ = try resolver.resolve(declaration, in: .path(fixture.libraryURL))
            }
            #expect(index != nil)
            if throwing { throw BatchFailure.expected }
        }
        do {
            if asynchronous {
                try await resolver.withCachedLookups {
                    try resolve()
                    await Task.yield()
                    try verify()
                }
            } else {
                try resolver.withCachedLookups {
                    try resolve()
                    try verify()
                }
            }
        } catch BatchFailure.expected {
            #expect(throwing)
        }
        #expect(index == nil)
        let retained = try #require(symbol)
        let reused = try resolver.resolve(declaration, in: .path(fixture.libraryURL))
        #expect(reused.address == retained.address)
        #expect(reused.image.lease === retained.image.lease)
        #expect(resolver.cachedSymbolIndexes.isEmpty)
    }

    @Test func lookupIndexesOutliveABatchForTheirRetention() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let declaration = RuntimeDeclaration(
            name: fixture.namespace + "::add(int, int)",
            language: .cxx
        )
        let kept = RuntimeSymbolResolver(keepingLookupIndexesFor: .seconds(3600))
        _ = try kept.resolve(declaration, in: .path(fixture.libraryURL))
        let index = try #require(kept.cachedSymbolIndexes.first)
        try kept.withCachedLookups {
            #expect(kept.cachedSymbolIndexes.first === index)
        }

        let released = RuntimeSymbolResolver(keepingLookupIndexesFor: .milliseconds(10))
        _ = try released.resolve(declaration, in: .path(fixture.libraryURL))
        let deadline = ContinuousClock.now + .seconds(30)
        while !released.cachedSymbolIndexes.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released.cachedSymbolIndexes.isEmpty)
    }

    @Test func retiredTablesAreFreedOnTheWorker() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let caller = UInt(bitPattern: pthread_self())
        let freedOnCaller = Mutex<[Bool]>([])
        let holder = Mutex<SymbolTableRetirement?>(nil)
        // The worker finishes before the ending thread drops its own reference.
        let retirement = SymbolTableRetirement(limit: .max, afterRetiring: {
            holder.withLock { $0 }?.waitForWorker()
        })
        holder.withLock { $0 = retirement }
        defer { holder.withLock { $0 = nil } }
        let resolver = RuntimeSymbolResolver(retiringTablesWith: retirement) {
            freedOnCaller.withLock { $0.append(UInt(bitPattern: pthread_self()) == caller) }
        }
        _ = try resolver.resolve(
            RuntimeDeclaration(name: fixture.namespace + "::add(int, int)", language: .cxx),
            in: .path(fixture.libraryURL)
        )
        retirement.waitForWorker()
        #expect(freedOnCaller.withLock { $0 } == [false])
    }

    @Test func tableBuildsFreeADelayedWorkersBacklog() throws {
        let first = try FixtureLibrary(), second = try FixtureLibrary()
        defer { first.cleanup(); second.cleanup() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let freed = Mutex(0)
        let retirement = SymbolTableRetirement(limit: 0, beforeReleasing: {
            _ = release.wait(timeout: .now() + 30)
        })
        let resolver = RuntimeSymbolResolver(retiringTablesWith: retirement) {
            freed.withLock { $0 += 1 }
        }
        func add(in fixture: FixtureLibrary) throws {
            _ = try resolver.resolve(
                RuntimeDeclaration(name: fixture.namespace + "::add(int, int)", language: .cxx),
                in: .path(fixture.libraryURL)
            )
        }
        try add(in: first)
        #expect(resolver.cachedSymbolIndexes.isEmpty)
        #expect(freed.withLock { $0 } == 0)
        try resolver.withCachedLookups {
            try add(in: second)
            // Building the second image's tables freed the first's.
            #expect(freed.withLock { $0 } == 1)
        }
        release.signal()
        retirement.waitForWorker()
        #expect(freed.withLock { $0 } == 2)
    }

    @Test func wrongKindLocalSymbolsDoNotHideFunctionsInOtherImages() throws {
        let name = "KindCollision_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let data = try FixtureLibrary(
            cxxSource: "static int value asm(\"_\(name)\") __attribute__((used)) = 42;"
        )
        let function = try FixtureLibrary(
            load: false,
            cxxSource:
                "extern \"C\" __attribute__((visibility(\"hidden\"))) int \(name)() { return 42; }"
        )
        defer { data.cleanup(); function.cleanup() }
        let resolver = RuntimeSymbolResolver()
        let declaration = RuntimeDeclaration(name: name, language: .c)
        #expect(throws: RuntimeResolutionError.invalidAddress) {
            try resolver.resolve(declaration)
        }
        try function.load()
        let expected = try #require(try resolver.images(matching: .path(function.libraryURL)).first)
        #expect(try resolver.resolve(declaration).image.identity == expected.identity)
        #expect(throws: RuntimeResolutionError.invalidAddress) {
            try resolver.resolve(declaration, in: .path(data.libraryURL), loading: .loadedOnly)
        }
    }

    @Test(arguments: [RuntimeLanguage.c, .cxx, .swift])
    func laterLoadsReplaceNegativeAndUniqueResults(language: RuntimeLanguage) async throws {
        let module = "Catalog_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let source: String
        let name: String
        switch language {
        case .c:
            source = "extern \"C\" int \(module)() { return 42; }"
            name = module
        case .cxx:
            source = "namespace \(module) { int answer() { return 42; } }"
            name = module + "::answer()"
        default:
            source = "public func answer() -> Int { 42 }"
            name = module + ".answer() -> Swift.Int"
        }
        func fixture() throws -> FixtureLibrary {
            try language == .swift
                ? FixtureLibrary(load: false, swiftModule: module, swiftSource: source)
                : FixtureLibrary(load: false, cxxSource: source)
        }
        let first = try fixture(), second = try fixture()
        defer { first.cleanup(); second.cleanup() }
        let runtime = RuntimeSymbolResolver()
        let declaration = RuntimeDeclaration(name: name, language: language)
        for _ in 0..<2 {
            await #expect(throws: RuntimeResolutionError.declarationNotFound(declaration)) {
                _ = try await runtime.resolve(declaration)
            }
        }
        try first.load()
        let expected = try #require(
            try await runtime.images(matching: .path(first.libraryURL)).first
        ).identity
        let symbol = try await runtime.resolve(declaration)
        #expect(symbol.image.identity == expected)
        #expect(try await runtime.resolve(declaration).image.identity == symbol.image.identity)
        try second.load()
        for _ in 0..<2 {
            do {
                _ = try await runtime.resolve(declaration)
                Issue.record("Newly loaded competing definitions must invalidate a unique result")
            } catch RuntimeResolutionError.ambiguousDeclaration(let actual, let candidates) {
                #expect(actual == declaration)
                #expect(candidates.count == 2)
            }
        }
        #expect(
            try await runtime.resolve(declaration, in: symbol.image, loading: .loadedOnly).image
                .identity == symbol.image.identity
        )
        await runtime.removeCachedResults()
    }

    @Test func cacheClearingCanRaceWithNativeResolution() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let resolver = RuntimeSymbolResolver()
        let expected = try #require(try resolver.images(matching: .path(fixture.libraryURL)).first)
            .identity
        let declaration = RuntimeDeclaration(
            name: fixture.namespace + "::add(int, int)",
            language: .cxx
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    for _ in 0..<10 {
                        let symbol = try resolver.resolve(
                            declaration,
                            in: .automatic,
                            loading: .loadedOnly
                        )
                        #expect(symbol.image.identity == expected)
                    }
                }
            }
            group.addTask {
                for _ in 0..<30 { resolver.removeCachedResults() }
            }
            try await group.waitForAll()
        }
        resolver.removeCachedResults()
    }
}
#endif
