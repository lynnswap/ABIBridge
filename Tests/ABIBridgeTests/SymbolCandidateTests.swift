#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
import Testing

struct SymbolCandidateTests {
    @Test func protocolDescriptorCandidatesKeepModuleAndFallbackCoverage() {
        let query = SymbolQuery(.init(name: "protocol descriptor for First.Readable", language: .swift, kind: .data))
        func accepts(_ name: String) -> Bool { name.withCString(query.acceptsCandidate) }
        #expect(query.candidateScope == .swiftModule("First"))
        #expect(accepts("_$s5First8ReadableMp"))
        #expect(accepts("$S5First8ReadableMp"))
        #expect(!accepts("_$s6Second8ReadableMp"))
        #expect(accepts("_$s03FooA08ReadableMp"))
        #expect(accepts("_$sSQMp"))
        let conformance = SymbolQuery(.init(
            name: "protocol conformance descriptor for First.Value : Second.Readable in First", language: .swift, kind: .data))
        #expect(conformance.candidateScope == .language(.swift))
    }

    @Test func exactSharedCacheCoverageDoesNotHideOtherNamesOrKinds() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let image = try #require(try await runtime.images(matching: .path(fixture.libraryURL)).first)
        let index = SymbolIndex(image: image)
        let address = UInt64(try fixture.address(kind: 0))
        let first = SymbolQuery(.init(name: "ABIFirst", language: .c))
        let second = SymbolQuery(.init(machOName: "_ABISecond", language: .swift))
        #expect(try index.resolve(first, source: .sharedCache) == nil)
        index.appendSharedCacheSymbols([.init(name: "_ABIFirst", address: address, source: .sharedCache)], matching: first)
        #expect(index.hasSharedCacheSymbols(for: first))
        #expect(!index.hasSharedCacheSymbols(for: second))
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        index.appendSharedCacheSymbols([.init(name: "_ABISecond", address: address, source: .sharedCache)], matching: second)
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        #expect(try index.resolve(second, source: .sharedCache) != nil)
        let data = SymbolQuery(.init(name: "ABIFirst", language: .c, kind: .data))
        #expect(index.hasSharedCacheSymbols(for: data))
        #expect(throws: ABIResolutionError.invalidAddress) { try index.resolve(data, source: .sharedCache) }
    }

    @Test func cxxOwnerCoverageIncludesSiblingMethodsButNotOtherOwners() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let image = try #require(try await runtime.images(matching: .path(fixture.libraryURL)).first)
        let index = SymbolIndex(image: image)
        let address = UInt64(try fixture.address(kind: 0))
        let first = SymbolQuery(.init(name: "First::Counter::one()", language: .cxx))
        let sibling = SymbolQuery(.init(name: "First::Counter::two()", language: .cxx))
        let other = SymbolQuery(.init(name: "First::Different::one()", language: .cxx))
        index.appendSharedCacheSymbols([
            .init(name: "__ZN5First7Counter3oneEv", address: address, source: .sharedCache),
            .init(name: "__ZN5First7Counter3twoEv", address: address, source: .sharedCache)
        ], matching: first)
        #expect(index.hasSharedCacheSymbols(for: sibling))
        #expect(!index.hasSharedCacheSymbols(for: other))
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        #expect(try index.resolve(sibling, source: .sharedCache) != nil)
        #expect(try index.resolve(other, source: .sharedCache) == nil)
        index.appendSharedCacheSymbols([.init(name: "__ZN5First9Different3oneEv", address: address, source: .sharedCache)], matching: other)
        #expect(try index.resolve(other, source: .sharedCache) != nil)
        #expect(try index.resolve(sibling, source: .sharedCache) != nil)
        let complex = SymbolQuery(.init(name: "operator new(unsigned long)", language: .cxx))
        #expect(!index.hasSharedCacheSymbols(for: complex))
        index.appendSharedCacheSymbols([], matching: complex)
        #expect(index.hasSharedCacheSymbols(for: complex))
        #expect(index.hasSharedCacheSymbols(for: SymbolQuery(.init(name: "Another::Owner::value()", language: .cxx))))
    }

    @Test func rawCandidateMatchingKeepsByteIdentityAndExactNameForms() {
        func accepts(_ query: SymbolQuery, _ name: String) -> Bool { name.withCString(query.acceptsCandidate) }
        let exact = SymbolQuery(.init(machOName: "_café", language: .cxx))
        #expect(accepts(exact, "_café"))
        #expect(!accepts(exact, "_cafe\u{301}"))
        #expect(!accepts(SymbolQuery(.init(machOName: "_name\0suffix", language: .c)), "_name"))
        let owner = SymbolQuery(.init(name: "First::Counter::one()", language: .cxx))
        #expect(accepts(owner, "__ZN5First7Counter3twoEv"))
        #expect(!accepts(owner, "_Counter"))
        #expect(!accepts(owner, "_$s7Counter4echoyyF"))
        let complex = SymbolQuery(.init(name: "First::Box<int>::value()", language: .cxx))
        #expect(accepts(complex, "__ZN5First3BoxIiE5valueEv"))
    }
}
#endif
