#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
import MachO
import MachOKit
import Testing

struct SwiftSymbolIndexTests {
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
        index.appendSharedCacheSymbols([])
        #expect(index.hasSharedCacheSymbols(for: exact))
        #expect(try index.resolve(exact, source: .sharedCache) != nil)
    }
}
#endif
