#if DEBUG
@testable import ABIBridge
import ManagedSwiftFixtures
import Testing

private func implementation(_ declaration: String) async throws -> SwiftAsyncImplementation {
    let runtime = ABIRuntime.shared
    let symbol = try await runtime.resolve(.init(name: declaration, language: .swift))
    let descriptor = try await runtime.resolve(.init(name: "async function pointer to " + declaration,
                                                     language: .swift, kind: .data))
    return try SwiftAsyncImplementation(symbol: symbol, descriptor: descriptor)
}

struct SwiftAsyncTransportTests {
    @Test func immediateNativeAsyncEntryResumesItsSwiftCaller() async throws {
        let entry = try await implementation("ManagedSwiftFixtures.asyncImmediate(Swift.Int64) async -> Swift.Int64")
        let call = try SwiftAsyncCall<Int64, Int64>(inheritsCallerIsolation: true)
        #expect(try unsafe await call.unsafeInvoke(implementation: entry, 41) == 42)
    }

    @Test func suspendedNativeEntryRetainsItsArgumentsAndResult() async throws {
        let entry = try await implementation(
            "ManagedSwiftFixtures.asyncConcurrent(ManagedSwiftFixtures.AsyncGate, ManagedSwiftFixtures.ErrorLifetimeToken, Swift.Int64) async -> Swift.String")
        let call = try SwiftAsyncCall<String, AsyncGate, ErrorLifetimeToken, Int64>(inheritsCallerIsolation: false)
        let gate = AsyncGate(), token = ErrorLifetimeToken()
        let task = Task { try unsafe await call.unsafeInvoke(implementation: entry, gate, token, 42) }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(try await task.value == String(repeating: "value:42", count: 100))
    }

    @MainActor @Test func callerIsolationPayloadSurvivesAnActorHop() async throws {
        let entry = try await implementation(
            "ManagedSwiftFixtures.asyncCaller(ManagedSwiftFixtures.AsyncGate, Swift.Int64) async -> Swift.Int64")
        let call = try SwiftAsyncCall<Int64, AsyncGate, Int64>(inheritsCallerIsolation: true)
        let gate = AsyncGate()
        let task = Task { @MainActor in
            try await AsyncTaskValues.$marker.withValue(35) {
                let result = try unsafe await call.unsafeInvoke(implementation: entry, gate, 7)
                MainActor.preconditionIsolated()
                return result
            }
        }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(try await task.value == 42)
    }

    @MainActor @Test func concurrentCalleeReturnsToTheCallerExecutor() async throws {
        let entry = try await implementation(
            "ManagedSwiftFixtures.asyncConcurrent(ManagedSwiftFixtures.AsyncGate, ManagedSwiftFixtures.ErrorLifetimeToken, Swift.Int64) async -> Swift.String")
        let call = try SwiftAsyncCall<String, AsyncGate, ErrorLifetimeToken, Int64>(inheritsCallerIsolation: false)
        let gate = AsyncGate(), token = ErrorLifetimeToken()
        let task = Task { @MainActor in
            let result = try unsafe await call.unsafeInvoke(implementation: entry, gate, token, 7)
            MainActor.preconditionIsolated()
            return result
        }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(try await task.value == String(repeating: "value:7", count: 100))
    }

    @Test func asyncTailTransferHandlesStackArguments() async throws {
        let types = Array(repeating: "Swift.Int64", count: 10) + Array(repeating: "Swift.Double", count: 10)
        let entry = try await implementation("ManagedSwiftFixtures.asyncMany(" + types.joined(separator: ", ") + ") async -> Swift.Double")
        let call = try SwiftAsyncCall<Double, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64,
                                      Double, Double, Double, Double, Double, Double, Double, Double, Double, Double>(
            inheritsCallerIsolation: false)
        #expect(try unsafe await call.unsafeInvoke(implementation: entry,
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5) == 577.5)
    }

    @Test func indirectAsyncResultAndErrorUseOrdinaryParameters() async throws {
        let entry = try await implementation(
            "ManagedSwiftFixtures.asyncBothIndirect(ManagedSwiftFixtures.AsyncGate, ManagedSwiftFixtures.ErrorLifetimeToken, Swift.Bool) async throws(ManagedSwiftFixtures.LargeFailure) -> ManagedSwiftFixtures.ErrorSuccessPayload")
        let call = try SwiftAsyncCall<ErrorSuccessPayload, AsyncGate, ErrorLifetimeToken, Bool>(
            errorPlan: SwiftErrorPlan.make(LargeFailure.self), inheritsCallerIsolation: false)
        let token = ErrorLifetimeToken()
        for fail in [false, true] {
            let gate = AsyncGate()
            let task = Task { try unsafe await call.unsafeInvoke(implementation: entry, gate, token, fail) }
            await gate.waitUntilSuspended()
            await gate.open()
            do {
                let result = try await task.value
                #expect(!fail && result.token === token && result.d == 40)
            } catch let error as NativeSwiftError {
                error.withUnderlyingError { #expect(fail && ($0 as? LargeFailure)?.token === token) }
            }
        }
    }

    @Test func callerCancellationReachesTheNativeTask() async throws {
        let entry = try await implementation(
            "ManagedSwiftFixtures.asyncUntyped(ManagedSwiftFixtures.AsyncGate, ManagedSwiftFixtures.ErrorLifetimeToken, Swift.Bool) async throws -> Swift.String")
        let call = try SwiftAsyncCall<String, AsyncGate, ErrorLifetimeToken, Bool>(
            errorPlan: SwiftErrorPlan.make((any Error).self), inheritsCallerIsolation: false)
        let gate = AsyncGate(), token = ErrorLifetimeToken()
        let task = Task { try unsafe await call.unsafeInvoke(implementation: entry, gate, token, false) }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            Issue.record("Expected native cancellation")
        } catch let error as NativeSwiftError {
            error.withUnderlyingError { #expect($0 is CancellationError) }
        }
    }

    @Test func nativeAsyncErrorsUseTheCompletionContextRegister() async throws {
        let declaration = "ManagedSwiftFixtures.asyncTyped(ManagedSwiftFixtures.AsyncGate, ManagedSwiftFixtures.ErrorLifetimeToken, Swift.Bool) async throws(ManagedSwiftFixtures.ManagedFailure) -> Swift.String"
        let entry = try await implementation(declaration)
        let call = try SwiftAsyncCall<String, AsyncGate, ErrorLifetimeToken, Bool>(
            errorPlan: SwiftErrorPlan.make(ManagedFailure.self), inheritsCallerIsolation: false)
        let gate = AsyncGate(), token = ErrorLifetimeToken()
        let task = Task { try unsafe await call.unsafeInvoke(implementation: entry, gate, token, true) }
        await gate.waitUntilSuspended()
        await gate.open()
        do {
            _ = try await task.value
            Issue.record("Expected native failure")
        } catch let error as NativeSwiftError {
            error.withUnderlyingError { #expect(($0 as? ManagedFailure)?.code == 42) }
        }
    }
}
#endif
