#if os(macOS)
#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ABIBridgeCore
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct SymbolResolutionTests {
    @Test func exactSpellingsPreserveCXXVariantsAndUnderscores() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(fixture.libraryURL)
        let prefix = "_ZN\(fixture.namespace.utf8.count)\(fixture.namespace)7Counter"
        let deleting = NativeDeclaration(linkerName: prefix + "D0Ev", language: .cxx)
        let complete = NativeDeclaration(machOName: "_" + prefix + "D1Ev", language: .cxx)
        let deletingSymbol = try await runtime.resolve(deleting, in: scope)
        let completeSymbol = try await runtime.resolve(complete, in: scope)
        #expect(deletingSymbol.declaration.nameForm == .linker)
        #expect(completeSymbol.declaration.nameForm == .machO)
        #expect(unsafe deletingSymbol.withUnsafeAddress { first in
            completeSymbol.withUnsafeAddress { second in first != second }
        })
        let library = try #require(dlopen(fixture.libraryURL.path, RTLD_NOW | RTLD_LOCAL))
        defer { dlclose(library) }
        #expect(unsafe deletingSymbol.withUnsafeAddress { $0 == dlsym(library, prefix + "D0Ev") })
        #expect(unsafe completeSymbol.withUnsafeAddress { $0 == dlsym(library, prefix + "D1Ev") })
        let results = await runtime.resolve([
            NativeSymbolRequest(deleting, alternatives: [
                .init(machOName: "_" + prefix + "D0Ev", language: .cxx)
            ], in: [scope]),
            .init(deleting, alternatives: [complete], in: [scope]),
            .init(.init(linkerName: "_ABIFixtureUnderscore", language: .c, kind: .data), in: [scope]),
            .init(.init(machOName: "__ABIFixtureUnderscore", language: .c, kind: .data), in: [scope])
        ])
        #expect(try results[0].get().declaration == deleting)
        do {
            _ = try results[1].get()
            Issue.record("Distinct destructor variants must not be treated as aliases")
        } catch ABIResolutionError.ambiguousDeclaration {}
        for index in [2, 3] {
            #expect(try unsafe results[index].get().withUnsafeAddress { $0.load(as: Int32.self) } == 73)
        }
        await #expect(throws: ABIResolutionError.invalidAddress) {
            _ = try await runtime.resolve(.init(linkerName: prefix + "D0Ev", language: .cxx, kind: .data), in: scope)
        }
        for query in [
            NativeDeclaration(machOName: prefix + "D0Ev", language: .cxx),
            .init(linkerName: "_" + prefix + "D0Ev", language: .cxx),
            .init(linkerName: prefix + "D0Ev ", language: .cxx)
        ] {
            do {
                _ = try await runtime.resolve(query, in: scope)
                Issue.record("Exact lookup must not guess prefixes or normalize whitespace")
            } catch ABIResolutionError.declarationNotFound {}
        }
    }

    @Test func exactSpellingsDistinguishCanonicallyEquivalentUTF8() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let composed = NativeDeclaration(machOName: "_ABIBridgeUTF8_\u{00E9}", language: .c, kind: .data)
        let decomposed = NativeDeclaration(machOName: "_ABIBridgeUTF8_e\u{0301}", language: .c, kind: .data)
        #expect(composed.name == decomposed.name) // Swift canonical string equality.
        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
        let sourceComposed = NativeDeclaration(name: "ABIBridgeUTF8_\u{00E9}", language: .c, kind: .data)
        let sourceDecomposed = NativeDeclaration(name: "ABIBridgeUTF8_e\u{0301}", language: .c, kind: .data)
        #expect(sourceComposed != sourceDecomposed)
        let scope = ImageSelector.path(fixture.libraryURL)
        let first = try await runtime.resolve(composed, in: scope)
        let second = try await runtime.resolve(decomposed, in: scope)
        #expect(unsafe first.withUnsafeAddress { $0.load(as: Int32.self) } == 31)
        #expect(unsafe second.withUnsafeAddress { $0.load(as: Int32.self) } == 32)
        let linker = NativeDeclaration(linkerName: "ABIBridgeUTF8_e\u{0301}", language: .c, kind: .data)
        let source = try await runtime.resolve(sourceDecomposed, in: scope)
        #expect(unsafe source.withUnsafeAddress { $0.load(as: Int32.self) } == 32)
        let alias = try await runtime.resolve(linker, in: scope)
        #expect(unsafe alias.withUnsafeAddress { $0.load(as: Int32.self) } == 32)
    }

    @Test func exactSwiftSpellingsUseTheSameRetainedImage() async throws {
        let module = "Exact_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let fixture = try FixtureLibrary(swiftModule: module)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let exported = try fixture.exportedSymbols().filter { $0.hasPrefix("_$s") }
        #expect(exported.count == 1)
        let machOName = try #require(exported.first)
        let mangled = String(machOName.dropFirst())
        let scope = ImageSelector.path(fixture.libraryURL)
        let symbol = try await runtime.resolve(.init(linkerName: mangled, language: .swift), in: scope)
        let literal = try await runtime.resolve(.init(machOName: "_" + mangled, language: .swift), in: scope)
        #expect(symbol.image.identity == literal.image.identity)
        #expect(unsafe symbol.withUnsafeAddress { first in literal.withUnsafeAddress { $0 == first } })
        #expect(symbol.declaration.language == .swift)
        fixture.close()
        await runtime.removeCachedResults()
        #expect(unsafe symbol.withUnsafeAddress { address in
            var info = Dl_info()
            return dladdr(address, &info) != 0
        })
    }

    @Test func batchLookupPreservesOrderFallbackAliasesAndLifetime() async throws {
        let first = try FixtureLibrary()
        let other = try FixtureLibrary()
        defer { first.cleanup(); other.cleanup() }
        let runtime = ABIRuntime()
        let counter = NativeDeclaration(name: "\(first.namespace)::counter", language: .cxx, kind: .data)
        let add = NativeDeclaration(name: "\(first.namespace)::add(int, int)", language: .cxx)
        let missing = NativeDeclaration(name: "\(first.namespace)::missing()", language: .cxx)
        let scope = ImageSelector.path(first.libraryURL)
        let fallback: [ImageSelector] = [.path(first.directory.appendingPathComponent("absent")), .path(other.libraryURL), scope]
        let requests: [NativeSymbolRequest] = [
            .init(counter, in: fallback),
            .init(missing, in: [scope]),
            .init(add, alternatives: [.init(name: "\(first.namespace)::add( int,int )", language: .cxx)], in: [scope]),
            .init(missing, alternatives: [counter], in: [scope]),
            .init(counter, in: [])
        ]
        let results = await runtime.resolve(requests)
        #expect(results.count == requests.count)
        #expect(try results[0].get().declaration == counter)
        do {
            _ = try results[1].get()
            Issue.record("A missing request must fail independently")
        } catch ABIResolutionError.declarationNotFound(let declaration) {
            #expect(declaration == missing)
        }
        #expect(try results[2].get().declaration == add)
        #expect(try results[3].get().declaration == counter)
        do {
            _ = try results[4].get()
            Issue.record("Empty scopes must not search all images")
        } catch ABIResolutionError.imageNotLoaded {}
        #expect(await runtime.resolve([NativeSymbolRequest]()).isEmpty)
        let again = try await runtime.resolve(requests[0])
        #expect(try results[0].get().image.identity == again.image.identity)
        first.close()
        other.close()
        await runtime.removeCachedResults()
        #expect(try unsafe results[0].get().withUnsafeAddress { $0.load(as: Int32.self) } == 42)
    }

    @Test func alternativesAndScopeFallbackDoNotHideInvalidOrAmbiguousMatches() async throws {
        let first = try FixtureLibrary()
        let second = try FixtureLibrary(namespace: first.namespace)
        defer { first.cleanup(); second.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(first.libraryURL)
        let add = NativeDeclaration(name: "\(first.namespace)::add(int, int)", language: .cxx)
        let counter = NativeDeclaration(name: "\(first.namespace)::counter", language: .cxx, kind: .data)
        let wrongKind = NativeDeclaration(name: counter.name, language: .cxx)
        let requests: [NativeSymbolRequest] = [
            .init(add, alternatives: [counter], in: [scope]),
            .init(add, alternatives: [wrongKind], in: [scope, .path(second.libraryURL)]),
            .init(add, in: [.automatic, scope])
        ]
        let results = await runtime.resolve(requests)
        for index in [0, 2] {
            do {
                _ = try results[index].get()
                Issue.record("Ambiguity must stop lookup")
            } catch ABIResolutionError.ambiguousDeclaration {}
        }
        do {
            _ = try results[1].get()
            Issue.record("Invalid storage must stop lookup")
        } catch ABIResolutionError.invalidAddress {}
    }

    @Test func lazyNamesShortCircuitAndTakePriorityOverScopes() async throws {
        let first = try FixtureLibrary()
        let second = try FixtureLibrary()
        defer { first.cleanup(); second.cleanup() }
        let runtime = ABIRuntime()
        let firstCounter = NativeDeclaration(name: "\(first.namespace)::counter", language: .cxx, kind: .data)
        let secondCounter = NativeDeclaration(name: "\(second.namespace)::counter", language: .cxx, kind: .data)
        let exact = NativeDeclaration(
            linkerName: "_ZN\(second.namespace.utf8.count)\(second.namespace)7counterE",
            language: .cxx, kind: .data
        )
        let missing = NativeDeclaration(linkerName: "ABIBridgeLazyMissing", language: .cxx)
        let unsupported = NativeDeclaration(name: "selector:", language: .objectiveC)
        let scopes: [ImageSelector] = [.path(first.libraryURL), .path(second.libraryURL)]
        let results = await runtime.resolve([
            NativeSymbolRequest(exact, fallbacks: [firstCounter, unsupported], in: scopes),
            .init(missing, fallbacks: [secondCounter, firstCounter, unsupported], in: scopes),
            .init(missing, alternatives: [exact], fallbacks: [unsupported], in: scopes)
        ])
        #expect(try results[0].get().declaration == exact)
        #expect(try results[1].get().declaration == secondCounter)
        #expect(try results[2].get().declaration == exact)
        #expect(try results[0].get().image.identity == results[1].get().image.identity)
        first.close()
        second.close()
        await runtime.removeCachedResults()
        for result in results {
            #expect(try unsafe result.get().withUnsafeAddress { $0.load(as: Int32.self) } == 42)
        }
    }

    @Test func lazyNamesStopOnSubstantiveErrorsAndPreserveMissingIdentity() async throws {
        let first = try FixtureLibrary()
        let second = try FixtureLibrary(namespace: first.namespace)
        defer { first.cleanup(); second.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(first.libraryURL)
        let add = NativeDeclaration(name: "\(first.namespace)::add(int, int)", language: .cxx)
        let counter = NativeDeclaration(name: "\(first.namespace)::counter", language: .cxx, kind: .data)
        let wrongKind = NativeDeclaration(name: counter.name, language: .cxx)
        let missing = NativeDeclaration(name: "ABIBridgeLazyMissing", language: .c)
        let results = await runtime.resolve([
            NativeSymbolRequest(missing, fallbacks: [add, counter], in: [.automatic, scope]),
            .init(add, alternatives: [counter], fallbacks: [add], in: [scope]),
            .init(wrongKind, fallbacks: [add], in: [scope]),
            .init(missing, fallbacks: [wrongKind, add], in: [scope]),
            .init(add, fallbacks: [wrongKind], in: [scope]),
            .init(missing, fallbacks: [.init(name: "ABIBridgeAlsoMissing", language: .c)], in: [scope]),
            .init(missing, fallbacks: [add], in: [])
        ])
        for index in [0, 1] {
            do {
                _ = try results[index].get()
                Issue.record("Ambiguity must stop candidate fallback")
            } catch ABIResolutionError.ambiguousDeclaration {}
        }
        for index in [2, 3] {
            #expect(throws: ABIResolutionError.invalidAddress) { try results[index].get() }
        }
        #expect(try results[4].get().declaration == add)
        do {
            _ = try results[5].get()
            Issue.record("Exhausted fallbacks must report the primary missing declaration")
        } catch ABIResolutionError.declarationNotFound(let declaration) {
            #expect(declaration == missing)
        }
        #expect(throws: ABIResolutionError.imageNotLoaded) { try results[6].get() }
    }

    @Test func handedOffSymbolsOwnTheImageAfterOriginalOwnersRelease() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let declaration = NativeDeclaration(
            name: "\(fixture.namespace)::counter", language: .cxx, kind: .data
        )
        var original: ResolvedSymbol? = try await runtime.resolve(declaration, in: .path(fixture.libraryURL))
        let generation = original!.image.identity.loadGeneration
        let exported = unsafe original!.copyNativeHandle()
        original = nil
        fixture.close()
        await runtime.removeCachedResults()

        let retained = try #require(ABIRetainResolvedSymbol(exported))
        ABIReleaseResolvedSymbol(exported)
        #expect(ABIResolvedSymbolAddress(retained).load(as: Int32.self) == 42)
        var restored: ResolvedSymbol? = unsafe ResolvedSymbol(retainingNativeHandle: retained)
        ABIReleaseResolvedSymbol(retained)
        #expect(restored!.declaration == declaration)
        #expect(unsafe restored!.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
        restored = nil
        let remaining = ABIRetainLoadedImage(generation)
        #expect(remaining == nil)
        if let remaining { ABIReleaseImage(remaining) }
    }

    @Test func inheritedSwiftMembersUseTheConcreteSuperclassImage() async throws {
        let module = "Inheritance_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let source = """
        import Foundation
        @objc(\(module)_ParentA) public class Parent: NSObject {
            public override init() { super.init() }
            @inline(never) public func answer() -> Int { 42 }
        }
        @objc(\(module)_ChildA) public final class Child: Parent {}
        """
        let first = try FixtureLibrary(swiftModule: module, swiftSource: source)
        defer { first.cleanup() }
        let other = source.replacingOccurrences(of: "_ParentA", with: "_ParentB")
            .replacingOccurrences(of: "_ChildA", with: "_ChildB")
            .replacingOccurrences(of: "{ 42 }", with: "{ 7 }")
        let second = try FixtureLibrary(swiftModule: module, swiftSource: other)
        defer { second.cleanup() }
        let runtime = ABIRuntime()
        do {
            _ = try await runtime.resolve(.init(name: module + ".Parent.answer() -> Swift.Int", language: .swift))
            Issue.record("The parent source name exists in both images")
        } catch ABIResolutionError.ambiguousDeclaration {}
        let type = try await runtime.swiftType(named: module + ".Child", in: .path(first.libraryURL))
        let initialize = try await type.initializer(named: "init()", as: (() -> AnyObject).self)
        let child = try unsafe initialize.unsafeInvoke()
        let method = try await type.method(named: "answer()", as: (() -> Int).self)
        #expect(method.symbol.image.identity == type.image.identity)
        #expect(try unsafe method.unsafeInvoke(on: child) == 42)
        let bound = try await runtime.object(child).method(named: "answer()", as: (() -> Int).self)
        #expect(try unsafe bound.unsafeInvoke() == 42)
    }

    @Test func automaticLookupToleratesUnrelatedLoaderChurn() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let path = fixture.libraryURL.path
        let runtime = ABIRuntime()
        try await withThrowingTaskGroup(of: Int.self) { group in
            let (started, signal) = AsyncStream<Void>.makeStream()
            group.addTask {
                defer { signal.finish() }
                var count = 0
                while !Task.isCancelled {
                    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                        throw NSError(domain: "ABIBridgeTests.Loader", code: 1)
                    }
                    dlclose(handle)
                    count += 1
                    if count == 1 { signal.yield(()); signal.finish() }
                    // Let the query acquire dyld's unfair lock between cycles.
                    try? await Task.sleep(for: .microseconds(100))
                }
                return count
            }
            var startup = started.makeAsyncIterator()
            guard await startup.next() != nil else {
                try await group.waitForAll()
                throw NSError(domain: "ABIBridgeTests.Loader", code: 2)
            }
            for _ in 0..<8 {
                await runtime.removeCachedResults()
                let function = try await runtime.cFunction(named: "getpid", as: (() -> Int32).self)
                #expect(try unsafe function.unsafeInvoke() == getpid())
            }
            group.cancelAll()
            #expect(try await group.next() ?? 0 > 0)
        }
        await runtime.removeCachedResults()
    }

    @Test func resolvesFunctionsDataAndVTablesByDeclaration() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let images = try await runtime.images(matching: .path(fixture.libraryURL))
        let image = try #require(images.first)
        #expect(images.count == 1)
        #expect(image.identity.uuid != nil)

        let function = try await runtime.resolve(
            .init(name: "\(fixture.namespace)::add(int, int)", language: .cxx), in: image
        )
        let expected = try fixture.address(kind: 0)
        let actual = unsafe function.withUnsafeAddress { UInt(bitPattern: $0) }
        #expect(actual == expected)
        #expect(function.source == .image)

        let data = try await runtime.resolve(
            .init(name: "\(fixture.namespace)::counter", language: .cxx, kind: .data), in: image
        )
        #expect(unsafe data.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
        let vtable = try await runtime.resolve(
            .init(vtableFor: "\(fixture.namespace)::Counter"), in: image
        )
        let legacyVTable = try await runtime.resolve(
            .init(name: "vtable for \(fixture.namespace)::Counter", language: .cxx, kind: .vtable), in: image
        )
        var failure: OpaquePointer?
        let nativeRuntime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(nativeRuntime) }
        let native = "\(fixture.namespace)::Counter".withCString { typeName in
            fixture.libraryURL.path.withCString { path in
                ABIResolveCXXVTable(nativeRuntime, typeName, Int32(ABIImagePath), path, &failure)
            }
        }
        let nativeVTable = try #require(native)
        defer { ABIReleaseResolvedSymbol(nativeVTable) }
        #expect(failure == nil)
        #expect(unsafe legacyVTable.withUnsafeAddress { $0 == ABIResolvedSymbolAddress(nativeVTable) })
        let expectedVTable = try fixture.address(kind: 2)
        #expect(unsafe vtable.withUnsafeAddress { UInt(bitPattern: $0) } == expectedVTable)
        let member = try await runtime.resolve(
            .init(name: "\(fixture.namespace)::Counter::value() const", language: .cxx), in: image
        )
        #expect(unsafe member.withUnsafeAddress { UInt(bitPattern: $0) } != expectedVTable)

        let again = try await runtime.resolve(function.declaration, in: image)
        #expect(unsafe again.withUnsafeAddress { UInt(bitPattern: $0) } == actual)
        await runtime.removeCachedResults()
        let rebuilt = try await runtime.resolve(function.declaration, in: image)
        #expect(unsafe rebuilt.withUnsafeAddress { UInt(bitPattern: $0) } == actual)
        #expect(rebuilt.image.identity == image.identity)
    }

    #if DEBUG
    @Test func appendedLocalSymbolsInvalidateEmptyCandidateGroups() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let image = try #require(try await runtime.images(matching: .path(fixture.libraryURL)).first)
        let declaration = NativeDeclaration(name: "\(fixture.namespace)::add(int, int)", language: .cxx)
        let original = SymbolIndex(image: image).matches(declaration)
        #expect(!original.isEmpty)
        let index = SymbolIndex(image: image)
        index.symbols = []
        #expect(index.matches(declaration).isEmpty)
        index.appendSharedCacheSymbols(original.map {
            IndexedSymbol(name: $0.name, address: $0.address, source: .sharedCache)
        })
        let resolved = try #require(try index.resolve(declaration, source: .sharedCache))
        let expected = try fixture.address(kind: 0)
        #expect(unsafe resolved.withUnsafeAddress { UInt(bitPattern: $0) } == expected)
    }

    #endif

    @Test func typedCXXFunctionsRetainImagesAndReuseScopes() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let name = "\(fixture.namespace)::add(int, int)"
        let function = try await runtime.cxxFunction(
            named: name, as: ((Int32, Int32) -> Int32).self, in: .path(fixture.libraryURL)
        )
        let image = function.symbol.image
        let again = try await runtime.cxxFunction(
            named: name, as: ((Int32, Int32) -> Int32).self, in: image
        )
        let address = try await runtime.cFunction(
            named: "ABIFixtureAddress", as: ((Int32) -> UInt).self, in: image
        )
        let expectedAddress = try fixture.address(kind: 0)
        #expect(try unsafe address.unsafeInvoke(0) == expectedAddress)
        #expect(function.symbol.image.identity == again.symbol.image.identity)
        fixture.close()
        await runtime.removeCachedResults()
        #expect(try unsafe function.unsafeInvoke(20, 22) == 42)
        #expect(try unsafe again.unsafeInvoke(12, 30) == 42)
    }

    @Test func missingWrongKindAndAmbiguousDeclarationsRemainDistinct() async throws {
        let first = try FixtureLibrary()
        defer { first.cleanup() }
        let second = try FixtureLibrary(namespace: first.namespace)
        defer { second.cleanup() }
        let runtime = ABIRuntime()
        let declaration = NativeDeclaration(name: "\(first.namespace)::add(int, int)", language: .cxx)

        await #expect(throws: ABIResolutionError.declarationNotFound(.init(name: "doesNotExist", language: .c))) {
            _ = try await runtime.resolve(.init(name: "doesNotExist", language: .c), in: .path(first.libraryURL))
        }
        await #expect(throws: ABIResolutionError.invalidAddress) {
            _ = try await runtime.resolve(.init(name: declaration.name, language: .cxx, kind: .data), in: .path(first.libraryURL))
        }
        do {
            _ = try await runtime.resolve(declaration)
            Issue.record("Expected two distinct definitions to be ambiguous")
        } catch ABIResolutionError.ambiguousDeclaration(_, let candidates) {
            #expect(candidates.count == 2)
        }
        await runtime.removeCachedResults()
    }

    @Test func lookupRetriesAfterLoadAndImageHandlesKeepAddressesAlive() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let request = NativeDeclaration(name: "\(fixture.namespace)::counter", language: .cxx, kind: .data)
        await #expect(throws: ABIResolutionError.imageNotLoaded) {
            _ = try await runtime.resolve(request, in: .path(fixture.libraryURL))
        }
        try fixture.load()
        let resolved = try await runtime.resolve(request, in: .path(fixture.libraryURL))
        fixture.close()
        await runtime.removeCachedResults()
        #expect(unsafe resolved.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
    }

    @Test func quickStartAndFrameworkScopeUseLoadedSystemImages() async throws {
        let runtime = ABIRuntime()
        let foundations = try await runtime.images(matching: .framework(named: "Foundation"))
        #expect(foundations.count == 1)
        let symbol = try await runtime.resolve(.init(name: "getpid", language: .c))
        #expect(symbol.source == .image)
    }

    @Test func resolvesSwiftSourceDeclarations() async throws {
        #expect(swiftFixtureEcho(41) == 42)
        let path = try #require(Bundle(for: FixtureBundleMarker.self).executableURL)
        let runtime = ABIRuntime()
        let symbol = try await runtime.resolve(
            .init(name: "ABIBridgeTests.swiftFixtureEcho(Swift.Int32) -> Swift.Int32", language: .swift),
            in: .path(path)
        )
        #expect(symbol.source == .image)
    }

    @Test func threadLocalDescriptorsAreNotReturnedAsOrdinaryData() async throws {
        let fixture = try FixtureLibrary(threadLocal: true)
        defer { fixture.cleanup() }
        let address = try fixture.address(kind: 3)
        let pointer = try #require(UnsafeRawPointer(bitPattern: address))
        #expect(pointer.load(as: Int32.self) == 42)
        let runtime = ABIRuntime()
        await #expect(throws: ABIResolutionError.invalidAddress) {
            _ = try await runtime.resolve(
                .init(name: "\(fixture.namespace)::localCounter", language: .cxx, kind: .data),
                in: .path(fixture.libraryURL)
            )
        }
    }

    @Test func resolvesCompressedSwiftModuleNames() async throws {
        let fixture = try FixtureLibrary(swiftModule: "FooFoo")
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let symbol = try await runtime.resolve(
            .init(name: "FooFoo.echo() -> ()", language: .swift),
            in: .path(fixture.libraryURL)
        )
        #expect(symbol.source == .image)
    }

    @Test func nativeModuleSupportsBackendFixtures() throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let include = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ABIBridgeCore/include")
        let client = fixture.directory.appendingPathComponent("consumer.mm")
        try """
        @import ABIBridgeCore;
        static_assert(abi_bridge::image_identity{1, 2, 3}.load_generation == 3);
        """.write(to: client, atomically: true, encoding: .utf8)
        try FixtureLibrary.run([
            "--sdk", "macosx", "clang++", "-std=c++20", "-fmodules", "-fcxx-modules",
            "-fmodule-map-file=" + include.appendingPathComponent("module.modulemap").path,
            "-fmodules-cache-path=" + fixture.directory.appendingPathComponent("ModuleCache").path,
            "-I", include.path, "-fsyntax-only", client.path,
        ])
    }

    @Test func unloadingInvalidatesTheNativeGeneration() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let generation = try await generation(of: fixture.libraryURL, runtime: runtime)
        fixture.close()
        let lease = ABIRetainLoadedImage(generation)
        if let lease { ABIReleaseImage(lease) }
        #expect(lease == nil)
        try fixture.load()
        let reloaded = try await self.generation(of: fixture.libraryURL, runtime: runtime)
        #expect(reloaded != generation)
    }

    private func generation(of url: URL, runtime: ABIRuntime) async throws -> UInt64 {
        let images = try await runtime.images(matching: .path(url))
        return try #require(images.first).identity.loadGeneration
    }
}

private final class FixtureBundleMarker: NSObject {}

@inline(never)
public func swiftFixtureEcho(_ value: Int32) -> Int32 { value + 1 }

private final class FixtureLibrary {
    let directory: URL
    let libraryURL: URL
    let namespace: String
    private var handle: UnsafeMutableRawPointer?

    init(namespace: String? = nil, load: Bool = true, swiftModule: String? = nil, swiftSource: String? = nil, threadLocal: Bool = false) throws {
        self.namespace = namespace ?? "Fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        libraryURL = directory.appendingPathComponent("fixture.dylib")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent(swiftModule == nil ? "fixture.cpp" : "fixture.swift")
        let cxxSource = """
        #include <cstdint>
        namespace \(self.namespace) {
        int counter = 42;
        \(threadLocal ? "thread_local int localCounter = 42;" : "")
        int add(int a, int b) { return a + b; }
        class Counter {
        public:
            virtual ~Counter();
            virtual int value() const;
        };
        Counter::~Counter() {}
        int Counter::value() const { return counter; }
        Counter object;
        }
        extern "C" int _ABIFixtureUnderscore = 73;
        extern "C" int exactComposed asm("_ABIBridgeUTF8_\u{00E9}") = 31;
        extern "C" int exactDecomposed asm("_ABIBridgeUTF8_e\u{0301}") = 32;
        extern "C" uintptr_t ABIFixtureAddress(int kind) {
            \(threadLocal ? "if (kind == 3) return reinterpret_cast<uintptr_t>(&\(self.namespace)::localCounter);" : "")
            if (kind == 0) return reinterpret_cast<uintptr_t>(&\(self.namespace)::add);
            if (kind == 1) return reinterpret_cast<uintptr_t>(&\(self.namespace)::counter);
            return *reinterpret_cast<uintptr_t *>(&\(self.namespace)::object) - 2 * sizeof(void *);
        }
        """
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        if let swiftModule {
            let target = "\(architecture)-apple-macosx15.4"
            try (swiftSource ?? "public func echo() {}").write(to: source, atomically: true, encoding: .utf8)
            try Self.run(["--sdk", "macosx", "swiftc", "-module-name", swiftModule, "-target", target,
                          "-emit-library", source.path, "-o", libraryURL.path])
        } else {
            try cxxSource.write(to: source, atomically: true, encoding: .utf8)
            try Self.run(["--sdk", "macosx", "clang++", "-arch", architecture, "-std=c++20", "-mmacosx-version-min=15.4",
                          "-dynamiclib", source.path, "-o", libraryURL.path])
        }
        if load { try self.load() }
    }

    static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        // XCTest injects loader paths for its own Xcode. A child compiler must
        // resolve its own libraries, even when xcode-select points elsewhere.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    func exportedSymbols() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        process.arguments = ["--sdk", "macosx", "nm", "-gUj", libraryURL.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    func load() throws {
        handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL)
        try #require(handle != nil, Comment(rawValue: dlerror().map { String(cString: $0) } ?? "dlopen failed"))
    }

    func address(kind: Int32) throws -> UInt {
        let symbol = try #require(dlsym(handle, "ABIFixtureAddress"))
        let function = unsafeBitCast(symbol, to: (@convention(c) (Int32) -> UInt).self)
        return function(kind)
    }

    func close() {
        if let handle { dlclose(handle) }
        handle = nil
    }

    func cleanup() {
        close()
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
