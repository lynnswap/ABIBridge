#if os(macOS) && DEBUG
@testable import ABIBridgeRuntime
import ABIBridgeTestSupport
import Foundation
import Synchronization
import Testing

private final class CachedImageTestClass {}

@Suite(.serialized)
struct CachePublicationTests {
    @Test func automaticScopeIsNotRepublishedAfterClear() throws {
        let declaration = RuntimeDeclaration(name: "getpid", language: .c)
        let warmup = RuntimeSymbolResolver()
        _ = try warmup.resolve(declaration)
        let publications = Mutex(0)
        let resolver = RuntimeSymbolResolver(beforePublishingCache: { cache, resolver in
            guard case .automaticScope = cache else { return }
            let count = publications.withLock { count in
                count += 1; return count
            }
            if count == 1 { resolver.removeCachedResults() }
        })
        let original = try resolver.resolve(declaration)
        #expect(publications.withLock { $0 } == 1)
        let current = try resolver.resolve(declaration)
        #expect(current.address == original.address)
        #expect(publications.withLock { $0 } == 2)
        #expect(try resolver.resolve(declaration).address == current.address)
        #expect(publications.withLock { $0 } == 2)
    }

    @Test func classImageLookupDoesNotPublishAcrossClear() throws {
        let first = try FixtureLibrary(), second = try FixtureLibrary()
        defer { first.cleanup(); second.cleanup() }
        let resolver = RuntimeSymbolResolver()
        let firstImage = try #require(resolver.images(matching: .path(first.libraryURL)).first)
        let secondImage = try #require(resolver.images(matching: .path(second.libraryURL)).first)
        var lookups = 0
        let original = try resolver.image(forSwiftClass: CachedImageTestClass.self) {
            lookups += 1
            resolver.removeCachedResults()
            return firstImage
        }
        #expect(original.identity == firstImage.identity)
        let current = try resolver.image(forSwiftClass: CachedImageTestClass.self) {
            lookups += 1
            return secondImage
        }
        #expect(current.identity == secondImage.identity)
        #expect(lookups == 2)
        let cached = try resolver.image(forSwiftClass: CachedImageTestClass.self) {
            lookups += 1
            return firstImage
        }
        #expect(cached.identity == current.identity)
        #expect(lookups == 2)
    }

    @Test func importIndexIsNotRepublishedAfterClear() throws {
        let fixture = try FixtureLibrary(
            cxxSource:
                "#include <unistd.h>\nextern \"C\" int ABICacheImportCall() { return getpid(); }",
            linkArguments: ["-Wl,-fixup_chains"]
        )
        defer { fixture.cleanup() }
        let originalFile = fixture.libraryURL
        let movedFile = fixture.directory.appendingPathComponent("original.dylib")
        let moved = Mutex<Result<Void, any Error>?>(nil)
        let resolver = RuntimeSymbolResolver(beforePublishingCache: { cache, resolver in
            guard case .importIndex = cache else { return }
            resolver.removeCachedResults()
            let result = Result {
                try FileManager.default.moveItem(at: originalFile, to: movedFile)
            }
            moved.withLock { $0 = result }
        })
        let image = try #require(resolver.images(matching: .path(originalFile)).first)
        let original = try resolver.importIndex(for: image)
        try #require(moved.withLock { $0 }).get()
        #expect((try original.matches(.init(name: "getpid", language: .c))).isEmpty == false)
        do {
            _ = try resolver.importIndex(for: image)
            Issue.record(
                "A cleared import index was republished after its original file disappeared"
            )
        } catch RuntimeResolutionError.metadataUnavailable {}
        #expect((try original.matches(.init(name: "getpid", language: .c))).isEmpty == false)
    }

    @Test func virtualEntryIndexIsNotRepublishedAfterClear() throws {
        let namespace =
            "CachePublication_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let fixture = try FixtureLibrary(
            cxxSource: """
                namespace \(namespace) { int value(int value) { return value + 1; } }
                using Function = int (*)(int);
                extern "C" { Function ABICacheVirtualTable[] = {\(namespace)::value}; }
                """,
            linkArguments: ["-Wl,-fixup_chains"]
        )
        defer { fixture.cleanup() }
        let originalFile = fixture.libraryURL
        let movedFile = fixture.directory.appendingPathComponent("original.dylib")
        let moved = Mutex<Result<Void, any Error>?>(nil)
        let resolver = RuntimeSymbolResolver(beforePublishingCache: { cache, resolver in
            guard case .virtualEntries = cache else { return }
            resolver.removeCachedResults()
            let result = Result {
                try FileManager.default.moveItem(at: originalFile, to: movedFile)
            }
            moved.withLock { $0 = result }
        })
        let table = try resolver.resolve(
            .init(name: "ABICacheVirtualTable", language: .c, kind: .data),
            in: .path(originalFile),
            loading: .loadedOnly
        )
        let name = namespace + "::value(int)"
        let original = try resolver.virtualEntry(
            named: name,
            addressPoint: UInt(table.address),
            entryCount: 1
        )
        try #require(moved.withLock { $0 }).get()
        #expect(original.index == 0)
        #expect(original.image.identity == table.image.identity)
        do {
            _ = try resolver.virtualEntry(
                named: name,
                addressPoint: UInt(table.address),
                entryCount: 1
            )
            Issue.record(
                "A cleared virtual-entry index was republished after its original file disappeared"
            )
        } catch RuntimeResolutionError.metadataUnavailable {}
    }
}
#endif
