import ABIBridgeCore
@testable import ABIBridgeRuntime
import Foundation
import Synchronization
import Testing

private enum CallInterfacePreparationFailure: Error, Equatable {
    case failedBuild
    case timedOut(String)
}

private final class PreparedInterface: Sendable {
    let value: Int
    private let onRelease: (@Sendable () -> Void)?
    init(_ value: Int, onRelease: (@Sendable () -> Void)? = nil) {
        self.value = value
        self.onRelease = onRelease
    }
    deinit { onRelease?() }
}

private final class CallInterfaceBuildGate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let builds = Mutex(0)

    func build() -> PreparedInterface {
        builds.withLock { $0 += 1 }
        entered.signal()
        release.wait()
        return PreparedInterface(42)
    }

    func waitUntilEntered(until deadline: DispatchTime) throws {
        guard entered.wait(timeout: deadline) == .success else {
            throw CallInterfacePreparationFailure.timedOut("entering preparation build")
        }
    }
}

private final class CallInterfaceWorker<Value: Sendable>: Sendable {
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

    func waitForCompletion(until deadline: DispatchTime) throws {
        guard finished.wait(timeout: deadline) == .success else {
            throw CallInterfacePreparationFailure.timedOut("completing \(name)")
        }
    }

    func value(until deadline: DispatchTime) throws -> Value {
        try waitForCompletion(until: deadline)
        return try result.withLock { $0! }.get()
    }
}

struct CallInterfacePreparationTests {
    @Test func synchronousDemandSharesTheRunningNativePreparation() throws {
        let integer = try RuntimeValueType(scalar: ABIValueInt64)
        let key = RuntimeCallInterfaceKey(result: integer, parameters: [integer])
        #if DEBUG
        let joined = DispatchSemaphore(value: 0)
        let cache = RuntimeCallInterfaceCache<PreparedInterface>(
            beforeWaitingForPreparation: { joined.signal() }
        )
        #else
        let cache = RuntimeCallInterfaceCache<PreparedInterface>()
        #endif
        let gate = CallInterfaceBuildGate()
        let deadline = DispatchTime.now() + 30
        var workers: [CallInterfaceWorker<PreparedInterface>] = []
        defer {
            gate.release.signal()
            let cleanupDeadline = DispatchTime.now() + 30
            for worker in workers {
                do {
                    try worker.waitForCompletion(until: cleanupDeadline)
                } catch {
                    Issue.record(error, "Worker did not finish after releasing the build gate")
                }
            }
        }
        let preparation = CallInterfaceWorker("preparation") {
            try cache.interface(for: key) { gate.build() }
        }
        workers.append(preparation)
        try gate.waitUntilEntered(until: deadline)
        let demand = CallInterfaceWorker("demand") {
            try cache.interface(for: key) {
                gate.builds.withLock { $0 += 1 }
                return PreparedInterface(-1)
            }
        }
        workers.append(demand)
        #if DEBUG
        guard joined.wait(timeout: deadline) == .success else {
            throw CallInterfacePreparationFailure.timedOut("joining the running preparation")
        }
        #endif

        // An unrelated signature remains available while this build is held.
        let unrelatedLookup = CallInterfaceWorker("unrelated lookup") {
            try cache.interface(
                for: RuntimeCallInterfaceKey(result: integer, parameters: [])
            ) { PreparedInterface(7) }
        }
        workers.append(unrelatedLookup)
        let unrelated = try unrelatedLookup.value(until: deadline)
        #expect(unrelated.value == 7)
        gate.release.signal()
        let prepared = try preparation.value(until: deadline)
        let requested = try demand.value(until: deadline)
        #expect(prepared === requested)
        #expect(requested.value == 42)
        #expect(gate.builds.withLock { $0 } == 1)
    }

    @Test func failedPreparationPreservesTheErrorAndAllowsRetry() throws {
        let integer = try RuntimeValueType(scalar: ABIValueInt64)
        let key = RuntimeCallInterfaceKey(result: integer, parameters: [integer])
        let cache = RuntimeCallInterfaceCache<PreparedInterface>()
        var builds = 0
        #expect(throws: CallInterfacePreparationFailure.failedBuild) {
            try cache.interface(for: key) {
                builds += 1
                throw CallInterfacePreparationFailure.failedBuild
            }
        }
        let recovered = try cache.interface(for: key) {
            builds += 1
            return PreparedInterface(42)
        }
        let repeated = try cache.interface(for: key) {
            builds += 1
            return PreparedInterface(-1)
        }
        #expect(recovered === repeated)
        #expect(repeated.value == 42)
        #expect(builds == 2)
    }

    @Test func finishedEntriesAreBoundedAndEvictedHandlesRemainUsable() throws {
        let integer = try RuntimeValueType(scalar: ABIValueInt64)
        let cache = RuntimeCallInterfaceCache<PreparedInterface>()
        let originalKey = RuntimeCallInterfaceKey(result: integer, parameters: [])
        let original = try cache.interface(for: originalKey) { PreparedInterface(42) }
        weak var evicted: PreparedInterface?
        do {
            let entry = try cache.interface(
                for: RuntimeCallInterfaceKey(result: integer, parameters: [integer])
            ) { PreparedInterface(1) }
            evicted = entry
        }
        #expect(evicted != nil)
        for count in 2...65 {
            _ = try cache.interface(
                for: RuntimeCallInterfaceKey(
                    result: integer,
                    parameters: Array(repeating: integer, count: count)
                )
            ) { PreparedInterface(count) }
        }
        #expect(evicted == nil)
        #expect(original.value == 42)
        let rebuilt = try cache.interface(for: originalKey) { PreparedInterface(43) }
        #expect(rebuilt !== original)
        #expect(rebuilt.value == 43)
        let recent = try cache.interface(
            for: RuntimeCallInterfaceKey(
                result: integer,
                parameters: Array(repeating: integer, count: 65)
            )
        ) { PreparedInterface(-1) }
        #expect(recent.value == 65)
    }

    @Test func evictionReleasesNativeOwnersOutsideTheCacheLock() throws {
        let integer = try RuntimeValueType(scalar: ABIValueInt64)
        let cache = RuntimeCallInterfaceCache<PreparedInterface>()
        let reentered = Mutex<Result<Int, any Error>?>(nil)
        let originalKey = RuntimeCallInterfaceKey(result: integer, parameters: [])
        let nestedKey = RuntimeCallInterfaceKey(result: integer, parameters: [integer])
        let eviction = CallInterfaceWorker("eviction") {
            _ = try cache.interface(for: originalKey) {
                PreparedInterface(
                    42,
                    onRelease: {
                        let result = Result {
                            try cache.interface(for: nestedKey) { PreparedInterface(-1) }.value
                        }
                        reentered.withLock { $0 = result }
                    }
                )
            }
            for count in 1...64 {
                _ = try cache.interface(
                    for: RuntimeCallInterfaceKey(
                        result: integer,
                        parameters: Array(repeating: integer, count: count)
                    )
                ) { PreparedInterface(count) }
            }
        }
        try eviction.value(until: .now() + 30)
        let result = try #require(reentered.withLock { $0 })
        #expect(try result.get() == 1)
    }

}
