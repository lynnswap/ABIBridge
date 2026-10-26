#if os(macOS) && DEBUG
@testable import ABIBridgeRuntime
import ABIBridgeTestSupport
import Foundation
import Synchronization
import Testing

private struct SharedCacheScanTestFailure: Error {
    let message: String
}

private final class SharedCacheScanGate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let reads = Mutex(0)
    var readCount: Int { reads.withLock { $0 } }

    @discardableResult func read() -> Int {
        let count = reads.withLock { count in
            count += 1; return count
        }
        if count == 1 {
            entered.signal()
            // The controller inspects resolver locks. A locking regression must
            // release this gate eventually so it can report the failure.
            #expect(
                release.wait(timeout: .now() + 60) == .success,
                "Releasing the captured-source scan"
            )
        }
        return count
    }

    func waitUntilEntered(until deadline: DispatchTime) throws {
        guard entered.wait(timeout: deadline) == .success else {
            throw SharedCacheScanTestFailure(message: "The captured-source scan did not start")
        }
    }
}

private final class SharedCacheScanWorker<Value: Sendable>: Sendable {
    private let name: String
    private let finished = DispatchGroup()
    private let result = Mutex<Result<Value, any Error>?>(nil)

    init(_ name: String, _ operation: @escaping @Sendable () throws -> Value) {
        self.name = name
        finished.enter()
        let worker = Thread { [self] in
            let value = Result { try operation() }
            result.withLock { $0 = value }
            finished.leave()
        }
        worker.qualityOfService = Thread.current.qualityOfService
        worker.start()
    }

    func value(until deadline: DispatchTime) throws -> Value {
        guard finished.wait(timeout: deadline) == .success else {
            throw SharedCacheScanTestFailure(message: "\(name) did not complete")
        }
        return try result.withLock { $0! }.get()
    }

    func waitForCleanup() {
        if finished.wait(timeout: .now() + 30) != .success {
            Issue.record(
                SharedCacheScanTestFailure(message: "\(name) did not finish during cleanup")
            )
        }
    }
}

private func capturedSources(
    named name: String,
    at address: UInt,
    gate: SharedCacheScanGate? = nil
)
    -> SharedCacheSymbols.CapturedSymbols
{
    SharedCacheSymbols.CapturedSymbols(
        slide: 0,
        readers: [
            { record in
                gate?.read()
                ("_" + name).withCString { record($0, UInt64(address)) }
            }
        ]
    )
}

struct SharedCacheScanTests {
    @Test func wrongKindImageSymbolsDoNotBlockSharedCacheDefinitions() throws {
        let name =
            "SharedKindCollision_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let data = try FixtureLibrary(
            cxxSource: "static int value asm(\"_\(name)\") __attribute__((used)) = 42;"
        )
        let function = try FixtureLibrary()
        defer { data.cleanup(); function.cleanup() }
        let address = try function.address(kind: 0)
        let functionImage = try #require(
            try RuntimeSymbolResolver().images(matching: .path(function.libraryURL)).first
        ).identity
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { image, _, source in
            guard image.identity == functionImage, source == .loaded else { return nil }
            return capturedSources(named: name, at: address)
        })
        let symbol = try resolver.resolve(RuntimeDeclaration(name: name, language: .c))
        #expect(symbol.address == UInt64(address))
        #expect(symbol.source == .sharedCache)
    }

    @Test func malformedSharedCacheAddressesStillFailCrossImageResolution() throws {
        let name = "MalformedAddress_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let malformed = try FixtureLibrary()
        let function = try FixtureLibrary()
        defer { malformed.cleanup(); function.cleanup() }
        let address = try function.address(kind: 0)
        let lookup = RuntimeSymbolResolver()
        let malformedImage = try #require(
            try lookup.images(matching: .path(malformed.libraryURL)).first
        ).identity
        let functionImage = try #require(
            try lookup.images(matching: .path(function.libraryURL)).first
        ).identity
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { image, _, source in
            guard source == .loaded else { return nil }
            if image.identity == malformedImage { return capturedSources(named: name, at: 0) }
            guard image.identity == functionImage else { return nil }
            return capturedSources(named: name, at: address)
        })
        #expect(throws: RuntimeResolutionError.invalidAddress) {
            try resolver.resolve(RuntimeDeclaration(name: name, language: .c))
        }
    }

    @Test func batchLookupTraversesImageSymbolsOnceAndLeavesFallbacksLazy() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let address = UInt64(try fixture.address(kind: 0))
        let reads = Mutex(0)
        let names = [
            "_ABIBatchValue",
            "__ZN5First7Counter3oneEv",
            "__ZN5First7Counter3twoEv",
            "__ZN5First9Different3oneEv",
            "__ZN5First8Fallback3oneEv",
        ]
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { image, _, source in
            guard source == .loaded else { return nil }
            return SharedCacheSymbols.CapturedSymbols(
                slide: 0,
                readers: [
                    { record in
                        reads.withLock { $0 += 1 }
                        for name in names {
                            name.withCString { record($0, address) }
                        }
                    }
                ],
                imageIdentity: image.identity
            )
        })
        let selector = RuntimeImageSelector.path(fixture.libraryURL)
        let fallback = RuntimeDeclaration(name: "First::Fallback::one()", language: .cxx)
        let requests: [RuntimeSymbolRequest] = [
            .init(
                .init(name: "ABIBatchValue", language: .c),
                fallbacks: [fallback],
                in: [selector],
                loading: .loadedOnly
            ),
            .init(
                .init(name: "First::Counter::one()", language: .cxx),
                alternatives: [.init(machOName: "__ZN5First7Counter3oneEv", language: .cxx)],
                in: [selector],
                loading: .loadedOnly
            ),
            .init(
                .init(name: "First::Counter::two()", language: .cxx),
                in: [selector],
                loading: .loadedOnly
            ),
            .init(
                .init(name: "First::Different::one()", language: .cxx),
                in: [selector],
                loading: .loadedOnly
            ),
            .init(
                .init(name: "First::Missing::one()", language: .cxx),
                in: [selector],
                loading: .loadedOnly
            ),
        ]
        let results = resolver.resolve(requests)
        for result in results.dropLast() {
            #expect(try result.get().address == address)
        }
        #expect(throws: RuntimeResolutionError.declarationNotFound(requests.last!.declaration)) {
            try results.last!.get()
        }
        #expect(reads.withLock { $0 } == 1)
        #expect(
            try resolver.resolve(fallback, in: selector, loading: .loadedOnly).address == address
        )
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func concurrentLookupJoinsCapturedScan() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let address = try fixture.address(kind: 0)
        let gate = SharedCacheScanGate()
        let declaration = RuntimeDeclaration(name: "ABIBridgePreparedScanValue", language: .c)
        let selector = RuntimeImageSelector.path(fixture.libraryURL)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, requested, source in
            source == .loaded
                ? capturedSources(named: requested.name, at: address, gate: gate) : nil
        })
        let deadline = DispatchTime.now() + 30
        let prepared = SharedCacheScanWorker("Prepared lookup") {
            try resolver.resolve(declaration, in: selector, loading: .loadedOnly)
        }
        defer { gate.release.signal(); prepared.waitForCleanup() }
        try gate.waitUntilEntered(until: deadline)
        let invoked = SharedCacheScanWorker("Joining lookup") {
            try resolver.resolve(declaration, in: selector, loading: .loadedOnly)
        }
        defer { gate.release.signal(); invoked.waitForCleanup() }
        while !resolver.hasSharedCacheWaiters {
            guard DispatchTime.now() < deadline else {
                throw SharedCacheScanTestFailure(
                    message: "The second lookup did not join the running scan"
                )
            }
            await Task.yield()
        }
        #expect(gate.readCount == 1)
        gate.release.signal()
        #expect(try prepared.value(until: deadline).address == UInt64(address))
        #expect(try invoked.value(until: deadline).address == UInt64(address))
        #expect(gate.readCount == 1)
    }

    @Test func unrelatedLookupDoesNotWaitForWholeBatch() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let address = try fixture.address(kind: 0)
        let gate = SharedCacheScanGate()
        let first = RuntimeDeclaration(name: "ABIBridgeFirstPreparedValue", language: .c)
        let second = RuntimeDeclaration(name: "ABIBridgeSecondPreparedValue", language: .c)
        let selector = RuntimeImageSelector.path(fixture.libraryURL)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, requested, source in
            guard source == .loaded else { return nil }
            return capturedSources(
                named: requested.name,
                at: address,
                gate: requested == first ? gate : nil
            )
        })
        let deadline = DispatchTime.now() + 30
        let prepared = SharedCacheScanWorker("Prepared batch") {
            resolver.resolve(
                [first, second].map {
                    RuntimeSymbolRequest($0, in: [selector], loading: .loadedOnly)
                }
            )
        }
        defer { gate.release.signal(); prepared.waitForCleanup() }
        try gate.waitUntilEntered(until: deadline)
        let invoked = SharedCacheScanWorker("Unrelated lookup") {
            try resolver.resolve(second, in: selector, loading: .loadedOnly)
        }
        defer { gate.release.signal(); invoked.waitForCleanup() }
        #expect(try invoked.value(until: deadline).address == UInt64(address))
        gate.release.signal()
        let results = try prepared.value(until: deadline)
        #expect(results.count == 2)
        for result in results { #expect(try result.get().address == UInt64(address)) }
        #expect(gate.readCount == 1)
    }

    @Test func cacheClearDetachesRunningScan() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let oldAddress = try fixture.address(kind: 1)
        let currentAddress = try fixture.address(kind: 2)
        #expect(oldAddress != currentAddress)
        let gate = SharedCacheScanGate()
        let declaration = RuntimeDeclaration(
            name: "ABIBridgeClearedScanValue",
            language: .c,
            kind: .data
        )
        let selector = RuntimeImageSelector.path(fixture.libraryURL)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, requested, source in
            guard source == .loaded else { return nil }
            return SharedCacheSymbols.CapturedSymbols(
                slide: 0,
                readers: [
                    { record in
                        let read = gate.read()
                        let address = read == 1 ? oldAddress : currentAddress
                        ("_" + requested.name).withCString { record($0, UInt64(address)) }
                    }
                ]
            )
        })
        let deadline = DispatchTime.now() + 30
        let old = SharedCacheScanWorker("Old lookup") {
            try resolver.resolve(declaration, in: selector, loading: .loadedOnly)
        }
        defer { gate.release.signal(); old.waitForCleanup() }
        try gate.waitUntilEntered(until: deadline)
        resolver.removeCachedResults()
        let current = SharedCacheScanWorker("Lookup after cache clear") {
            try resolver.resolve(declaration, in: selector, loading: .loadedOnly)
        }
        defer { gate.release.signal(); current.waitForCleanup() }
        #expect(try current.value(until: deadline).address == UInt64(currentAddress))
        #expect(gate.readCount == 2)
        gate.release.signal()
        #expect(try old.value(until: deadline).address == UInt64(oldAddress))
        #expect(
            try resolver.resolve(declaration, in: selector, loading: .loadedOnly).address
                == UInt64(currentAddress)
        )
        #expect(gate.readCount == 2)
    }

    @Test func sourceCaptureCanReenterResolverAndClearCaches() throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let address = try fixture.address(kind: 0)
        let holder = Mutex<RuntimeSymbolResolver?>(nil)
        let reentered = Mutex<Result<RuntimeSymbol, any Error>?>(nil)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, requested, source in
            guard source == .loaded else { return nil }
            let resolver = holder.withLock { $0! }
            let result = Result {
                try resolver.resolve(RuntimeDeclaration(name: "getpid", language: .c))
            }
            reentered.withLock { $0 = result }
            resolver.removeCachedResults()
            return capturedSources(named: requested.name, at: address)
        })
        holder.withLock { $0 = resolver }
        defer { holder.withLock { $0 = nil } }
        let selector = RuntimeImageSelector.path(fixture.libraryURL)
        let deadline = DispatchTime.now() + 30
        let lookup = SharedCacheScanWorker("Reentrant lookup") {
            try resolver.resolve(
                RuntimeDeclaration(name: "ABIBridgeReentrantScanValue", language: .c),
                in: selector,
                loading: .loadedOnly
            )
        }
        defer { lookup.waitForCleanup() }
        #expect(try lookup.value(until: deadline).address == UInt64(address))
        let result = try #require(reentered.withLock { $0 })
        #expect(try result.get().declaration.name == "getpid")
        resolver.removeCachedResults()
    }
}
#endif
