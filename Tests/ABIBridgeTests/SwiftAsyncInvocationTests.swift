import ABIBridge
import ManagedSwiftFixtures
import Synchronization
import Testing

extension AsyncMutableRecord: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .int64 }
}

struct SwiftAsyncInvocationTests {
    @Test func functionMetatypesSelectTheNativeIsolationConvention() async throws {
        let runtime = ABIRuntime.shared
        let immediate = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.asyncImmediate(_:)",
            as: (nonisolated(nonsending) (Int64) async -> Int64).self)
        #expect(try unsafe await immediate.unsafeInvoke(41) == 42)
        let suspended = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.asyncConcurrent(_:_:_:)",
            as: (@concurrent (AsyncGate, ErrorLifetimeToken, Int64) async -> String).self)
        let gate = AsyncGate(), token = ErrorLifetimeToken()
        let task = Task { try unsafe await suspended.unsafeInvoke(gate, token, 7) }
        await gate.waitUntilSuspended()
        await gate.open()
        #expect(try await task.value == String(repeating: "value:7", count: 100))
        let inImage = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.asyncImmediate(_:)",
            as: (nonisolated(nonsending) (Int64) async -> Int64).self, in: immediate.symbol.image)
        #expect(try unsafe await inImage.unsafeInvoke(9) == 10)
    }

    @MainActor @Test func callerTaskAndExecutorArePreservedAcrossNativeSuspension() async throws {
        let runtime = ABIRuntime.shared
        let call = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.asyncCaller(_:_:)",
            as: (nonisolated(nonsending) (AsyncGate, Int64) async -> Int64).self)
        let gate = AsyncGate()
        let task = Task { @MainActor in
            try await AsyncTaskValues.$marker.withValue(35) {
                let value = try unsafe await call.unsafeInvoke(gate, 7)
                MainActor.preconditionIsolated()
                return value
            }
        }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await task.value == 42)
        let concurrent = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.asyncConcurrent(_:_:_:)",
            as: (@concurrent (AsyncGate, ErrorLifetimeToken, Int64) async -> String).self)
        let nextGate = AsyncGate(), token = ErrorLifetimeToken()
        let next = Task { @MainActor in
            let value = try unsafe await concurrent.unsafeInvoke(nextGate, token, 7)
            MainActor.preconditionIsolated()
            return value
        }
        await nextGate.waitUntilSuspended(); await nextGate.open()
        #expect(try await next.value == String(repeating: "value:7", count: 100))
    }

    @Test func cancellationIsReportedByTheNativeImplementation() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.asyncUntyped(_:_:_:)",
            as: (@concurrent (AsyncGate, ErrorLifetimeToken, Bool) async throws -> String).self)
        let gate = AsyncGate(), token = ErrorLifetimeToken()
        let task = Task { try unsafe await call.unsafeInvoke(gate, token, false) }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch let error as NativeSwiftError { error.withUnderlyingError { #expect($0 is CancellationError) } }
    }

    @Test func classesActorsAndBoundMethodsUseExplicitReceivers() async throws {
        let runtime = ABIRuntime.shared
        let gate = AsyncGate(), owner = AsyncOwner(ErrorLifetimeToken())
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.AsyncOwner")
        let method = try await type.method(named: "value(_:)", as: (@concurrent (AsyncGate) async -> String).self)
        let task = Task { try unsafe await method.unsafeInvoke(on: owner, gate) }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await task.value == String(repeating: "value:42", count: 100))
        let bound = try await runtime.object(owner).method(named: "value(_:)",
            as: (@concurrent (AsyncGate) async -> String).self)
        let secondGate = AsyncGate()
        let second = Task { try unsafe await bound.unsafeInvoke(secondGate) }
        await secondGate.waitUntilSuspended(); await secondGate.open()
        #expect(try await second.value == String(repeating: "value:42", count: 100))
        let actor = AsyncCounter(35), actorGate = AsyncGate()
        let actorType = try await runtime.swiftType(named: "ManagedSwiftFixtures.AsyncCounter")
        let add = try await actorType.method(named: "add(_:_:)",
            as: (@concurrent (Int64, AsyncGate) async -> Int64).self)
        let added = Task { try unsafe await add.unsafeInvoke(on: actor, 7, actorGate) }
        await actorGate.waitUntilSuspended(); await actorGate.open()
        #expect(try await added.value == 42)
    }

    @Test func initializersGettersAndStaticMembersComposeWithAsync() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.AsyncMemberOwner")
        let initialize = try await type.initializer(named: "init(_:_:_:)",
            as: (@concurrent (ErrorLifetimeToken, AsyncGate, Bool) async throws(ManagedFailure) -> AsyncMemberOwner).self)
        let token = ErrorLifetimeToken()
        let gate = AsyncGate()
        let creation = Task { try unsafe await initialize.unsafeInvoke(token, gate, false) }
        await gate.waitUntilSuspended(); await gate.open()
        let owner = try await creation.value
        #expect(owner.token === token)
        let getter = try await type.getter(named: "delayed", as: (@concurrent () async -> String).self)
        let get = Task { try unsafe await getter.unsafeInvoke(on: owner) }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await get.value == "getter")
        let bound = try await runtime.object(owner).getter(named: "delayed", as: (@concurrent () async -> String).self)
        let boundGet = Task { try unsafe await bound.unsafeInvoke() }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await boundGet.value == "getter")
        let increment = try await type.staticMethod(named: "increment(_:)", as: (@concurrent (Int64) async -> Int64).self)
        #expect(try unsafe await increment.unsafeInvoke(41) == 42)
        let answer = try await type.staticGetter(named: "answer", as: (@concurrent () async -> Int64).self)
        #expect(try unsafe await answer.unsafeInvoke() == 42)
        let failedGate = AsyncGate()
        let failed = Task { try unsafe await initialize.unsafeInvoke(token, failedGate, true) }
        await failedGate.waitUntilSuspended(); await failedGate.open()
        do { _ = try await failed.value; Issue.record("Expected initializer failure") }
        catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? ManagedFailure)?.code == 43) } }
    }

    @Test func mutatingReceiverWritesBackAfterNativeError() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.AsyncMutableRecord", as: AsyncMutableRecord.self)
        let advance = try await type.method(named: "advance(_:_:)",
            as: (nonisolated(nonsending) (AsyncGate, Bool) async throws(ScalarFailure) -> Int64).self, mutating: true)
        let gate = AsyncGate()
        let task = Task {
            var receiver = AsyncMutableRecord(41)
            do { _ = try unsafe await advance.unsafeInvoke(on: &receiver, gate, true); Issue.record("Expected failure") }
            catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) } }
            return receiver.count
        }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await task.value == 42)
    }
}
