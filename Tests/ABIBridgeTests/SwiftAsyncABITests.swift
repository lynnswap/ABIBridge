import ABIBridge
import ManagedSwiftAdapters
import ManagedSwiftFixtures
import Synchronization
import Testing

private final class AsyncDestructionCount: Sendable {
    let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

struct SwiftAsyncABITests {
    @Test func immediateAndSuspendedCallsHaveCompilerManagedCompletion() async throws {
        #expect(await compiledAsyncImmediate(41) == 42)
        let gate = AsyncGate(), token = ErrorLifetimeToken()
        let task = Task { await compiledAsyncConcurrent(gate, token, 42) }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(await task.value == String(repeating: "value:42", count: 100))
    }

    @MainActor @Test func callerIsolationAndTaskLocalsSurviveSuspension() async throws {
        let gate = AsyncGate()
        let task = Task { @MainActor in
            await AsyncTaskValues.$marker.withValue(35) {
                await compiledAsyncCaller(gate, 7)
            }
        }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(await task.value == 42)
        let mainGate = AsyncGate()
        let main = Task { await compiledAsyncMainActor(mainGate) }
        await mainGate.waitUntilSuspended()
        await mainGate.open()
        #expect(await main.value)
    }

    @Test func receiverAndArgumentsRemainAliveUntilCompletion() async throws {
        let destroyed = AsyncDestructionCount()
        let gate = AsyncGate()
        weak var observed: AsyncOwner?
        weak var observedToken: ErrorLifetimeToken?
        let task: Task<String, Never>
        do {
            let token = ErrorLifetimeToken { destroyed.increment() }
            let owner = AsyncOwner(token)
            observed = owner; observedToken = token
            task = Task { await compiledAsyncMember(owner, gate) }
        }
        await gate.waitUntilSuspended()
        #expect(observed != nil && observedToken != nil && destroyed.value == 0)
        await gate.open()
        #expect(await task.value == String(repeating: "value:42", count: 100))
        #expect(observed == nil && observedToken == nil && destroyed.value == 1)
    }

    @Test func typedAndUntypedErrorsKeepTheirOwnedPayloads() async throws {
        for typed in [false, true] {
            let destroyed = AsyncDestructionCount()
            let gate = AsyncGate()
            weak var observed: ErrorLifetimeToken?
            var result: Result<String, any Error>?
            do {
                let token = ErrorLifetimeToken { destroyed.increment() }
                observed = token
                let task = Task {
                    if typed { return try await compiledAsyncTyped(gate, token, true) }
                    return try await compiledAsyncUntyped(gate, token, true)
                }
                await gate.waitUntilSuspended()
                #expect(observed != nil && destroyed.value == 0)
                await gate.open()
                result = await task.result
                if case .failure(let error) = result {
                    let actual = try #require(error as? ManagedFailure)
                    #expect(actual.token === token && actual.code == 42)
                } else { Issue.record("Expected native error") }
            }
            withExtendedLifetime(result) { #expect(observed != nil && destroyed.value == 0) }
            result = nil
            #expect(observed == nil && destroyed.value == 1)
        }
    }

    @Test func cancellationRemainsCooperativeUntilNativeCompletion() async throws {
        let gate = AsyncGate(), token = ErrorLifetimeToken()
        let task = Task { try await compiledAsyncUntyped(gate, token, false) }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            Issue.record("Native cancellation should be preserved")
        } catch is CancellationError {}
        let typedGate = AsyncGate()
        let typed = Task { try await compiledAsyncTyped(typedGate, token, false) }
        await typedGate.waitUntilSuspended()
        typed.cancel()
        await typedGate.open()
        do {
            _ = try await typed.value
            Issue.record("The native typed error decides cancellation behavior")
        } catch let error as ManagedFailure { #expect(error.code == -1 && error.token === token) }
    }

    @Test func independentIndirectOutputsAndFloatingErrorsArePreserved() async throws {
        let token = ErrorLifetimeToken()
        for fail in [false, true] {
            let gate = AsyncGate()
            let task = Task { try await compiledAsyncBothIndirect(gate, token, fail) }
            await gate.waitUntilSuspended()
            await gate.open()
            do {
                let result = try await task.value
                #expect(!fail && result.token === token && result.a == 10 && result.d == 40)
            } catch let error as LargeFailure { #expect(fail && error.token === token && error.d == 4) }
            let floatingGate = AsyncGate()
            let floating = Task { try await compiledAsyncFloatingError(floatingGate, fail) }
            await floatingGate.waitUntilSuspended()
            await floatingGate.open()
            do { #expect(try await floating.value == 2.5 && !fail) }
            catch let error as FloatingFailure { #expect(fail && error.value == 1.5) }
        }
    }

    @Test func mixedRegistersAndStackArgumentsSurviveSuspension() async {
        #expect(await compiledAsyncMany() == 577.5)
    }

    @Test func actorMemberResumesOnItsExecutor() async throws {
        let gate = AsyncGate(), owner = AsyncCounter(35)
        let task = Task { await compiledAsyncActor(owner, 7, gate) }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(await task.value == 42)
    }

    @Test func asyncDescriptorsResolveBySourceName() async throws {
        let runtime = ABIRuntime.shared
        for (name, signature) in [
            ("asyncImmediate", "(Swift.Int64) async -> Swift.Int64"),
            ("asyncCaller", "(ManagedSwiftFixtures.AsyncGate, Swift.Int64) async -> Swift.Int64")
        ] {
            let declaration = "ManagedSwiftFixtures." + name + signature
            let descriptor = try await runtime.resolve(.init(
                name: "async function pointer to " + declaration, language: .swift, kind: .data))
            let function = try await runtime.resolve(.init(name: declaration, language: .swift))
            let fields = unsafe descriptor.withUnsafeAddress { address in
                (UInt(bitPattern: address), address.load(as: Int32.self),
                 address.load(fromByteOffset: 4, as: UInt32.self))
            }
            #expect(fields.2 >= 2 * MemoryLayout<UnsafeRawPointer>.size)
            let entry = Int64(fields.0) + Int64(fields.1)
            let expected = unsafe function.withUnsafeAddress { UInt(bitPattern: $0) }
            #expect(UInt64(entry) == UInt64(expected))
        }
    }
}
