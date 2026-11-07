#if os(macOS) && DEBUG
@testable import ABIBridgeRuntime
import ABIBridgeTestSupport
import Foundation
import Synchronization
import Testing

private final class CachedImageTestClass {}
private let initializingImageLookup = Mutex<(@Sendable () -> Void)?>(nil)

@Suite(.serialized)
struct CachePublicationTests {
    @Test func retainedLeasesDoNotExposeAnInitializingImageToAnotherThread() throws {
        let callback: @convention(c) () -> Void = {
            initializingImageLookup.withLock { $0 }?()
        }
        let address = unsafe UInt(bitPattern: unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let fixture = try FixtureLibrary(
            load: false,
            cxxSource: """
                extern "C" int ABICacheInitializingValue = 42;
                __attribute__((constructor)) static void initialize() {
                    reinterpret_cast<void (*)()>(\(address))();
                }
                """
        )
        defer { fixture.cleanup() }
        let path = fixture.libraryURL.path
        let scope = RuntimeImageSelector.path(fixture.libraryURL)
        let declaration = RuntimeDeclaration(
            name: "ABICacheInitializingValue",
            language: .c,
            kind: .data
        )
        let resolver = RuntimeSymbolResolver()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let initialLookup = Mutex<Result<RuntimeSymbol, any Error>?>(nil)
        let loaded = Mutex<Result<RuntimeImage, any Error>?>(nil)
        initializingImageLookup.withLock {
            $0 = {
                let result = Result {
                    try resolver.resolve(declaration, in: scope, loading: .loadedOnly)
                }
                initialLookup.withLock { $0 = result }
                entered.signal()
                #expect(release.wait(timeout: .now() + 30) == .success)
            }
        }
        finished.enter()
        Thread {
            let result = Result { try RuntimeImage.opening(path: path) }
            loaded.withLock { $0 = result }
            finished.leave()
        }.start()
        defer {
            release.signal()
            #expect(finished.wait(timeout: .now() + 30) == .success)
            initializingImageLookup.withLock { $0 = nil }
        }
        try #require(entered.wait(timeout: .now() + 30) == .success)
        let original = try #require(initialLookup.withLock { $0 }).get()
        #expect(throws: RuntimeResolutionError.imageUnavailable) {
            try resolver.resolve(declaration, in: scope, loading: .loadedOnly)
        }
        release.signal()
        try #require(finished.wait(timeout: .now() + 30) == .success)
        _ = try #require(loaded.withLock { $0 }).get()
        #expect(
            try resolver.resolve(declaration, in: scope, loading: .loadedOnly).address
                == original.address
        )
    }

    @Test func fileNotificationsInvalidateNestedSymbolicLinks() async throws {
        let first = try FixtureLibrary(), second = try FixtureLibrary()
        defer { first.cleanup(); second.cleanup() }
        let intermediate = second.directory.appendingPathComponent("target.dylib")
        let alias = first.directory.appendingPathComponent("alias.dylib")
        try FileManager.default.createSymbolicLink(
            at: intermediate,
            withDestinationURL: first.libraryURL
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: intermediate)
        let resolver = RuntimeSymbolResolver()
        let path = RuntimeImageSelector.path(alias)
        let original = try #require(resolver.acquireImages(path, loading: .ifNeeded).first)
        let expected = try #require(
            resolver.acquireImages(.path(second.libraryURL), loading: .ifNeeded).first
        )
        try FileManager.default.removeItem(at: intermediate)
        try FileManager.default.createSymbolicLink(
            at: intermediate,
            withDestinationURL: second.libraryURL
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let current = try #require(resolver.acquireImages(path, loading: .ifNeeded).first)
            if current.identity == expected.identity {
                #expect(current.identity != original.identity)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The symbolic-link notification did not invalidate the cached path")
    }

    @Test func pathAcquisitionIsNotRepublishedAfterClear() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let publications = Mutex(0)
        let resolver = RuntimeSymbolResolver(beforePublishingCache: { cache, resolver in
            guard case .pathImage = cache else { return }
            let count = publications.withLock { count in
                count += 1; return count
            }
            if count == 1 { resolver.removeCachedResults() }
        })
        let path = RuntimeImageSelector.path(fixture.libraryURL)
        let first = try #require(resolver.acquireImages(path, loading: .ifNeeded).first)
        let current = try #require(resolver.acquireImages(path, loading: .ifNeeded).first)
        #expect(current.lease !== first.lease)
        let cached = try #require(resolver.acquireImages(path, loading: .ifNeeded).first)
        #expect(cached.lease === current.lease)
        #expect(publications.withLock { $0 } == 2)
    }

    @Test func pathAcquisitionsReuseTheirLeaseAndClearWithTheResolver() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let resolver = RuntimeSymbolResolver()
        let path = RuntimeImageSelector.path(fixture.libraryURL)
        let first = try #require(resolver.acquireImages(path, loading: .ifNeeded).first)
        let repeated = try #require(resolver.acquireImages(path, loading: .ifNeeded).first)
        #expect(repeated.lease === first.lease)
        let inspection = try #require(resolver.acquireImages(path, loading: .loadedOnly).first)
        #expect(inspection.lease === first.lease)
        let finished = DispatchSemaphore(value: 0)
        let acquired = Mutex<Result<RuntimeImage?, any Error>?>(nil)
        Thread {
            let result = Result { try resolver.acquireImages(path, loading: .ifNeeded).first }
            acquired.withLock { $0 = result }
            finished.signal()
        }.start()
        #expect(finished.wait(timeout: .now() + 10) == .success)
        let result = try #require(acquired.withLock { $0 })
        let otherThread = try #require(try result.get())
        let shared = try #require(resolver.acquireImages(path, loading: .ifNeeded).first)
        #expect(shared.lease === otherThread.lease)
        resolver.removeCachedResults()
        let reopened = try #require(resolver.acquireImages(path, loading: .ifNeeded).first)
        #expect(reopened.identity == first.identity)
        #expect(reopened.lease !== first.lease)
    }

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
