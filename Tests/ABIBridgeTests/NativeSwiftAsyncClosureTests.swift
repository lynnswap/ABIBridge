#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ABIBridgeCore
import ManagedSwiftFixtures
import Darwin
import Testing

private nonisolated(nonsending) func concurrentClosureBody(_ gate: AsyncGate, _ value: Int64) async -> String {
    #expect(#isolation == nil)
    await gate.wait()
    #expect(#isolation == nil)
    return "value:\(value + AsyncTaskValues.marker)"
}
private nonisolated(nonsending) func callerClosureBody(_ gate: AsyncGate, _ value: Int64) async -> Int64 {
    MainActor.preconditionIsolated()
    await gate.wait()
    MainActor.preconditionIsolated()
    return value + AsyncTaskValues.marker
}

private nonisolated(nonsending) func nativeAsyncClosureError<Value>(_ body: () async throws -> Value) async throws -> NativeSwiftError {
    do { _ = try await body(); throw ABIResolutionError.unsupportedDeclaration("Expected native async closure error") }
    catch let error as NativeSwiftError { return error }
}

private nonisolated(nonsending) func isOnMainThread() async -> Bool { pthread_main_np() != 0 }
private final class AsyncCallbackCapture: Sendable {}

struct NativeSwiftAsyncClosureTests {
    @MainActor @Test func directConcurrentCallbackUsesTheDefaultGenericExecutor() async throws {
        let body: @Sendable () async -> Bool = isOnMainThread
        let concurrent = try NativeSwiftConcurrentClosure<Bool, Never>(body)
        #expect(try unsafe await concurrent.unsafeInvoke() == false)
        MainActor.preconditionIsolated()
        let caller = try NativeSwiftAsyncClosure<Bool, Never>(body)
        #expect(try unsafe await caller.unsafeInvoke() == true)
    }

#if DEBUG
    @Test func implicitActorAuthenticationMatchesCompilerLowering() {
        #expect(swiftClosureDiscriminator(parameters: ["-class", "$ss5Int64V"], result: "$ss5Int64V") == 51173)
        #expect(swiftClosureDiscriminator(parameters: ["-class"], result: "-indirect") == 51264)
        #expect(swiftClosureDiscriminator(parameters: [], result: "-indirect") == 29199)
    }

    @Test func rejectedDescriptorsReleaseTheirOwnedNativeContext() throws {
        let codec = try NativeSwiftConcurrentClosure<Void, Never>.makeClosureCodec()
        let discriminator = swiftClosureDiscriminator(parameters: [], result: nil)
        for missing in [false, true] {
            weak var observed: AsyncCallbackCapture?
            do {
                let capture = AsyncCallbackCapture()
                observed = capture
                var descriptor: (Int32, UInt32) = (0, 1)
                try withUnsafePointer(to: &descriptor) { address in
                    let pointer = missing ? nil : ABISignSwiftAsyncClosureDescriptor(address, discriminator)
                    let value = ABISwiftClosureValue(function: pointer, context: Unmanaged.passRetained(capture).toOpaque())
                    do { _ = try codec.makeValue(value, nil, true); Issue.record("Expected rejected descriptor") }
                    catch {}
                }
            }
            #expect(observed == nil)
        }
    }
#endif

    @Test func escapedErrorsDoNotKeepUnrelatedAsyncCapturesAlive() async throws {
        weak var observed: AsyncCallbackCapture?
        var failure: NativeSwiftError?
        do {
            let capture = AsyncCallbackCapture()
            observed = capture
            let body: @Sendable () async throws(ScalarFailure) -> Int64 = { () async throws(ScalarFailure) in
                await Task.yield()
                withExtendedLifetime(capture) {}
                throw ScalarFailure(42)
            }
            let callback = try NativeSwiftConcurrentClosure<Int64, ScalarFailure>(body)
            failure = try await nativeAsyncClosureError { try unsafe await callback.unsafeInvoke() }
        }
        withExtendedLifetime(failure) { #expect(observed == nil) }
        failure?.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) }
    }


    @Test func compilerCallerPassesRegistersAndStackArguments() async throws {
        typealias Many = NativeSwiftConcurrentClosure<Double, Never,
            Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64,
            Double, Double, Double, Double, Double, Double, Double, Double, Double, Double>
        let callback = try Many(asyncMany)
        let apply = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.applyManyAsyncClosure(_:)",
            as: (@concurrent (Many) async -> Double).self)
        #expect(try unsafe await apply.unsafeInvoke(callback) == 577.5)
    }

    @Test func returnedTypedClosureObservesCancellationOnTheOriginalTask() async throws {
        let factory = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeTypedAsyncClosure(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftConcurrentClosure<String, ManagedFailure, AsyncGate, Bool>).self)
        let token = ErrorLifetimeToken(), gate = AsyncGate()
        let task = Task {
            let callback = try unsafe factory.unsafeInvoke(token)
            return try unsafe await callback.unsafeInvoke(gate, false)
        }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.open()
        let failure = try await nativeAsyncClosureError { try await task.value }
        failure.withUnderlyingError { #expect(($0 as? ManagedFailure)?.code == -1 && ($0 as? ManagedFailure)?.token === token) }
    }

    @MainActor @Test func returnedCallerClosureKeepsItsNativeIsolation() async throws {
        let factory = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeCallerAsyncClosure(_: ManagedSwiftFixtures.ErrorLifetimeToken, expectMainActor: Swift.Bool) -> nonisolated(nonsending) @Sendable (ManagedSwiftFixtures.AsyncGate, Swift.Int64) async -> Swift.Int64",
            as: ((ErrorLifetimeToken, Bool) -> NativeSwiftAsyncClosure<Int64, Never, AsyncGate, Int64>).self)
        let gate = AsyncGate()
        let task = Task { @MainActor in
            let callback = try unsafe factory.unsafeInvoke(ErrorLifetimeToken(), true)
            return try await AsyncTaskValues.$marker.withValue(35) {
                try unsafe await callback.unsafeInvoke(gate, 7)
            }
        }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(try await task.value == 42)
    }

    @Test func repeatedHandoffsAndEscapingNativeStorageReleaseCaptures() async throws {
        typealias Callback = NativeSwiftConcurrentClosure<String, Never, AsyncGate, Int64>
        let runtime = ABIRuntime.shared
        let factory = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeConcurrentAsyncClosure(_:)",
            as: ((ErrorLifetimeToken) -> Callback).self)
        let identity = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.handoffAsyncClosure(_:)",
            as: ((Callback) -> Callback).self)
        let retain = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.retainAsyncClosure(_:)",
            as: ((Callback) -> StoredAsyncClosure).self)
        weak var observed: ErrorLifetimeToken?
        var stored: StoredAsyncClosure?
        do {
            let token = ErrorLifetimeToken()
            observed = token
            var callback = try unsafe factory.unsafeInvoke(token)
            for _ in 0..<5 { callback = try unsafe identity.unsafeInvoke(callback) }
            stored = try unsafe retain.unsafeInvoke(callback)
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


    @Test func generatedCallbacksReturnTypedAndUntypedErrors() async throws {
        let zero: @Sendable () async throws(ScalarFailure) -> Void = { () async throws(ScalarFailure) in
            await Task.yield()
            throw ScalarFailure(0)
        }
        let callback = try NativeSwiftConcurrentClosure<Void, ScalarFailure>(zero)
        let failure = try await nativeAsyncClosureError { try unsafe await callback.unsafeInvoke() }
        failure.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 0) }

        let token = ErrorLifetimeToken()
        let untyped: @Sendable (Bool) async throws -> String = { fail in
            await Task.yield()
            if fail { throw ManagedFailure(token, 43) }
            return "success"
        }
        let ordinary = try NativeSwiftAsyncClosure<String, any Error, Bool>(untyped)
        #expect(try unsafe await ordinary.unsafeInvoke(false) == "success")
        let nativeError = try await nativeAsyncClosureError { try unsafe await ordinary.unsafeInvoke(true) }
        nativeError.withUnderlyingError { #expect(($0 as? ManagedFailure)?.token === token) }
    }

    @Test func nativeTypedCallerReceivesTheOriginalError() async throws {
        let apply = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.applyTypedAsyncClosure(_:_:_:)",
            as: (@concurrent (NativeSwiftConcurrentClosure<String, ManagedFailure, AsyncGate, Bool>, AsyncGate, Bool) async throws(ManagedFailure) -> String).self)
        let token = ErrorLifetimeToken()
        let gate = AsyncGate()
        let task = Task {
            let body: @Sendable (AsyncGate, Bool) async throws(ManagedFailure) -> String = {
                (gate: AsyncGate, fail: Bool) async throws(ManagedFailure) in
                await gate.wait()
                if fail { throw ManagedFailure(token, 44) }
                return "success"
            }
            let callback = try NativeSwiftConcurrentClosure<String, ManagedFailure, AsyncGate, Bool>(body)
            return try unsafe await apply.unsafeInvoke(callback, gate, true)
        }
        await gate.waitUntilSuspended()
        await gate.open()
        let failure = try await nativeAsyncClosureError { try await task.value }
        failure.withUnderlyingError { #expect(($0 as? ManagedFailure)?.code == 44 && ($0 as? ManagedFailure)?.token === token) }
    }

    @Test func indirectCallbackResultsAndErrorsRemainIndependent() async throws {
        let token = ErrorLifetimeToken()
        let body: @Sendable (Bool) async throws(LargeFailure) -> ErrorSuccessPayload = {
            (fail: Bool) async throws(LargeFailure) in
            await Task.yield()
            if fail { throw LargeFailure(token) }
            return ErrorSuccessPayload(token)
        }
        let callback = try NativeSwiftAsyncClosure<ErrorSuccessPayload, LargeFailure, Bool>(body)
        let result = try unsafe await callback.unsafeInvoke(false)
        #expect(result.token === token && result.d == 40)
        let failure = try await nativeAsyncClosureError { try unsafe await callback.unsafeInvoke(true) }
        failure.withUnderlyingError { #expect(($0 as? LargeFailure)?.token === token && ($0 as? LargeFailure)?.d == 4) }
    }

    @Test func managedCollectionsAndEmptyValuesSurviveSuspension() async throws {
        let body: @Sendable ([String]?) async -> [String]? = { value in
            await Task.yield()
            return value.map { $0 + ["callback"] }
        }
        let callback = try NativeSwiftConcurrentClosure<[String]?, Never, [String]?>(body)
        #expect(try unsafe await callback.unsafeInvoke(nil) == nil)
        #expect(try unsafe await callback.unsafeInvoke(["input"]) == ["input", "callback"])
        let empty: @Sendable (Void) async -> Void = { _ in await Task.yield() }
        try unsafe await NativeSwiftAsyncClosure<Void, Never, Void>(empty).unsafeInvoke(())
    }


    @MainActor @Test func nativeConcurrentCallPreservesTaskLocalsAndRestoresItsCaller() async throws {
        let apply = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.applyConcurrentAsyncClosure(_:_:_:)",
            as: (@concurrent (NativeSwiftConcurrentClosure<String, Never, AsyncGate, Int64>, AsyncGate, Int64) async -> String).self)
        let gate = AsyncGate()
        let task = Task { @MainActor in
            let callback = try NativeSwiftConcurrentClosure<String, Never, AsyncGate, Int64>(concurrentClosureBody)
            return try await AsyncTaskValues.$marker.withValue(35) {
                let value = try unsafe await apply.unsafeInvoke(callback, gate, 7)
                MainActor.preconditionIsolated()
                return value
            }
        }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(try await task.value == "value:42")
    }

    @MainActor @Test func nativeCallerIsolatedCallPreservesItsExecutor() async throws {
        let apply = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.applyCallerAsyncClosure(_:_:_:)",
            as: (nonisolated(nonsending) (NativeSwiftAsyncClosure<Int64, Never, AsyncGate, Int64>, AsyncGate, Int64) async -> Int64).self)
        let gate = AsyncGate()
        let task = Task { @MainActor in
            let callback = try NativeSwiftAsyncClosure<Int64, Never, AsyncGate, Int64>(callerClosureBody)
            return try await AsyncTaskValues.$marker.withValue(35) {
                try unsafe await apply.unsafeInvoke(callback, gate, 7)
            }
        }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(try await task.value == 42)
    }

    @Test func returnedConcurrentClosureRetainsItsCaptureAcrossSuspension() async throws {
        let factory = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeConcurrentAsyncClosure(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftConcurrentClosure<String, Never, AsyncGate, Int64>).self)
        let gate = AsyncGate()
        weak var observed: ErrorLifetimeToken?
        let task: Task<String, any Error>
        do {
            let token = ErrorLifetimeToken()
            observed = token
            task = Task {
                let callback = try unsafe factory.unsafeInvoke(token)
                return try unsafe await callback.unsafeInvoke(gate, 42)
            }
        }
        await gate.waitUntilSuspended()
        #expect(observed != nil)
        await gate.open()
        #expect(try await task.value == String(repeating: "closure:42", count: 100))
        #expect(observed == nil)
    }

    @Test func generatedConcurrentAndCallerClosuresReturnNativeValues() async throws {
        let addSeven: @Sendable (Int64) async -> Int64 = { $0 + 7 }
        let addEight: @Sendable (Int64) async -> Int64 = { $0 + 8 }
        let concurrent = try NativeSwiftConcurrentClosure<Int64, Never, Int64>(addSeven)
        #expect(try unsafe await concurrent.unsafeInvoke(35) == 42)
        let caller = try NativeSwiftAsyncClosure<Int64, Never, Int64>(addEight)
        #expect(try unsafe await caller.unsafeInvoke(35) == 43)
    }
}
