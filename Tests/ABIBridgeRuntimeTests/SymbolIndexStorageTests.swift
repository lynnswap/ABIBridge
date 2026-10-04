#if os(macOS) && DEBUG
@testable import ABIBridgeRuntime
import ABIBridgeTestSupport
import Foundation
import Testing

struct SymbolIndexStorageTests {
    @Test(arguments: [false, true])
    func extensionAndOrdinaryIndexesCanBeBuiltInEitherOrder(extensionFirst: Bool) async throws {
        let module = "IndexOrder_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let fixture = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public func echo() -> Int { 42 }
                extension Int { public func café() -> Int { self } }
                extension String { public func café() -> Int { count } }
                """
        )
        defer { fixture.cleanup() }
        let runtime = RuntimeSymbolResolver()
        let image = try #require(try runtime.images(matching: .path(fixture.libraryURL)).first)
        let index = SymbolIndex(image: image)
        let ordinary = RuntimeDeclaration(name: module + ".echo() -> Swift.Int", language: .swift)
        let member = RuntimeDeclaration(name: "Swift.Int.café() -> Swift.Int", language: .swift)
        for extensionsOnly in [extensionFirst, !extensionFirst, extensionFirst] {
            let symbol = try #require(
                try index.resolve(
                    extensionsOnly ? member : ordinary,
                    source: .image,
                    extensionsOnly: extensionsOnly
                )
            )
            #expect(symbol.image.identity == image.identity)
            let stringMember = RuntimeDeclaration(
                name: "Swift.String.café() -> Swift.Int",
                language: .swift
            )
            #expect(try index.resolve(stringMember, source: .image, extensionsOnly: true) != nil)
        }
    }

    @Test func appendedLocalSymbolsInvalidateEmptyCandidateGroups() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = RuntimeSymbolResolver()
        let image = try #require(try runtime.images(matching: .path(fixture.libraryURL)).first)
        let declaration = RuntimeDeclaration(name: "ABICacheFixture::add(int, int)", language: .cxx)
        let expected = try fixture.address(kind: 0)
        let index = SymbolIndex(image: image)
        #expect(index.matches(declaration).isEmpty)
        let exact = RuntimeDeclaration(machOName: "__ZN15ABICacheFixture3addEii", language: .cxx)
        #expect(index.matches(exact).isEmpty)
        index.appendSharedCacheSymbols(
            [
                IndexedSymbol(
                    name: "__ZN15ABICacheFixture3addEii",
                    address: UInt64(expected),
                    source: .sharedCache
                )
            ],
            matching: SymbolQuery(declaration)
        )
        let resolved = try #require(try index.resolve(declaration, source: .sharedCache))
        #expect(unsafe resolved.withUnsafeAddress { UInt(bitPattern: $0) } == expected)
        let exactResolved = try #require(try index.resolve(exact, source: .sharedCache))
        #expect(unsafe exactResolved.withUnsafeAddress { UInt(bitPattern: $0) } == expected)
    }

}
#endif
