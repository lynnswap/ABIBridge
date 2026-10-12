import ABIBridgeCore
@testable import ABIBridgeRuntime
import Foundation
import Synchronization
import Testing

private enum CallInterfacePreparationFailure: Error, Equatable {
    case failedBuild
    case timedOut
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

    func build() throws -> PreparedInterface {
        builds.withLock { $0 += 1 }
        entered.signal()
        guard release.wait(timeout: .now() + 5) == .success else {
            throw CallInterfacePreparationFailure.timedOut
        }
        return PreparedInterface(42)
    }

    func waitUntilEntered() throws {
        guard entered.wait(timeout: .now() + 5) == .success else {
            throw CallInterfacePreparationFailure.timedOut
        }
    }
}

private final class CallInterfaceWorker<Value: Sendable>: Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let result = Mutex<Result<Value, any Error>?>(nil)

    init(_ operation: @escaping @Sendable () throws -> Value) {
        let worker = Thread { [self] in
            started.signal()
            let value = Result { try operation() }
            result.withLock { $0 = value }
            finished.signal()
        }
        worker.qualityOfService = .userInitiated
        worker.start()
    }

    func waitUntilStarted() throws {
        guard started.wait(timeout: .now() + 5) == .success else {
            throw CallInterfacePreparationFailure.timedOut
        }
    }

    func value() throws -> Value {
        guard finished.wait(timeout: .now() + 5) == .success else {
            throw CallInterfacePreparationFailure.timedOut
        }
        return try result.withLock { $0! }.get()
    }
}

struct CallInterfacePreparationTests {
    @Test func synchronousDemandSharesTheRunningNativePreparation() throws {
        let integer = try RuntimeValueType(scalar: ABIValueInt64)
        let key = RuntimeCallInterfaceKey(result: integer, parameters: [integer])
        let cache = RuntimeCallInterfaceCache<PreparedInterface>()
        let gate = CallInterfaceBuildGate()
        defer { gate.release.signal() }
        let preparation = CallInterfaceWorker {
            try cache.interface(for: key) { try gate.build() }
        }
        try gate.waitUntilEntered()
        let demand = CallInterfaceWorker {
            try cache.interface(for: key) {
                gate.builds.withLock { $0 += 1 }
                return PreparedInterface(-1)
            }
        }
        try demand.waitUntilStarted()

        // An unrelated signature remains available while this build is held.
        let unrelated = try cache.interface(
            for: RuntimeCallInterfaceKey(result: integer, parameters: [])
        ) { PreparedInterface(7) }
        #expect(unrelated.value == 7)
        gate.release.signal()
        let prepared = try preparation.value()
        let requested = try demand.value()
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
        let eviction = CallInterfaceWorker {
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
        try eviction.value()
        let result = try #require(reentered.withLock { $0 })
        #expect(try result.get() == 1)
    }

}
