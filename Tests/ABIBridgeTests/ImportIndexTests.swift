#if os(macOS) && DEBUG
@testable import ABIBridge
import Darwin
import Foundation
import MachOKit
import Testing

@Suite(.serialized)
struct ImportIndexTests {
    @Test func preservesFormatDefinedOrdinalAndAddendBoundaries() {
        for (raw, expected) in [(127, 127), (128, 128), (240, 240), (241, -15), (253, -3), (254, -2), (255, -1)] {
            var plain = DyldChainedImportGeneral.Layout()
            plain.lib_ordinal = UInt32(raw)
            #expect(ImportMetadata.chainedImport(.general(.init(layout: plain))).ordinal == expected)
            var withAddend = DyldChainedImportAddend.Layout()
            withAddend.lib_ordinal = UInt32(raw)
            withAddend.addend = -123
            let parsed = ImportMetadata.chainedImport(.addend(.init(layout: withAddend)))
            #expect(parsed.ordinal == expected && parsed.addend == -123)
        }
        for (raw, expected) in [(32767, 32767), (32768, 32768), (65520, 65520), (65521, -15), (65533, -3), (65534, -2), (65535, -1)] {
            var wide = DyldChainedImportAddend64.Layout()
            wide.lib_ordinal = UInt64(raw)
            wide.addend = UInt64(bitPattern: Int64.min)
            let parsed = ImportMetadata.chainedImport(.addend64(.init(layout: wide)))
            #expect(parsed.ordinal == expected && parsed.addend == Int64.min)
        }
    }

    @Test(arguments: [false, true])
    func preservesNamesProvidersWeakImportsAndAddends(chained: Bool) throws {
        let namespace = "Import_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let provider = try FixtureLibrary(namespace: namespace, cxxSource: """
        namespace \(namespace) {
            int add(int a, int b) { return a + b; }
            struct Counter { int next(int); };
            int Counter::next(int value) { return value + 1; }
        }
        extern "C" { char ABIImportBuffer[8] = {}; }
        """)
        defer { provider.cleanup() }
        let consumer = try FixtureLibrary(cxxSource: """
        #include <unistd.h>
        namespace \(namespace) {
            int add(int, int);
            struct Counter { int next(int); };
        }
        extern "C" int ABIImportAbsent(void) __attribute__((weak_import));
        extern "C" char ABIImportBuffer[8];
        extern "C" { char *ABIImportOffset = ABIImportBuffer + 3; }
        extern "C" int ABIImportInvoke(void) {
            \(namespace)::Counter counter;
            return \(namespace)::add(20, 21) + counter.next(0) + (getpid() > 0 ? 0 : 1);
        }
        extern "C" int ABIImportWeak(void) { return ABIImportAbsent ? ABIImportAbsent() : -1; }
        """, linkArguments: [provider.libraryURL.path, "-undefined", "dynamic_lookup", "-Wl," + (chained ? "-fixup_chains" : "-no_fixup_chains")])
        defer { consumer.cleanup() }
        let resolver = SymbolResolver()
        let image = try #require(resolver.images(matching: .path(consumer.libraryURL)).first)
        let index = try resolver.importIndex(for: image)
        #expect(index === (try resolver.importIndex(for: image)))
        let declaration = NativeDeclaration(name: "\(namespace)::add(int, int)", language: .cxx)
        let add = try #require(index.matches(declaration).only)
        #expect(add.libraryName == provider.libraryURL.path)
        #expect(add.libraryOrdinal > 0 && !add.weak && add.addend == 0)
        #expect(add.authentication == .unsigned && add.width == MemoryLayout<UnsafeRawPointer>.size)
        #expect(add.source == (chained ? .chained : .opcodes))
        #expect(try index.matches(declaration, libraryOrdinal: add.libraryOrdinal + 1).isEmpty)
        let originalBits = try #require(UnsafePointer<UInt>(bitPattern: UInt(add.address))).pointee
        let next = try #require(index.matches(.init(name: "\(namespace)::Counter::next(int)", language: .cxx)).only)
        #expect(next.libraryOrdinal == add.libraryOrdinal)
        let weak = try index.matches(.init(name: "ABIImportAbsent", language: .c))
        #expect(!weak.isEmpty && weak.allSatisfy(\.weak))
        #expect(Set(weak.map(\.address)).count == weak.count)
        // The address test and actual call can use separate non-lazy/lazy slots.
        // A lazy slot may still contain dyld's helper, even after RTLD_NOW.
        for reference in weak where !reference.isLazyBinding {
            #expect(try #require(UnsafePointer<UInt>(bitPattern: UInt(reference.address))).pointee == 0)
        }
        let buffer = try #require(index.matches(.init(name: "ABIImportBuffer", language: .c, kind: .data)).only)
        #expect(buffer.addend == 3)
        #expect(try index.matches(.init(machOName: add.symbol, language: .cxx)).only?.address == add.address)
        #expect(try index.matches(.init(name: "getpid", language: .c)).count == 1)
        #expect(try index.matches(.init(name: "missing", language: .c)).isEmpty)
        #expect(try #require(UnsafePointer<UInt>(bitPattern: UInt(add.address))).pointee == originalBits)
        let invoke = try resolver.resolve(.init(name: "ABIImportInvoke", language: .c), in: image, loading: .loadedOnly)
        let actual = unsafe invoke.withUnsafeAddress { unsafeBitCast($0, to: (@convention(c) () -> Int32).self)() }
        #expect(actual == 42)
    }

    @Test func sameNamesKeepTheirImportingAndDeclaredProviderIdentities() throws {
        let first = try FixtureLibrary(cxxSource: "extern \"C\" int ABIImportSame() { return 1; }")
        let second = try FixtureLibrary(cxxSource: "extern \"C\" int ABIImportSame() { return 2; }")
        defer { first.cleanup(); second.cleanup() }
        let source = "extern \"C\" int ABIImportSame(); extern \"C\" int ABIImportCall() { return ABIImportSame(); }"
        let a = try FixtureLibrary(cxxSource: source, linkArguments: [first.libraryURL.path])
        let b = try FixtureLibrary(cxxSource: source, linkArguments: [second.libraryURL.path])
        defer { a.cleanup(); b.cleanup() }
        let resolver = SymbolResolver()
        let imageA = try #require(resolver.images(matching: .path(a.libraryURL)).first)
        let imageB = try #require(resolver.images(matching: .path(b.libraryURL)).first)
        let query = NativeDeclaration(name: "ABIImportSame", language: .c)
        let importA = try #require(resolver.importIndex(for: imageA).matches(query).only)
        let importB = try #require(resolver.importIndex(for: imageB).matches(query).only)
        #expect(importA.image.identity != importB.image.identity)
        #expect(importA.libraryName == first.libraryURL.path)
        #expect(importB.libraryName == second.libraryURL.path)
        #expect(importA.address != importB.address)
    }

    @Test func matchesSwiftSourceDeclarationsWithoutSupplyingMangledNames() throws {
        let module = "ImportSwift_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let provider = try FixtureLibrary(swiftModule: module, swiftSource: "public func twice(_ value: Int) -> Int { value * 2 }")
        defer { provider.cleanup() }
        let symbol = try #require(provider.exportedSymbols().first { $0.hasPrefix("_$s") })
        // The fixture uses the compiler's own symbol and Swift calling convention;
        // the query below still uses the source declaration rather than that name.
        let consumer = try FixtureLibrary(cxxSource: """
        #include <stdint.h>
        extern "C" __attribute__((swiftcall)) intptr_t twice(intptr_t) asm("\(symbol)");
        extern "C" intptr_t ABIImportSwiftCall(intptr_t value) { return twice(value); }
        """, linkArguments: [provider.libraryURL.path])
        defer { consumer.cleanup() }
        let resolver = SymbolResolver()
        let image = try #require(resolver.images(matching: .path(consumer.libraryURL)).first)
        let index = try resolver.importIndex(for: image)
        let entry = try #require(index.matches(.init(name: "\(module).twice(Swift.Int) -> Swift.Int", language: .swift)).only)
        #expect(entry.libraryName == provider.libraryURL.path)
        #expect(try index.matches(.init(machOName: symbol, language: .swift)).only?.address == entry.address)
        let call = try resolver.resolve(.init(name: "ABIImportSwiftCall", language: .c), in: image, loading: .loadedOnly)
        #expect(unsafe call.withUnsafeAddress { unsafeBitCast($0, to: (@convention(c) (Int) -> Int).self)(21) } == 42)
    }

    @Test func preservesLargeNegativeChainedAddends() throws {
        let provider = try FixtureLibrary(cxxSource: "extern \"C\" { char ABIImportBuffer[8] = {}; }")
        defer { provider.cleanup() }
        let consumer = try FixtureLibrary(cxxSource: """
        asm(".section __DATA,__data\\n"
            ".globl _ABIImportNegative\\n"
            ".p2align 3\\n"
            "_ABIImportNegative:\\n"
            ".quad _ABIImportBuffer - 0x100000001\\n");
        """, linkArguments: [provider.libraryURL.path])
        defer { consumer.cleanup() }
        let resolver = SymbolResolver()
        let image = try #require(resolver.images(matching: .path(consumer.libraryURL)).first)
        let reference = try #require(resolver.importIndex(for: image).matches(.init(name: "ABIImportBuffer", language: .c, kind: .data)).only)
        #expect(reference.addend == -0x100000001)
        #expect(reference.libraryName == provider.libraryURL.path)
        let target = try resolver.resolve(.init(name: "ABIImportBuffer", language: .c, kind: .data), in: .path(provider.libraryURL), loading: .loadedOnly)
        let original = unsafe target.withUnsafeAddress { UInt64(UInt(bitPattern: $0)) }
        #expect(try #require(UnsafePointer<UInt64>(bitPattern: UInt(reference.address))).pointee == original &- 0x100000001)
    }

    @Test func keepsDependencyOrdinalsAbove127Positive() throws {
        var providers: [FixtureLibrary] = []
        defer { providers.forEach { $0.cleanup() } }
        for index in 1...128 {
            providers.append(try FixtureLibrary(load: false, cxxSource: "extern \"C\" int ABIOrdinal\(index)() { return \(index); }"))
        }
        let declarations = (1...128).map { "extern \"C\" int ABIOrdinal\($0)();" }.joined(separator: "\n")
        let calls = (1...128).map { "ABIOrdinal\($0)()" }.joined(separator: " + ")
        let consumer = try FixtureLibrary(cxxSource: declarations + "\nextern \"C\" int ABIOrdinals() { return " + calls + "; }",
            linkArguments: providers.map { $0.libraryURL.path })
        defer { consumer.cleanup() }
        let resolver = SymbolResolver()
        let image = try #require(resolver.images(matching: .path(consumer.libraryURL)).first)
        let index = try resolver.importIndex(for: image)
        let query = NativeDeclaration(name: "ABIOrdinal128", language: .c)
        let reference = try #require(index.matches(query).only)
        #expect(reference.libraryOrdinal >= 128)
        #expect(reference.libraryName == providers.last?.libraryURL.path)
        #expect(try index.matches(query, libraryOrdinal: reference.libraryOrdinal).count == 1)
    }

    @Test func combinesNormalAndWeakCoalescingRecordsForOneSlot() throws {
        let provider = try FixtureLibrary(cxxSource: "extern \"C\" { __attribute__((weak)) int ABIWeakDefinition = 42; }")
        defer { provider.cleanup() }
        let consumer = try FixtureLibrary(cxxSource: "extern \"C\" int ABIWeakDefinition; extern \"C\" { int *ABIWeakPointer = &ABIWeakDefinition; }",
            linkArguments: [provider.libraryURL.path, "-Wl,-no_fixup_chains"])
        defer { consumer.cleanup() }
        let resolver = SymbolResolver()
        let image = try #require(resolver.images(matching: .path(consumer.libraryURL)).first)
        let index = try resolver.importIndex(for: image)
        let query = NativeDeclaration(name: "ABIWeakDefinition", language: .c, kind: .data)
        let reference = try #require(index.matches(query).only)
        #expect(reference.usesWeakCoalescing)
        #expect(reference.libraryName == provider.libraryURL.path && reference.libraryOrdinal > 0)
        #expect(try index.matches(query, libraryOrdinal: reference.libraryOrdinal).count == 1)
    }

    @Test func separatesFileAndVMOffsetsAfterZeroFill() throws {
        let fixture = try FixtureLibrary(cxxSource: """
        #include <unistd.h>
        char largeZeroFill[131072];
        __attribute__((section("__Extra,__refs"))) void *externalReference = reinterpret_cast<void *>(&getpid);
        extern "C" int ABIImportCall() { return getpid() + largeZeroFill[0]; }
        """)
        defer { fixture.cleanup() }
        let resolver = SymbolResolver()
        let image = try #require(resolver.images(matching: .path(fixture.libraryURL)).first)
        let references = try resolver.importIndex(for: image).matches(.init(name: "getpid", language: .c))
        #expect(references.count == 2)
        #expect(references.filter { $0.sectionType == .non_lazy_symbol_pointers }.count == 1)
        #expect(references.filter { $0.sectionType == .regular }.count == 1)
        let handle = try #require(dlopen(nil, RTLD_NOW))
        defer { dlclose(handle) }
        let target = try #require(dlsym(handle, "getpid"))
        for reference in references {
            let slot = try #require(UnsafePointer<UnsafeRawPointer>(bitPattern: UInt(reference.address)))
            #expect(slot.pointee == UnsafeRawPointer(target))
        }
    }

    @Test func indirectTablesKeepSlotPositionsAfterLocalEntries() throws {
        let resolver = SymbolResolver()
        let ownSymbol = try resolver.resolve(.init(name: "ABICopyLoadedImages", language: .c), in: .automatic)
        let metadata = ImportMetadata(image: ownSymbol.image)
        let table = try #require(metadata.macho.indirectSymbols)
        #expect(table.contains { $0.isLocal })
        let complete = try resolver.importIndex(for: ownSymbol.image)
        let indirect = try metadata.indirect()
        #expect(!indirect.isEmpty)
        // Independently decoded chained/bind metadata is the oracle for the
        // indirect table's physical addresses, including positions after locals.
        for reference in indirect {
            let matching = try complete.matches(.init(machOName: reference.symbol, language: .c))
            #expect(matching.contains { $0.address == reference.address })
            #expect(reference.authentication == nil)
        }
    }

    @Test func preservesTheDeclaredReexportProvider() throws {
        let provider = try FixtureLibrary(cxxSource: "extern \"C\" int ABIReexportedImport() { return 42; }")
        defer { provider.cleanup() }
        let umbrella = try FixtureLibrary(cxxSource: "extern \"C\" int ABIImportUmbrella() { return 0; }",
            linkArguments: ["-Wl,-reexport_library," + provider.libraryURL.path])
        defer { umbrella.cleanup() }
        let consumer = try FixtureLibrary(cxxSource: "extern \"C\" int ABIReexportedImport(); extern \"C\" int ABIImportCall() { return ABIReexportedImport(); }",
            linkArguments: [umbrella.libraryURL.path])
        defer { consumer.cleanup() }
        let resolver = SymbolResolver()
        let image = try #require(resolver.images(matching: .path(consumer.libraryURL)).first)
        let entry = try #require(resolver.importIndex(for: image).matches(.init(name: "ABIReexportedImport", language: .c)).only)
        #expect(entry.libraryName == umbrella.libraryURL.path)
        #expect(entry.libraryName != provider.libraryURL.path)
    }

    @Test func rejectsReplacedBackingMetadataWithoutReportingNoMatches() throws {
        let fixture = try FixtureLibrary(cxxSource: "#include <unistd.h>\nextern \"C\" int ABIImportCall() { return getpid(); }")
        let other = try FixtureLibrary(load: false, cxxSource: "extern \"C\" int ABIOtherImport() { return 0; }")
        defer { fixture.cleanup(); other.cleanup() }
        let resolver = SymbolResolver()
        let image = try #require(resolver.images(matching: .path(fixture.libraryURL)).first)
        try FileManager.default.moveItem(at: fixture.libraryURL, to: fixture.directory.appendingPathComponent("original.dylib"))
        try FileManager.default.copyItem(at: other.libraryURL, to: fixture.libraryURL)
        do {
            _ = try resolver.importIndex(for: image)
            Issue.record("A different file must not describe the loaded image's slots")
        } catch ABIResolutionError.metadataUnavailable(let description) {
            #expect(description.contains("does not match"))
        }
    }

    @Test func readsTheMatchingUniversalSliceAndReportsUnavailableBackingFile() throws {
        let fixture = try FixtureLibrary(cxxSource: "#include <unistd.h>\nextern \"C\" int ABIImportCall() { return getpid(); }")
        defer { fixture.cleanup() }
        let resolver = SymbolResolver()
        let image = try #require(resolver.images(matching: .path(fixture.libraryURL)).first)
        let universal = fixture.directory.appendingPathComponent("universal.dylib")
        try FixtureLibrary.run(["lipo", "-create", fixture.libraryURL.path, "-output", universal.path])
        // Replace the directory entry, not the already-loaded file mapping.
        let original = fixture.directory.appendingPathComponent("original.dylib")
        try FileManager.default.moveItem(at: fixture.libraryURL, to: original)
        try FileManager.default.moveItem(at: universal, to: fixture.libraryURL)
        let index = try resolver.importIndex(for: image)
        #expect(try index.matches(.init(name: "getpid", language: .c)).count == 1)
        resolver.removeCachedResults()
        try FileManager.default.removeItem(at: fixture.libraryURL)
        #expect(throws: ABIResolutionError.self) { _ = try resolver.importIndex(for: image) }
        #expect(try index.matches(.init(name: "getpid", language: .c)).count == 1)
    }

    @Test func retainedReferencesOutliveCacheAndGenerationChangesRebuildTheIndex() throws {
        let fixture = try FixtureLibrary(cxxSource: "#include <unistd.h>\nextern \"C\" int ABIImportCall() { return getpid(); }")
        defer { fixture.cleanup() }
        let resolver = SymbolResolver()
        var reference: ImportedReference?
        var firstGeneration: UInt64 = 0
        do {
            let image = try #require(resolver.images(matching: .path(fixture.libraryURL)).first)
            firstGeneration = image.identity.loadGeneration
            reference = try resolver.importIndex(for: image).matches(.init(name: "getpid", language: .c)).only
        }
        fixture.close()
        resolver.removeCachedResults()
        #expect(try #require(reference).image.identity.loadGeneration == firstGeneration)
        let address = try #require(reference).address
        #expect(try #require(UnsafePointer<UInt>(bitPattern: UInt(address))).pointee != 0)
        reference = nil
        try fixture.load()
        let reloaded = try #require(resolver.images(matching: .path(fixture.libraryURL)).first)
        #expect(reloaded.identity.loadGeneration != firstGeneration)
        #expect(try resolver.importIndex(for: reloaded).matches(.init(name: "getpid", language: .c)).count == 1)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
#endif
