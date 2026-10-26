import ABIBridgeTestSupport
#if os(macOS) && DEBUG
@testable import ABIBridgeRuntime
import Foundation
import Testing

@Suite(.serialized)
struct AutomaticLookupCacheTests {
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
