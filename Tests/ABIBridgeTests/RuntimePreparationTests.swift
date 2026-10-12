import ABIBridgeTestSupport
#if os(macOS)
import ABIBridge
import Foundation
import Testing

@Suite(.serialized)
struct RuntimePreparationTests {
    @Test func ordinaryLookupPreparesAColdImageAndProducesASynchronousHandle() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let add = try await runtime.cxxFunction(
            named: fixture.namespace + "::add(int, int)",
            as: ((Int32, Int32) -> Int32).self,
            in: .path(fixture.libraryURL)
        )

        #expect(try unsafe add.unsafeInvoke(19, 23) == 42)
        #expect(try unsafe add.unsafeInvoke(1, 2) == 3)
    }

    @Test func preparedSymbolsRemainUsableAcrossLookupAndCacheRemoval() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let request = NativeSymbolRequest(
            .init(name: fixture.namespace + "::counter", language: .cxx, kind: .data),
            in: [.path(fixture.libraryURL)]
        )

        let prepared = try await runtime.prepare(request)
        let resolved = try await runtime.resolve(request)
        #expect(prepared.declaration == request.declaration)
        #expect(prepared.image.identity == resolved.image.identity)
        #expect(
            unsafe prepared.withUnsafeAddress { first in
                resolved.withUnsafeAddress { first == $0 }
            }
        )

        await runtime.removeCachedResults()
        #expect(unsafe prepared.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
        let rebuilt = try await runtime.resolve(request)
        #expect(rebuilt.image.identity == prepared.image.identity)
        #expect(unsafe rebuilt.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
    }

    @Test func batchPreparationPreservesOrderAndPartialSuccess() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(fixture.libraryURL)
        let counter = NativeDeclaration(
            name: fixture.namespace + "::counter",
            language: .cxx,
            kind: .data
        )
        let missing = NativeDeclaration(
            name: fixture.namespace + "::missing",
            language: .cxx,
            kind: .data
        )
        let add = NativeDeclaration(name: fixture.namespace + "::add(int, int)", language: .cxx)
        let requests = [counter, missing, add].map { NativeSymbolRequest($0, in: [scope]) }

        let results = await runtime.prepare(requests)
        #expect(results.count == requests.count)
        let preparedCounter = try results[0].get()
        #expect(preparedCounter.declaration == counter)
        #expect(unsafe preparedCounter.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
        do {
            _ = try results[1].get()
            Issue.record("A missing preparation requirement must fail independently")
        } catch ABIResolutionError.declarationNotFound(let declaration) {
            #expect(declaration == missing)
        }
        #expect(try results[2].get().declaration == add)
        #expect(await runtime.prepare([NativeSymbolRequest]()).isEmpty)
    }

    @Test func preparationAndDemandLookupCanRunConcurrently() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let request = NativeSymbolRequest(
            .init(name: fixture.namespace + "::counter", language: .cxx, kind: .data),
            in: [.path(fixture.libraryURL)]
        )

        async let preparation = runtime.prepare(request)
        async let lookup = runtime.resolve(request)
        let (prepared, resolved) = try await (preparation, lookup)

        #expect(prepared.image.identity == resolved.image.identity)
        #expect(
            unsafe prepared.withUnsafeAddress { first in
                resolved.withUnsafeAddress { first == $0 }
            }
        )
        #expect(unsafe resolved.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
    }

    @MainActor @Test(arguments: [false, true])
    func coldAcquisitionFromMainActorInitializesTheImageOffMainThread(prepare: Bool) async throws {
        MainActor.assertIsolated()
        let fixture = try FixtureLibrary(
            load: false,
            cxxSource: """
                #include <pthread.h>
                extern "C" int ABIPreparationWasOnMainThread = -1;
                __attribute__((constructor)) static void initialize() {
                    ABIPreparationWasOnMainThread = pthread_main_np();
                }
                """
        )
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let request = NativeSymbolRequest(
            .init(name: "ABIPreparationWasOnMainThread", language: .c, kind: .data),
            in: [.path(fixture.libraryURL)]
        )

        let symbol: ResolvedSymbol
        if prepare {
            symbol = try await runtime.prepare(request)
        } else {
            symbol = try await runtime.resolve(request)
        }

        #expect(unsafe symbol.withUnsafeAddress { $0.load(as: Int32.self) } == 0)
        MainActor.assertIsolated()
    }
}
#endif
