import ABIBridgeTestSupport
#if os(macOS)
import ABIBridge
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct RuntimePreparationTests {
    @MainActor @Test
    func ordinaryLookupPreparesAColdImageAndProducesASynchronousHandle() throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let add = try runtime.resolveCXXFunctionAndWait(
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
        let resolved = try runtime.resolveAndWait(request)
        #expect(prepared.declaration == request.declaration)
        #expect(prepared.image.identity == resolved.image.identity)
        #expect(
            unsafe prepared.withUnsafeAddress { first in
                resolved.withUnsafeAddress { first == $0 }
            }
        )

        runtime.removeCachedResults()
        #expect(unsafe prepared.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
        let rebuilt = try runtime.resolveAndWait(request)
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

    @MainActor @Test(arguments: ["sync", "async", "prepare"])
    func coldAcquisitionInitializesTheImageOnTheCallingThreadOrPreparationWorker(
        lookup: String
    ) async throws {
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
        if lookup == "prepare" {
            symbol = try await runtime.prepare(request)
        } else if lookup == "async" {
            symbol = try await runtime.resolve(request)
        } else {
            symbol = try runtime.resolveAndWait(request)
        }

        #expect(
            unsafe symbol.withUnsafeAddress { $0.load(as: Int32.self) }
                == (lookup == "sync" ? 1 : 0)
        )
        MainActor.assertIsolated()
    }

    @MainActor @Test
    func synchronousDemandDoesNotDependOnAQueuedMainActorPreparationTask() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let name = fixture.namespace + "::add(int, int)"
        let image = ImageSelector.path(fixture.libraryURL)
        let preparation = Task {
            try await runtime.prepare {
                try $0.resolveCXXFunctionAndWait(
                    named: name,
                    as: ((Int32, Int32) -> Int32).self,
                    in: image
                )
            }
        }

        let demanded = try runtime.resolveCXXFunctionAndWait(
            named: name,
            as: ((Int32, Int32) -> Int32).self,
            in: image
        )
        #expect(try unsafe demanded.unsafeInvoke(19, 23) == 42)
        let prepared = try await preparation.value
        #expect(try unsafe prepared.unsafeInvoke(19, 23) == 42)
        MainActor.assertIsolated()
    }

    @MainActor @Test(arguments: [false, true])
    func demandLookupDoesNotWaitForUnrelatedPreparation(asynchronous: Bool) async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let name = fixture.namespace + "::add(int, int)"
        let image = ImageSelector.path(fixture.libraryURL)
        let ready = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let finished = Mutex(false)
        defer { release.signal() }
        let preparation = Task {
            try await runtime.prepare { runtime in
                let function = try runtime.resolveCXXFunctionAndWait(
                    named: name,
                    as: ((Int32, Int32) -> Int32).self,
                    in: image
                )
                ready.continuation.yield(())
                _ = release.wait(timeout: .now() + 10)
                finished.withLock { $0 = true }
                return function
            }
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()

        let function: NativeFunction<Int32, Int32, Int32>
        if asynchronous {
            function = try await runtime.resolveCXXFunction(
                named: name,
                as: ((Int32, Int32) -> Int32).self,
                in: image
            )
        } else {
            function = try runtime.resolveCXXFunctionAndWait(
                named: name,
                as: ((Int32, Int32) -> Int32).self,
                in: image
            )
        }
        #expect(!finished.withLock { $0 })
        #expect(try unsafe function.unsafeInvoke(19, 23) == 42)
        release.signal()
        let prepared = try await preparation.value
        #expect(try unsafe prepared.unsafeInvoke(19, 23) == 42)
        MainActor.assertIsolated()
    }

    @MainActor @Test(arguments: [false, true], [false, true])
    func swiftLookupSelectsTheCallingThreadOrAnIndependentWorker(
        asynchronous: Bool,
        typeLookup: Bool
    ) async throws {
        let dependency = try FixtureLibrary(
            load: false,
            cxxSource: """
                #include <pthread.h>
                static int preparationThread = -1;
                __attribute__((constructor)) static void initialize() {
                    preparationThread = pthread_main_np();
                }
                extern "C" int ABISwiftPreparationThread() { return preparationThread; }
                """
        )
        defer { dependency.cleanup() }
        let module = "SwiftPreparation_" + dependency.namespace
        let fixture = try FixtureLibrary(
            load: false,
            swiftModule: module,
            swiftSource: """
                @_silgen_name("ABISwiftPreparationThread") private func preparationThread() -> Int32
                public func thread() -> Int32 { preparationThread() }
                public final class Receiver { public init() {} }
                """,
            linkArguments: [dependency.libraryURL.path]
        )
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let name = module + ".thread()"
        let image = ImageSelector.path(fixture.libraryURL)

        if typeLookup {
            let typeName = module + ".Receiver"
            let type: NativeSwiftType
            if asynchronous {
                type = try await runtime.resolveSwiftType(named: typeName, in: image)
            } else {
                type = try runtime.resolveSwiftTypeAndWait(named: typeName, in: image)
            }
            let retained = try await runtime.resolveSwiftType(
                named: typeName,
                in: type.image,
                loading: .loadedOnly
            )
            #expect(type === retained)
            let represented = try await runtime.resolveSwiftType(
                named: typeName,
                as: AnyObject.self,
                in: image
            )
            let retainedRepresentation = try await runtime.resolveSwiftType(
                named: typeName,
                as: AnyObject.self,
                in: type.image,
                loading: .loadedOnly
            )
            #expect(represented === retainedRepresentation)
        }

        let function: NativeSwiftFunction<() -> Int32>
        if asynchronous {
            function = try await runtime.resolve(
                .function(
                    name,
                    as: (() -> Int32).self
                ),
                in: image
            )
        } else {
            function = try runtime.resolveAndWait(
                .function(
                    name,
                    as: (() -> Int32).self
                ),
                in: image
            )
        }
        MainActor.assertIsolated()
        #expect(try unsafe function.unsafeInvoke() == (asynchronous ? 0 : 1))

        let retained = try await runtime.resolve(
            .function(
                name,
                as: (() -> Int32).self
            ),
            in: function.symbol.image,
            loading: .loadedOnly
        )
        #expect(retained.symbol.declaration == function.symbol.declaration)
        #expect(try unsafe retained.unsafeInvoke() == (asynchronous ? 0 : 1))
        MainActor.assertIsolated()
    }

    @MainActor @Test(arguments: [false, true])
    func asynchronousMemberPreparationKeepsReceiverIsolation(bound: Bool) async throws {
        let runtime = ABIRuntime()
        let receiver = SwiftPreparationReceiver()
        let type = try await runtime.resolveSwiftType(
            named: "ABIBridgeTests.SwiftPreparationReceiver"
        )
        let object = runtime.object(receiver)
        SwiftPreparationValue.preparationThreads.withLock { $0.removeAll() }
        defer { SwiftPreparationValue.preparationThreads.withLock { $0.removeAll() } }

        if bound {
            let method = try await object.resolve(
                .method(
                    "read()",
                    as: (() -> SwiftPreparationValue).self
                )
            )
            let getter = try await object.resolve(
                .getter(
                    "value",
                    as: (() -> SwiftPreparationValue).self
                )
            )
            let setter = try await object.resolve(
                .setter(
                    "value",
                    as: ((SwiftPreparationValue) -> Void).self
                )
            )
            let observations = SwiftPreparationValue.preparationThreads.withLock { $0 }
            #expect(!observations.isEmpty)
            #expect(observations.allSatisfy { !$0 })
            MainActor.assertIsolated()
            receiver.raw = 43
            #expect(try unsafe method.unsafeInvoke().raw == 43)
            #expect(try unsafe getter.unsafeInvoke().raw == 43)
            try unsafe setter.unsafeInvoke(SwiftPreparationValue(raw: 44))
            #expect(receiver.raw == 44)
        } else {
            let method = try await type.resolve(
                .method(
                    "read()",
                    as: (() -> SwiftPreparationValue).self
                )
            )
            let getter = try await type.resolve(
                .getter(
                    "value",
                    as: (() -> SwiftPreparationValue).self
                )
            )
            let setter = try await type.resolve(
                .setter(
                    "value",
                    as: ((SwiftPreparationValue) -> Void).self
                )
            )
            let observations = SwiftPreparationValue.preparationThreads.withLock { $0 }
            #expect(!observations.isEmpty)
            #expect(observations.allSatisfy { !$0 })
            MainActor.assertIsolated()
            receiver.raw = 43
            #expect(try unsafe method.unsafeInvoke(on: receiver).raw == 43)
            #expect(try unsafe getter.unsafeInvoke(on: receiver).raw == 43)
            try unsafe setter.unsafeInvoke(on: receiver, SwiftPreparationValue(raw: 44))
            #expect(receiver.raw == 44)
        }
    }

    @MainActor @Test
    func asynchronousInitializerAndStaticPreparationRunAwayFromMainActor() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.resolveSwiftType(
            named: "ABIBridgeTests.SwiftPreparationReceiver"
        )
        let originalStaticValue = SwiftPreparationReceiver.staticValue
        defer { SwiftPreparationReceiver.staticValue = originalStaticValue }
        SwiftPreparationValue.preparationThreads.withLock { $0.removeAll() }
        defer { SwiftPreparationValue.preparationThreads.withLock { $0.removeAll() } }

        let initialize = try await type.resolve(
            .initializer(
                "init(value:)",
                as: ((SwiftPreparationValue) -> AnyObject).self
            )
        )
        let read = try await type.resolve(
            .staticMethod(
                "readStatic()",
                as: (() -> SwiftPreparationValue).self
            )
        )
        let getter = try await type.resolve(
            .staticGetter(
                "staticValue",
                as: (() -> SwiftPreparationValue).self
            )
        )
        let setter = try await type.resolve(
            .staticSetter(
                "staticValue",
                as: ((SwiftPreparationValue) -> Void).self
            )
        )
        let observations = SwiftPreparationValue.preparationThreads.withLock { $0 }
        #expect(!observations.isEmpty)
        #expect(observations.allSatisfy { !$0 })
        MainActor.assertIsolated()

        let receiver =
            try unsafe initialize.unsafeInvoke(SwiftPreparationValue(raw: 43))
            as! SwiftPreparationReceiver
        #expect(receiver.raw == 43)
        try unsafe setter.unsafeInvoke(SwiftPreparationValue(raw: 44))
        #expect(try unsafe getter.unsafeInvoke().raw == 44)
        #expect(try unsafe read.unsafeInvoke().raw == 44)
    }

    @Test func asynchronousSwiftLookupPreservesLookupFailures() async throws {
        let runtime = ABIRuntime()
        let missing = NativeDeclaration(
            name: "ABIBridgeTests.swiftPreparationMissing() -> Swift.Int32",
            language: .swift
        )
        await #expect(throws: ABIResolutionError.declarationNotFound(missing)) {
            try await runtime.resolve(
                .function(
                    missing.name,
                    as: (() -> Int32).self
                )
            )
        }
        let function = try await runtime.resolve(
            .function(
                "ABIBridgeTests.swiftABIAnswer()",
                as: (() -> Int32).self
            )
        )
        #expect(try unsafe function.unsafeInvoke() == 42)

        let missingType = NativeDeclaration(
            name: "nominal type descriptor for ABIBridgeTests.SwiftPreparationMissing",
            language: .swift,
            kind: .data
        )
        await #expect(throws: ABIResolutionError.declarationNotFound(missingType)) {
            try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftPreparationMissing")
        }
        let type = try await runtime.resolveSwiftType(
            named: "ABIBridgeTests.SwiftPreparationReceiver"
        )
        await #expect(throws: ABIResolutionError.self) {
            try await type.resolve(.getter("missing", as: (() -> Int64).self))
        }
        let getter = try await type.resolve(
            .getter(
                "value",
                as: (() -> SwiftPreparationValue).self
            )
        )
        #expect(try unsafe getter.unsafeInvoke(on: SwiftPreparationReceiver()).raw == 42)
    }

    @Test func failedPreparationDoesNotDisableLaterSynchronousLookup() async throws {
        let fixture = try FixtureLibrary(load: false)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let image = ImageSelector.path(fixture.libraryURL)
        let missing = NativeDeclaration(name: fixture.namespace + "::missing", language: .cxx)
        do {
            _ = try await runtime.prepare { try $0.resolveAndWait(missing, in: image) }
            Issue.record("A missing preparation requirement must report its lookup error")
        } catch ABIResolutionError.declarationNotFound(let declaration) {
            #expect(declaration == missing)
        }

        let demanded = try runtime.resolveCXXFunctionAndWait(
            named: fixture.namespace + "::add(int, int)",
            as: ((Int32, Int32) -> Int32).self,
            in: image
        )
        #expect(try unsafe demanded.unsafeInvoke(19, 23) == 42)
    }
}

@frozen public struct SwiftPreparationValue: BitwiseCopyable, ABIBridgeValue {
    public var raw: Int64
    static let preparationThreads = Mutex<[Bool]>([])
    public static var abiType: NativeType {
        preparationThreads.withLock { $0.append(Thread.isMainThread) }
        return .int64
    }
}

public final class SwiftPreparationReceiver {
    public var raw: Int64 = 42
    private static let staticRaw = Mutex<Int64>(42)
    public init() {}
    public init(value: SwiftPreparationValue) { raw = value.raw }
    @inline(never) public func read() -> SwiftPreparationValue { .init(raw: raw) }
    public var value: SwiftPreparationValue {
        get { .init(raw: raw) }
        set { raw = newValue.raw }
    }
    @inline(never) public static func readStatic() -> SwiftPreparationValue {
        .init(raw: staticRaw.withLock { $0 })
    }
    public static var staticValue: SwiftPreparationValue {
        get { .init(raw: staticRaw.withLock { $0 }) }
        set { staticRaw.withLock { $0 = newValue.raw } }
    }
}
#endif
