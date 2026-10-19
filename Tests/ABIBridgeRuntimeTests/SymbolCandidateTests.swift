import ABIBridgeTestSupport
#if os(macOS) && DEBUG
@testable import ABIBridgeRuntime
import Foundation
import Testing

struct SymbolCandidateTests {
    @Test func combinedExtractionPreservesIndependentRawCandidateMatching() {
        let groups: [[RuntimeDeclaration]] = [
            [
                .init(machOName: "_café", language: .c),
                .init(machOName: "_name\0suffix", language: .c),
                .init(name: "First::Counter::one()", language: .cxx),
                .init(name: "First.echo()", language: .swift),
            ],
            [
                .init(name: "First::Box<int>::value()", language: .cxx),
                .init(machOName: "_ordinary", language: .swift),
            ],
            [
                .init(name: "Swift.Array.value()", language: .swift),
                .init(machOName: "", language: .cxx),
            ],
        ]
        let names = [
            "", "_", "__", "_$", "$S", "_ordinary", "_name", "_café", "_cafe\u{301}",
            "__ZN5First7Counter3oneEv", "_ZN5First7Counter3twoEv", "_ZN5First9Different3oneEv",
            "_ZN5First3BoxIiE5valueEv", "__ZTIi", "_Z", "__$s5First4echoyyF",
            "_$s5First4echoyyF", "$S5First4echoyyF", "_$s6Second4echoyyF",
            "_$s03FooA04echoyyF", "_$sSQMp", "_$sSo8NSObjectCMn",
        ]
        let sources = SharedCacheSymbols.CapturedSymbols(
            slide: 0,
            readers: [
                { record in
                    for name in names { name.withCString { record($0, 1) } }
                }
            ]
        )
        for declarations in groups {
            let queries = declarations.map(SymbolQuery.init)
            for includeFallback in [false, true] {
                let expected = names.filter { name in
                    name.withCString { raw in
                        queries.contains { $0.acceptsCandidate(raw) }
                            && (includeFallback
                                || SwiftModuleFilter.knownModulePrefix(raw) != false)
                    }
                }.map { Array($0.utf8) }
                let result = sources.extract(
                    matching: queries[0],
                    includingSwiftFallback: includeFallback,
                    relatedQueries: Array(queries.dropFirst())
                )
                #expect(result.symbols.map { Array($0.name.utf8) } == expected)
            }
        }
    }

    @Test func decoratedSwiftDeclarationsKeepOwnerModuleCoverage() {
        for declaration in [
            "async function pointer to static (extension in Second):First.Value.member() async -> ()",
            "method descriptor for First.Value.member() -> ()",
            "(extension in Second):First.Value.member() -> ()",
        ] {
            let query = SymbolQuery(.init(name: declaration, language: .swift, kind: .data))
            func accepts(_ name: String) -> Bool { name.withCString(query.acceptsCandidate) }
            #expect(query.candidateScope == .swiftModule("First"), "\(declaration)")
            #expect(accepts("_$s5First5ValueV6SecondE6memberyyF"))
            #expect(!accepts("_$s6Second5ValueV6memberyyF"))
            #expect(accepts("_$s03FooA05ValueV6memberyyF"))
        }
        let property = SymbolQuery(
            .init(
                name:
                    "property descriptor for (extension in Second):Swift.String.member : Swift.Int",
                language: .swift,
                kind: .data
            )
        )
        #expect(property.candidateScope == .swiftModule("Swift"))
        #expect("_$sSS6SecondE6memberSivpMV".withCString(property.acceptsCandidate))
        #expect(!"_$s6Second5ValueV6memberSivpMV".withCString(property.acceptsCandidate))
    }

    @Test func protocolDescriptorCandidatesKeepModuleAndFallbackCoverage() {
        let query = SymbolQuery(
            .init(name: "protocol descriptor for First.Readable", language: .swift, kind: .data)
        )
        func accepts(_ name: String) -> Bool { name.withCString(query.acceptsCandidate) }
        #expect(query.candidateScope == .swiftModule("First"))
        #expect(accepts("_$s5First8ReadableMp"))
        #expect(accepts("$S5First8ReadableMp"))
        #expect(!accepts("_$s6Second8ReadableMp"))
        #expect(accepts("_$s03FooA08ReadableMp"))
        #expect(!accepts("_$sSQMp"))
        let conformance = SymbolQuery(
            .init(
                name: "protocol conformance descriptor for First.Value : Second.Readable in First",
                language: .swift,
                kind: .data
            )
        )
        #expect(conformance.candidateScope == .language(.swift))
    }

    @Test func exactSharedCacheCoverageDoesNotHideOtherNamesOrKinds() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = RuntimeSymbolResolver()
        let image = try #require(
            try await runtime.images(matching: .path(fixture.libraryURL)).first
        )
        let index = SymbolIndex(image: image)
        let address = UInt64(try fixture.address(kind: 0))
        let first = SymbolQuery(.init(name: "ABIFirst", language: .c))
        let second = SymbolQuery(.init(machOName: "_ABISecond", language: .swift))
        #expect(try index.resolve(first, source: .sharedCache) == nil)
        index.appendSharedCacheSymbols(
            [.init(name: "_ABIFirst", address: address, source: .sharedCache)],
            matching: first
        )
        #expect(index.hasSharedCacheSymbols(for: first))
        #expect(!index.hasSharedCacheSymbols(for: second))
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        index.appendSharedCacheSymbols(
            [.init(name: "_ABISecond", address: address, source: .sharedCache)],
            matching: second
        )
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        #expect(try index.resolve(second, source: .sharedCache) != nil)
        let data = SymbolQuery(.init(name: "ABIFirst", language: .c, kind: .data))
        #expect(index.hasSharedCacheSymbols(for: data))
        #expect(throws: RuntimeResolutionError.invalidAddress) {
            try index.resolve(data, source: .sharedCache)
        }
    }

    @Test func cxxOwnerCoverageIncludesSiblingMethodsButNotOtherOwners() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = RuntimeSymbolResolver()
        let image = try #require(
            try await runtime.images(matching: .path(fixture.libraryURL)).first
        )
        let index = SymbolIndex(image: image)
        let address = UInt64(try fixture.address(kind: 0))
        let first = SymbolQuery(.init(name: "First::Counter::one()", language: .cxx))
        let sibling = SymbolQuery(.init(name: "First::Counter::two()", language: .cxx))
        let other = SymbolQuery(.init(name: "First::Different::one()", language: .cxx))
        index.appendSharedCacheSymbols(
            [
                .init(name: "__ZN5First7Counter3oneEv", address: address, source: .sharedCache),
                .init(name: "__ZN5First7Counter3twoEv", address: address, source: .sharedCache),
            ],
            matching: first
        )
        #expect(index.hasSharedCacheSymbols(for: sibling))
        #expect(!index.hasSharedCacheSymbols(for: other))
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        #expect(try index.resolve(sibling, source: .sharedCache) != nil)
        #expect(try index.resolve(other, source: .sharedCache) == nil)
        index.appendSharedCacheSymbols(
            [.init(name: "__ZN5First9Different3oneEv", address: address, source: .sharedCache)],
            matching: other
        )
        #expect(try index.resolve(other, source: .sharedCache) != nil)
        #expect(try index.resolve(sibling, source: .sharedCache) != nil)
        let complex = SymbolQuery(.init(name: "operator new(unsigned long)", language: .cxx))
        #expect(!index.hasSharedCacheSymbols(for: complex))
        index.appendSharedCacheSymbols([], matching: complex)
        #expect(index.hasSharedCacheSymbols(for: complex))
        #expect(
            index.hasSharedCacheSymbols(
                for: SymbolQuery(.init(name: "Another::Owner::value()", language: .cxx))
            )
        )
    }

    @Test func rawCandidateMatchingKeepsByteIdentityAndExactNameForms() {
        func accepts(_ query: SymbolQuery, _ name: String) -> Bool {
            name.withCString(query.acceptsCandidate)
        }
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
