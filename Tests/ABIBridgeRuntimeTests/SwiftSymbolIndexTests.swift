import ABIBridgeTestSupport
#if os(macOS) && DEBUG
@testable import ABIBridgeRuntime
import Foundation
import MachO
import MachOKit
import Testing

struct SwiftSymbolIndexTests {
    @Test func memberPathsKeepParameterLabelsAndUnicodeAccessorNames() throws {
        let declarations = [
            (
                "First.choose(Swift.Int, transform: (Swift.Int) -> Swift.String) -> (Swift.Int, (Swift.Int) -> Swift.String)",
                "First", "choose(_:transform:)", nil as RuntimeSwiftDeclaration.Accessor?
            ),
            (
                "First.(unknown context at $1).Box<A where A == (Swift.Int) -> Swift.String>.apply(A) -> (Swift.Int) -> Swift.String",
                "First.(unknown context at $1).Box", "apply(_:)", nil
            ),
            (
                "(extension in Second):First.値.cafe\u{301}.getter : (Swift.Int) -> Swift.String",
                "First.値", "cafe\u{301}", .getter
            ),
        ]
        for (declaration, owner, member, accessor) in declarations {
            let match = try #require(SwiftMemberMatch(declaration: declaration))
            #expect(match.path == SwiftMemberPath(owner: owner, member: member))
            #expect(match.accessor == accessor)
        }
        // The demangler spells a class's allocating initializer apart from
        // its initializing entry; records tell them apart.
        let allocator = try #require(
            SwiftMemberMatch(
                declaration: "First.Box.__allocating_init(value: Swift.Int) -> First.Box"
            )
        )
        #expect(allocator.path == SwiftMemberPath(owner: "First.Box", member: "init(value:)"))
        #expect(allocator.initializer == .classAllocator(true))
    }

    @Test func abbreviatedModuleRootsPreserveQueryOrder() async throws {
        let fixture = try FixtureLibrary(
            cxxSource: """
                extern "C" void swiftModule() asm("_$ss5probeyyF");
                void swiftModule() {}
                extern "C" void swiftType() asm("_$sSi5probeyyF");
                void swiftType() {}
                extern "C" void objcModule() asm("_$sSo7FixtureC5probeyyF");
                void objcModule() {}
                extern "C" void clangModule() asm("_$sSC7FixtureV5probeyyF");
                void clangModule() {}
                extern "C" void compressed() asm("_$s03FooA04echoyyF");
                void compressed() {}
                """
        )
        defer { fixture.cleanup() }
        let image = try #require(
            try await RuntimeSymbolResolver().images(matching: .path(fixture.libraryURL)).first
        )
        let names = [
            "Swift.probe() -> ()", "Swift.Int.probe() -> ()", "__C.Fixture.probe() -> ()",
            "__C_Synthesized.Fixture.probe() -> ()", "FooFoo.echo() -> ()",
        ]
        for order in [names, Array(names.reversed())] {
            let index = SymbolIndex(image: image)
            #expect(
                try index.resolve(
                    .init(name: "Absent.missing() -> ()", language: .swift),
                    source: .image
                ) == nil
            )
            for name in order {
                #expect(
                    try index.resolve(.init(name: name, language: .swift), source: .image) != nil,
                    "\(name)"
                )
            }
        }
    }

    @Test func knownAbbreviationsKeepSharedCacheCoverageSeparate() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let image = try #require(
            try await RuntimeSymbolResolver().images(matching: .path(fixture.libraryURL)).first
        )
        let address = UInt64(try fixture.address(kind: 0))
        let index = SymbolIndex(image: image)
        let foo = SymbolQuery(.init(name: "FooFoo.echo() -> ()", language: .swift))
        let swift = SymbolQuery(.init(name: "Swift.Int.probe() -> ()", language: .swift))
        let compressed = IndexedSymbol(
            name: "_$s03FooA04echoyyF",
            address: address,
            source: .sharedCache
        )
        let standard = IndexedSymbol(name: "_$sSi5probeyyF", address: address, source: .sharedCache)
        index.appendSharedCacheSymbols([compressed], matching: foo)
        #expect(try index.resolve(foo, source: .sharedCache) != nil)
        #expect(!index.hasSharedCacheSymbols(for: swift))
        #expect(try index.resolve(swift, source: .sharedCache) == nil)
        index.appendSharedCacheSymbols([standard], matching: swift)
        #expect(try index.resolve(swift, source: .sharedCache) != nil)
        #expect(try index.resolve(foo, source: .sharedCache) != nil)
        #expect(
            try index.resolve(
                .init(machOName: standard.name, language: .swift),
                source: .sharedCache
            ) != nil
        )
    }

    @Test func nominalDescriptorsKeepOtherDescriptorAndFunctionLookups() async throws {
        let fixture = try FixtureLibrary(
            cxxSource: """
                extern "C" int value asm("_$s5First5ValueVMn") = 1;
                extern "C" int other asm("_$s6Second5ValueVMn") = 2;
                extern "C" int readable asm("_$s5First8ReadableMp") = 3;
                extern "C" void echo() asm("_$s5First4echoyyF");
                void echo() {}
                """
        )
        defer { fixture.cleanup() }
        let image = try #require(
            try await RuntimeSymbolResolver().images(matching: .path(fixture.libraryURL)).first
        )
        let index = SymbolIndex(image: image)
        let nominal = RuntimeDeclaration(
            name: "nominal type descriptor for First.Value",
            language: .swift,
            kind: .data
        )
        let other = RuntimeDeclaration(
            name: "nominal type descriptor for Second.Value",
            language: .swift,
            kind: .data
        )
        let proto = RuntimeDeclaration(
            name: "protocol descriptor for First.Readable",
            language: .swift,
            kind: .data
        )
        let function = RuntimeDeclaration(name: "First.echo() -> ()", language: .swift)
        for declaration in [nominal, proto, function, other, nominal, function] {
            #expect(try index.resolve(declaration, source: .image) != nil)
        }
        let resolved = try #require(try index.resolve(nominal, source: .image))
        #expect(
            try index.swiftNominalTypeName(
                at: resolved.address,
                matching: SymbolQuery(nominal),
                source: .image
            ) == "First.Value"
        )
    }

    @Test func protocolDescriptorsPreserveCompressedNamesAmbiguityAndOtherLookups() async throws {
        let fixture = try FixtureLibrary(
            cxxSource: """
                extern "C" int first asm("_$s5First8ReadableMp") = 1;
                extern "C" int second asm("_$s6Second8ReadableMp") = 2;
                extern "C" int compressed asm("_$s03FooA08ReadableMp") = 3;
                extern "C" int literal asm("_$s6FooFoo8ReadableMp") = 4;
                extern "C" void echo() asm("_$s5First4echoyyF");
                void echo() {}
                """
        )
        defer { fixture.cleanup() }
        let runtime = RuntimeSymbolResolver()
        let image = try #require(
            try await runtime.images(matching: .path(fixture.libraryURL)).first
        )
        let index = SymbolIndex(image: image)
        let first = RuntimeDeclaration(
            name: "protocol descriptor for First.Readable",
            language: .swift,
            kind: .data
        )
        let second = RuntimeDeclaration(
            name: "protocol descriptor for Second.Readable",
            language: .swift,
            kind: .data
        )
        let function = RuntimeDeclaration(name: "First.echo() -> ()", language: .swift)
        for declaration in [first, function, second, first, function] {
            let symbol = try #require(try index.resolve(declaration, source: .image))
            #expect(symbol.image.identity == image.identity)
        }
        do {
            _ = try index.resolve(
                .init(
                    name: "protocol descriptor for FooFoo.Readable",
                    language: .swift,
                    kind: .data
                ),
                source: .image
            )
            Issue.record(
                "Literal and compressed protocol descriptors at different addresses must remain ambiguous"
            )
        } catch RuntimeResolutionError.ambiguousDeclaration(_, let candidates) {
            #expect(candidates.count == 2)
        }
    }

    @Test func protocolDescriptorQueriesPruneUnrelatedLiteralModules() throws {
        let query = SymbolQuery(
            .init(name: "  protocol descriptor for SwiftUI.View\n", language: .swift, kind: .data)
        )
        let filter = try #require(query.swiftModule)
        #expect(query.candidateScope == .swiftModule("SwiftUI"))
        #expect("_$s7SwiftUI4ViewMp".withCString(query.acceptsCandidate))
        #expect(!"_$s7Combine9PublisherMp".withCString(query.acceptsCandidate))
        #expect(filter.matches("_$s7SwiftUI", partial: true))
        #expect(!filter.matches("_$s7Combine", partial: true))
        #expect(!"_$sSQMp".withCString(query.acceptsCandidate))
        #expect(filter.matches("_$sS", partial: true))
        #expect("_$s03FooA05ValueMp".withCString(query.acceptsCandidate))
    }

    @Test(arguments: ["Mp", "VMn"])
    func descriptorsKeepCompressedFallbackAndAmbiguity(_ suffix: String) async throws {
        let fixture = try FixtureLibrary(
            cxxSource: """
                #include <cstdint>
                extern "C" {
                int descriptors[2] = {1, 2};
                uintptr_t ABIFixtureAddress(int kind) { return reinterpret_cast<uintptr_t>(&descriptors[kind]); }
                }
                """
        )
        defer { fixture.cleanup() }
        let image = try #require(
            try await RuntimeSymbolResolver().images(matching: .path(fixture.libraryURL)).first
        )
        let marker = suffix == "Mp" ? "protocol descriptor for " : "nominal type descriptor for "
        let query = SymbolQuery(.init(name: marker + "FooFoo.Value", language: .swift, kind: .data))
        let compressed = IndexedSymbol(
            name: "_$s03FooA05Value" + suffix,
            address: UInt64(try fixture.address(kind: 0)),
            source: .sharedCache
        )
        let literal = IndexedSymbol(
            name: "_$s6FooFoo5Value" + suffix,
            address: UInt64(try fixture.address(kind: 1)),
            source: .sharedCache
        )
        for symbol in [compressed, literal] {
            let index = SymbolIndex(image: image)
            index.appendSharedCacheSymbols([symbol], matching: query)
            let resolved = try #require(try index.resolve(query, source: .sharedCache))
            #expect(resolved.linkageName == symbol.name)
        }
        let index = SymbolIndex(image: image)
        index.appendSharedCacheSymbols([compressed], matching: query)
        #expect(try index.resolve(query, source: .sharedCache)?.linkageName == compressed.name)
        index.appendSharedCacheSymbols([literal], matching: query)
        do {
            _ = try index.resolve(query, source: .sharedCache)
            Issue.record(
                "Literal and compressed protocol descriptors at different addresses must remain ambiguous"
            )
        } catch RuntimeResolutionError.ambiguousDeclaration(_, let candidates) {
            #expect(candidates.count == 2)
        }
    }

    @Test func mappedLocalNamesRespectRangesAndTableBounds() throws {
        let names = Array("_plain\0_$s5First4echoyyF\0unterminated".utf8)
        var data = Data(repeating: 0, count: 7)
        for (offset, address) in [
            (UInt32(0), UInt64(0x1000)), (7, 0x2000), (.max, 0x3000), (27, 0x4000),
        ] {
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
        let table = try #require(
            SharedCacheSymbols.MappedSymbols(data: data, localSymbolsOffset: 7, layout: layout)
        )
        data.removeAll()
        var actual: [(String, UInt64)] = []
        table.forEach(in: 0..<4) { actual.append((String(cString: $0), $1)) }
        #expect(actual.map(\.0) == ["_plain", "_$s5First4echoyyF"])
        #expect(actual.map(\.1) == [0x1000, 0x2000])
        actual.removeAll()
        table.forEach(in: 1..<4) { actual.append((String(cString: $0), $1)) }
        #expect(actual.map(\.0) == ["_$s5First4echoyyF"])
        #expect(
            SharedCacheSymbols.MappedSymbols(
                data: Data(repeating: 0, count: 8),
                localSymbolsOffset: 7,
                layout: layout
            ) == nil
        )
        #expect(
            SharedCacheSymbols.MappedSymbols(data: Data(), localSymbolsOffset: .max, layout: layout)
                == nil
        )
    }

    @Test func sharedFallbackHandlesDifferentModulesExtensionsAndAmbiguity() async throws {
        let module = "FallbackFixture"
        let fixture = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                @_silgen_name("$s03FooA04echoyyF") public func first() {}
                @_silgen_name("$s03BarA04echoyyF") public func second() {}
                @_silgen_name("$s03FooA06answerSiyF") public func compressed() -> Int { 1 }
                @_silgen_name("$s6FooFoo6answerSiyF") public func literal() -> Int { 2 }
                public func ordinary() {}
                extension Int { public func _abiFallbackOrderFixture() -> Int { self } }
                """
        )
        defer { fixture.cleanup() }
        let runtime = RuntimeSymbolResolver()
        let image = try #require(
            try await runtime.images(matching: .path(fixture.libraryURL)).first
        )
        let index = SymbolIndex(image: image)
        for name in [
            "FooFoo.echo() -> ()", "BarBar.echo() -> ()", module + ".ordinary() -> ()",
            "FooFoo.echo() -> ()",
        ] {
            #expect(try index.resolve(.init(name: name, language: .swift), source: .image) != nil)
        }
        let extensionName = "Swift.Int._abiFallbackOrderFixture() -> Swift.Int"
        #expect(
            index.swiftDeclarationCandidates(
                SymbolQuery(.init(name: extensionName, language: .swift)),
                source: .image,
                extensionsOnly: true
            ).count == 1
        )
        #expect(
            try index.resolve(
                .init(name: "(extension in \(module)):" + extensionName, language: .swift),
                source: .image
            ) != nil
        )
        do {
            _ = try index.resolve(
                .init(name: "FooFoo.answer() -> Swift.Int", language: .swift),
                source: .image
            )
            Issue.record(
                "Literal and compressed spellings at different addresses must remain ambiguous"
            )
        } catch RuntimeResolutionError.ambiguousDeclaration(_, let candidates) {
            #expect(candidates.count == 2)
        }
    }

    // Standard protocols are mangled with substitutions such as SQ for
    // Equatable, so their method descriptors do not share a spelled prefix
    // with the protocol descriptor.
    @Test func methodDescriptorsNameStandardLibraryRequirements() throws {
        let resolver = RuntimeSymbolResolver()
        for (protocolName, expected) in [
            ("Swift.Equatable", "$sSQ2eeoiySbx_xtFZ"),
            ("Swift.Hashable", "$sSH4hash4intoys6HasherVz_tF"),
        ] {
            let descriptor = try resolver.resolve(
                RuntimeDeclaration(
                    name: "protocol descriptor for " + protocolName,
                    language: .swift,
                    kind: .data
                ),
                loading: .loadedOnly
            )
            let layout = RuntimeProtocolLayout(
                try #require(UnsafeRawPointer(bitPattern: UInt(descriptor.address)))
            )
            var names: Set<String> = []
            for requirement in layout.witnessRequirements where requirement.isCode {
                let requirements = resolver.swiftMethodDescriptorRequirements(
                    at: UInt64(UInt(bitPattern: requirement.address)),
                    in: descriptor.image
                )
                #expect(requirements.count == 1)
                names.formUnion(requirements)
            }
            #expect(names.contains(expected))
        }
    }

    @Test func dispatchThunksBringMemberCodeFromSharedCacheLocals() async throws {
        let module = "ThunkFixture"
        // Library evolution exports an open member's dispatch thunk; stripping
        // removes the member's own local symbol, as in shared-cache images.
        let fixture = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                open class Counter {
                    public init() {}
                    open func value() -> Int { 1 }
                }
                """,
            stripped: true,
            linkArguments: ["-parse-as-library", "-enable-library-evolution"]
        )
        defer { fixture.cleanup() }
        let request = RuntimeDeclaration(
            name: module + ".Counter.value() -> Swift.Int",
            language: .swift
        )
        let image = try #require(
            try await RuntimeSymbolResolver().images(matching: .path(fixture.libraryURL)).first
        )
        let thunk = try #require(
            try RuntimeSymbolResolver().swiftDeclarationCandidates(request, in: image).first
        )
        #expect(thunk.record.role == .dispatchThunk)
        // value() -> Swift.String: an overload that only local symbols describe.
        let identity = thunk.record.identity
        #expect(identity.hasSuffix("SiyF"))
        let overload = String(identity.dropLast(4)) + "SSyF"
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, _, source in
            guard source == .loaded else { return nil }
            return SharedCacheSymbols.CapturedSymbols(
                slide: 0,
                readers: [
                    { record in
                        // Candidates at one address are one definition.
                        for (offset, name) in [identity, overload].enumerated() {
                            ("_" + name).withCString {
                                record($0, thunk.symbol.address + UInt64(offset * 4))
                            }
                        }
                    }
                ],
                imageIdentity: image.identity
            )
        })
        let candidates = try resolver.swiftDeclarationCandidates(request, in: image)
        #expect(candidates.map(\.record.role) == [.dispatchThunk, .implementation, .implementation])
        #expect(candidates.map(\.symbol.source) == [.image, .sharedCache, .sharedCache])
        #expect(Set(candidates.map(\.record.identity)) == [identity, overload])
    }

    @Test func laterLocalSymbolsRefreshPartialFallbackAndPreserveUnrelatedGroups() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = RuntimeSymbolResolver()
        let image = try #require(
            try await runtime.images(matching: .path(fixture.libraryURL)).first
        )
        let index = SymbolIndex(image: image)
        let address = UInt64(try fixture.address(kind: 0))
        let foo = RuntimeDeclaration(name: "FooFoo.echo() -> ()", language: .swift)
        let bar = RuntimeDeclaration(name: "BarBar.echo() -> ()", language: .swift)
        #expect(try index.resolve(foo, source: .sharedCache) == nil)
        let fooSymbol = IndexedSymbol(
            name: "_$s03FooA04echoyyF",
            address: address,
            source: .sharedCache
        )
        let barSymbol = IndexedSymbol(
            name: "_$s03BarA04echoyyF",
            address: address,
            source: .sharedCache
        )
        index.appendSharedCacheSymbols(
            [fooSymbol],
            matching: SymbolQuery(.init(machOName: fooSymbol.name, language: .swift))
        )
        #expect(try index.resolve(foo, source: .sharedCache) != nil)
        #expect(try index.resolve(bar, source: .sharedCache) == nil)
        let first = SymbolQuery(.init(name: "First.echo() -> ()", language: .swift))
        index.appendSharedCacheSymbols(
            [
                fooSymbol, barSymbol,
                .init(name: "_$s5First4echoyyF", address: address, source: .sharedCache),
            ],
            matching: first
        )
        #expect(try index.resolve(bar, source: .sharedCache) != nil)
        let second = SymbolQuery(.init(name: "Second.echo() -> ()", language: .swift))
        index.appendSharedCacheSymbols(
            [
                fooSymbol, barSymbol,
                .init(name: "_$s6Second4echoyyF", address: address, source: .sharedCache),
            ],
            matching: second
        )
        #expect(try index.resolve(second, source: .sharedCache) != nil)
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        #expect(try index.resolve(foo, source: .sharedCache) != nil)
        #expect(try index.resolve(bar, source: .sharedCache) != nil)
    }

    @Test func moduleScopedLocalSymbolsDoNotMarkOtherDeclarationsLoaded() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = RuntimeSymbolResolver()
        let image = try #require(
            try await runtime.images(matching: .path(fixture.libraryURL)).first
        )
        let address = UInt64(try fixture.address(kind: 0))
        let index = SymbolIndex(image: image)
        let first = SymbolQuery(.init(name: "First.echo() -> ()", language: .swift))
        let second = SymbolQuery(.init(name: "Second.echo() -> ()", language: .swift))
        let exact = SymbolQuery(.init(machOName: "_$s5First4echoyyF", language: .swift))
        #expect(try index.resolve(first, source: .sharedCache) == nil)
        index.appendSharedCacheSymbols(
            [.init(name: "_$s5First4echoyyF", address: address, source: .sharedCache)],
            matching: first
        )
        #expect(index.hasSharedCacheSymbols(for: first))
        #expect(!index.hasSharedCacheSymbols(for: second))
        #expect(!index.hasSharedCacheSymbols(for: exact))
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        #expect(try index.resolve(second, source: .sharedCache) == nil)
        index.appendSharedCacheSymbols(
            [.init(name: "_$s6Second4echoyyF", address: address, source: .sharedCache)],
            matching: second
        )
        #expect(try index.resolve(first, source: .sharedCache) != nil)
        #expect(try index.resolve(second, source: .sharedCache) != nil)
        let unfiltered = SymbolQuery(
            .init(
                name: "protocol conformance descriptor for First.Value : Swift.Equatable in First",
                language: .swift,
                kind: .data
            )
        )
        index.appendSharedCacheSymbols([], matching: unfiltered)
        #expect(index.hasSharedCacheSymbols(for: exact))
        #expect(try index.resolve(exact, source: .sharedCache) != nil)
    }
}
#endif
