#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
import Testing

@Suite(.serialized)
struct AutomaticLookupCacheTests {
    @Test(arguments: [NativeLanguage.c, .cxx, .swift])
    func laterLoadsReplaceNegativeAndUniqueResults(language: NativeLanguage) async throws {
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
        let runtime = ABIRuntime()
        let declaration = NativeDeclaration(name: name, language: language)
        for _ in 0..<2 {
            await #expect(throws: ABIResolutionError.declarationNotFound(declaration)) {
                _ = try await runtime.resolve(declaration)
            }
        }
        try first.load()
        let expected = try #require(try await runtime.images(matching: .path(first.libraryURL)).first).identity
        let symbol = try await runtime.resolve(declaration)
        #expect(symbol.image.identity == expected)
        #expect(try await runtime.resolve(declaration).image.identity == symbol.image.identity)
        try second.load()
        for _ in 0..<2 {
            do {
                _ = try await runtime.resolve(declaration)
                Issue.record("Newly loaded competing definitions must invalidate a unique result")
            } catch ABIResolutionError.ambiguousDeclaration(let actual, let candidates) {
                #expect(actual == declaration)
                #expect(candidates.count == 2)
            }
        }
        #expect(try await runtime.resolve(declaration, in: symbol.image, loading: .loadedOnly).image.identity == symbol.image.identity)
        await runtime.removeCachedResults()
    }

    @Test func cacheClearingCanRaceWithNativeResolution() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let resolver = SymbolResolver()
        let expected = try #require(try resolver.images(matching: .path(fixture.libraryURL)).first).identity
        let declaration = NativeDeclaration(name: fixture.namespace + "::add(int, int)", language: .cxx)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    for _ in 0..<10 {
                        let symbol = try resolver.resolve(declaration, in: .automatic, loading: .loadedOnly)
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
