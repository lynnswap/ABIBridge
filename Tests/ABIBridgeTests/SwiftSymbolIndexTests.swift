#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
import MachO
import MachOKit
import Testing

struct SwiftSymbolIndexTests {
    @Test func protocolDescriptorsPreserveCompressedNamesAmbiguityAndOtherLookups() async throws {
        let fixture = try FixtureLibrary(cxxSource: """
        extern "C" int first asm("_$s5First8ReadableMp") = 1;
        extern "C" int second asm("_$s6Second8ReadableMp") = 2;
        extern "C" int compressed asm("_$s03FooA08ReadableMp") = 3;
        extern "C" int literal asm("_$s6FooFoo8ReadableMp") = 4;
        extern "C" void echo() asm("_$s5First4echoyyF");
        void echo() {}
        """)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let image = try #require(try await runtime.images(matching: .path(fixture.libraryURL)).first)
        let index = SymbolIndex(image: image)
        let first = NativeDeclaration(name: "protocol descriptor for First.Readable", language: .swift, kind: .data)
        let second = NativeDeclaration(name: "protocol descriptor for Second.Readable", language: .swift, kind: .data)
        let function = NativeDeclaration(name: "First.echo() -> ()", language: .swift)
        for declaration in [first, function, second, first] {
            let symbol = try #require(try index.resolve(declaration, source: .image))
            #expect(symbol.image.identity == image.identity)
        }
        do {
            _ = try index.resolve(.init(name: "protocol descriptor for FooFoo.Readable", language: .swift, kind: .data), source: .image)
            Issue.record("Literal and compressed protocol descriptors at different addresses must remain ambiguous")
        } catch ABIResolutionError.ambiguousDeclaration(_, let candidates) { #expect(candidates.count == 2) }
    }

    @Test func protocolDescriptorQueriesPruneUnrelatedLiteralModules() throws {
        let query = SymbolQuery(.init(name: "  protocol descriptor for SwiftUI.View\n", language: .swift, kind: .data))
        let filter = try #require(query.swiftModule)
        #expect(query.candidateScope == .swiftModule("SwiftUI"))
        #expect("_$s7SwiftUI4ViewMp".withCString(query.acceptsCandidate))
        #expect(!"_$s7Combine9PublisherMp".withCString(query.acceptsCandidate))
        #expect(filter.matches("_$s7SwiftUI", partial: true))
        #expect(!filter.matches("_$s7Combine", partial: true))
        for name in ["_$s03FooA05ValueMp", "_$sSQMp"] {
            #expect(name.withCString(query.acceptsCandidate))
        }
    }

    @Test func protocolDescriptorsKeepCompressedFallbackAndAmbiguity() async throws {
        let fixture = try FixtureLibrary(cxxSource: """
        #include <cstdint>
        extern "C" {
        int descriptors[2] = {1, 2};
        uintptr_t ABIFixtureAddress(int kind) { return reinterpret_cast<uintptr_t>(&descriptors[kind]); }
        }
        """)
        defer { fixture.cleanup() }
        let image = try #require(try await ABIRuntime().images(matching: .path(fixture.libraryURL)).first)
        let query = SymbolQuery(.init(name: "protocol descriptor for FooFoo.Value", language: .swift, kind: .data))
        let compressed = IndexedSymbol(name: "_$s03FooA05ValueMp", address: UInt64(try fixture.address(kind: 0)), source: .sharedCache)
        let literal = IndexedSymbol(name: "_$s6FooFoo5ValueMp", address: UInt64(try fixture.address(kind: 1)), source: .sharedCache)
        for symbol in [compressed, literal] {
            let index = SymbolIndex(image: image)
            index.appendSharedCacheSymbols([symbol], matching: query)
            let resolved = try #require(try index.resolve(query, source: .sharedCache))
            #expect(resolved.linkageName == symbol.name)
        }
        let index = SymbolIndex(image: image)
        index.appendSharedCacheSymbols([compressed, literal], matching: query)
        do {
            _ = try index.resolve(query, source: .sharedCache)
            Issue.record("Literal and compressed protocol descriptors at different addresses must remain ambiguous")
        } catch ABIResolutionError.ambiguousDeclaration(_, let candidates) { #expect(candidates.count == 2) }
    }

    @Test func mappedLocalNamesRespectRangesAndTableBounds() throws {
        let names = Array("_plain\0_$s5First4echoyyF\0unterminated".utf8)
        var data = Data(repeating: 0, count: 7)
        for (offset, address) in [(UInt32(0), UInt64(0x1000)), (7, 0x2000), (.max, 0x3000), (27, 0x4000)] {
            var entry = nlist_64()
            entry.n_un.n_strx = offset
            entry.n_value = address
            withUnsafeBytes(of: entry) { data.append(contentsOf: $0) }
        }
        let stringsOffset = data.count - 7
        data.append(contentsOf: names)
        var layout = DyldCacheLocalSymbolsInfo.Layout()
        layout.nlistCount = 4
        layout.stringsOffset = UInt32(stringsOffset)
        layout.stringsSize = UInt32(names.count)
        let table = try #require(SharedCacheSymbols.MappedSymbols(data: data, localSymbolsOffset: 7, layout: layout))
        data.removeAll()
        var actual: [(String, UInt64)] = []
        table.forEach(in: 0..<4) { actual.append((String(cString: $0), $1)) }
        #expect(actual.map(\.0) == ["_plain", "_$s5First4echoyyF"])
        #expect(actual.map(\.1) == [0x1000, 0x2000])
        actual.removeAll()
        table.forEach(in: 1..<4) { actual.append((String(cString: $0), $1)) }
        #expect(actual.map(\.0) == ["_$s5First4echoyyF"])
        #expect(SharedCacheSymbols.MappedSymbols(data: Data(repeating: 0, count: 8), localSymbolsOffset: 7, layout: layout) == nil)
        #expect(SharedCacheSymbols.MappedSymbols(data: Data(), localSymbolsOffset: .max, layout: layout) == nil)
    }

    @Test func sharedFallbackHandlesDifferentModulesExtensionsAndAmbiguity() async throws {
        let module = "FallbackFixture"
        let fixture = try FixtureLibrary(swiftModule: module, swiftSource: """
        @_silgen_name("$s03FooA04echoyyF") public func first() {}
        @_silgen_name("$s03BarA04echoyyF") public func second() {}
        @_silgen_name("$s03FooA06answerSiyF") public func compressed() -> Int { 1 }
        @_silgen_name("$s6FooFoo6answerSiyF") public func literal() -> Int { 2 }
        public func ordinary() {}
        extension Int { public func _abiFallbackOrderFixture() -> Int { self } }
        """)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let image = try #require(try await runtime.images(matching: .path(fixture.libraryURL)).first)
        let index = SymbolIndex(image: image)
        for name in ["FooFoo.echo() -> ()", "BarBar.echo() -> ()", module + ".ordinary() -> ()", "FooFoo.echo() -> ()"] {
            #expect(try index.resolve(.init(name: name, language: .swift), source: .image) != nil)
        }
        let extensionName = "Swift.Int._abiFallbackOrderFixture() -> Swift.Int"
        #expect(try index.resolve(.init(name: extensionName, language: .swift), source: .image, extensionsOnly: true) != nil)
        #expect(try index.resolve(.init(name: "(extension in \(module)):" + extensionName, language: .swift), source: .image) != nil)
        do {
            _ = try index.resolve(.init(name: "FooFoo.answer() -> Swift.Int", language: .swift), source: .image)
            Issue.record("Literal and compressed spellings at different addresses must remain ambiguous")
        } catch ABIResolutionError.ambiguousDeclaration(_, let candidates) { #expect(candidates.count == 2) }
    }

    @Test func laterLocalSymbolsRefreshPartialFallbackAndPreserveUnrelatedGroups() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let image = try #require(try await runtime.images(matching: .path(fixture.libraryURL)).first)
        let index = SymbolIndex(image: image)
        let address = UInt64(try fixture.address(kind: 0))
        let foo = NativeDeclaration(name: "FooFoo.echo() -> ()", language: .swift)
        let bar = NativeDeclaration(name: "BarBar.echo() -> ()", language: .swift)
        #expect(try index.resolve(foo, source: .sharedCache) == nil)
        let fooSymbol = IndexedSymbol(name: "_$s03FooA04echoyyF", address: address, source: .sharedCache)
        let barSymbol = IndexedSymbol(name: "_$s03BarA04echoyyF", address: address, source: .sharedCache)
        index.appendSharedCacheSymbols([fooSymbol], matching: SymbolQuery(.init(machOName: fooSymbol.name, language: .swift)))
        #expect(try index.resolve(foo, source: .sharedCache) != nil)
        #expect(try index.resolve(bar, source: .sharedCache) == nil)
        let first = SymbolQuery(.init(name: "First.echo() -> ()", language: .swift))
        index.appendSharedCacheSymbols([fooSymbol, barSymbol,
            .init(name: "_$s5First4echoyyF", address: address, source: .sharedCache)], matching: first)
        #expect(try index.resolve(bar, source: .sharedCache) != nil)
        let second = SymbolQuery(.init(name: "Second.echo() -> ()", language: .swift))
        index.appendSharedCacheSymbols([fooSymbol, barSymbol,
            .init(name: "_$s6Second4echoyyF", address: address, source: .sharedCache)], matching: second)
        #expect(try index.resolve(second, source: .sharedCache) != nil)
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        #expect(try index.resolve(foo, source: .sharedCache) != nil)
        #expect(try index.resolve(bar, source: .sharedCache) != nil)
    }

    @Test func moduleScopedLocalSymbolsDoNotMarkOtherDeclarationsLoaded() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let image = try #require(try await runtime.images(matching: .path(fixture.libraryURL)).first)
        let address = UInt64(try fixture.address(kind: 0))
        let index = SymbolIndex(image: image)
        let first = SymbolQuery(.init(name: "First.echo() -> ()", language: .swift))
        let second = SymbolQuery(.init(name: "Second.echo() -> ()", language: .swift))
        let exact = SymbolQuery(.init(machOName: "_$s5First4echoyyF", language: .swift))
        #expect(try index.resolve(first, source: .sharedCache) == nil)
        index.appendSharedCacheSymbols([.init(name: "_$s5First4echoyyF", address: address, source: .sharedCache)], matching: first)
        #expect(index.hasSharedCacheSymbols(for: first))
        #expect(!index.hasSharedCacheSymbols(for: second))
        #expect(!index.hasSharedCacheSymbols(for: exact))
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        #expect(try index.resolve(second, source: .sharedCache) == nil)
        index.appendSharedCacheSymbols([.init(name: "_$s6Second4echoyyF", address: address, source: .sharedCache)], matching: second)
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        #expect(try index.resolve(second, source: .sharedCache) != nil)
        let unfiltered = SymbolQuery(.init(name: "protocol conformance descriptor for First.Value : Swift.Equatable in First", language: .swift, kind: .data))
        index.appendSharedCacheSymbols([], matching: unfiltered)
        #expect(index.hasSharedCacheSymbols(for: exact))
        #expect(try index.resolve(exact, source: .sharedCache) != nil)
    }
}
#endif
