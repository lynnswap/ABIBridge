import ManagedSwiftAdapters
import ManagedSwiftFixtures
import Testing

struct SwiftAsyncClosureABITests {
    @Test func returnedCapturesSurviveSuspensionAndReleaseAfterCompletion() async throws {
        let gate = AsyncGate()
        weak var observed: ErrorLifetimeToken?
        let task: Task<String, Never>
        do {
            let token = ErrorLifetimeToken()
            observed = token
            let body = makeConcurrentAsyncClosure(token)
            task = Task { await compiledConcurrentAsyncClosure(body, gate, 42) }
        }
        await gate.waitUntilSuspended()
        #expect(observed != nil)
        await gate.open()
        #expect(await task.value == String(repeating: "closure:42", count: 100))
        #expect(observed == nil)
    }

    @MainActor @Test func callerIsolationAndTaskLocalsReachTheClosure() async throws {
        let gate = AsyncGate()
        let body = makeCallerAsyncClosure(ErrorLifetimeToken(), expectMainActor: true)
        let task = Task { @MainActor in
            await AsyncTaskValues.$marker.withValue(35) {
                await compiledCallerAsyncClosure(body, gate, 7)
            }
        }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(await task.value == 42)
    }

    @Test func typedAndUntypedClosureErrorsPreserveTheirPayloads() async throws {
        let token = ErrorLifetimeToken()
        for typed in [false, true] {
            let gate = AsyncGate()
            let task = Task {
                if typed { return try await compiledTypedAsyncClosure(makeTypedAsyncClosure(token), gate, true) }
                return try await compiledUntypedAsyncClosure(makeUntypedAsyncClosure(token), gate, true)
            }
            await gate.waitUntilSuspended()
            await gate.open()
            do { _ = try await task.value; Issue.record("Expected closure error") }
            catch let failure as ManagedFailure {
                #expect(failure.token === token && failure.code == (typed ? 42 : 43))
            }
        }
    }

    @Test func cancellationUsesTheOriginalTask() async throws {
        let token = ErrorLifetimeToken()
        for typed in [false, true] {
            let gate = AsyncGate()
            let task = Task {
                if typed { return try await compiledTypedAsyncClosure(makeTypedAsyncClosure(token), gate, false) }
                return try await compiledUntypedAsyncClosure(makeUntypedAsyncClosure(token), gate, false)
            }
            await gate.waitUntilSuspended()
            task.cancel()
            await gate.open()
            do { _ = try await task.value; Issue.record("Expected cooperative cancellation") }
            catch let error as ManagedFailure { #expect(typed && error.code == -1 && error.token === token) }
            catch is CancellationError { #expect(!typed) }
        }
    }

    @Test func indirectResultsAndErrorsUseIndependentStorage() async throws {
        let token = ErrorLifetimeToken()
        let body = makeIndirectAsyncClosure(token)
        for fail in [false, true] {
            let gate = AsyncGate()
            let task = Task { try await compiledIndirectAsyncClosure(body, gate, fail) }
            await gate.waitUntilSuspended()
            await gate.open()
            do {
                let result = try await task.value
                #expect(!fail && result.token === token && result.d == 40)
            } catch let error as LargeFailure { #expect(fail && error.token === token && error.d == 4) }
        }
    }

    @Test func nativeEscapingStorageOwnsAsyncCaptures() async throws {
        weak var observed: ErrorLifetimeToken?
        var stored: StoredAsyncClosure?
        do {
            let token = ErrorLifetimeToken()
            observed = token
            stored = retainAsyncClosure(makeConcurrentAsyncClosure(token))
        }
        #expect(observed != nil)
        let gate = AsyncGate()
        let task: Task<String, Never>
        do {
            let owner = stored!
            task = Task { await owner.body(gate, 42) }
        }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(await task.value == String(repeating: "closure:42", count: 100))
        stored = nil
        #expect(observed == nil)
    }
}
