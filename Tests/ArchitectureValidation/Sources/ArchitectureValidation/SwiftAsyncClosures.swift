import ABIBridge
import SwiftValueFixtures
import Darwin

private nonisolated(nonsending) func concurrentValueBody(_ gate: AsyncValueGate, _ value: Int64) async -> String {
    let isConcurrent = pthread_main_np() == 0
    await gate.wait()
    return isConcurrent ? "value:\(value + AsyncProbeLocal.value)" : "wrong isolation"
}
private nonisolated(nonsending) func inheritedValueBody(_ gate: AsyncValueGate, _ value: Int64) async -> Int64 {
    MainActor.preconditionIsolated()
    await gate.wait()
    MainActor.preconditionIsolated()
    return value + AsyncProbeLocal.value
}

@MainActor func validateSwiftAsyncClosures() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    typealias Concurrent = NativeSwiftClosure<@Sendable @concurrent (AsyncValueGate, Int64) async -> String>
    typealias Caller = NativeSwiftClosure<nonisolated(nonsending) @Sendable (AsyncValueGate, Int64) async -> Int64>
    let concurrent = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyConcurrentValueClosure(_:_:_:)",
        as: (@concurrent (Concurrent, AsyncValueGate, Int64) async -> String).self)
    let gate = AsyncValueGate()
    let operation = Task { @MainActor in
        let callback = try Concurrent(concurrentValueBody)
        return try await AsyncProbeLocal.$value.withValue(35) {
            let value = try unsafe await concurrent.unsafeInvoke(callback, gate, 7)
            MainActor.preconditionIsolated()
            return value
        }
    }
    await gate.waitUntilSuspended(); await gate.open()
    try check(try await operation.value == "value:42", "Concurrent callback preserves task locals and restores the caller executor")

    let caller = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyCallerValueClosure(_:_:_:)",
        as: (nonisolated(nonsending) (Caller, AsyncValueGate, Int64) async -> Int64).self)
    let callerGate = AsyncValueGate()
    let inherited = Task { @MainActor in
        let callback = try Caller(inheritedValueBody)
        return try await AsyncProbeLocal.$value.withValue(35) {
            try unsafe await caller.unsafeInvoke(callback, callerGate, 7)
        }
    }
    await callerGate.waitUntilSuspended(); await callerGate.open()
    try check(try await inherited.value == 42, "Caller-isolated callback retains native isolation across suspension")

    let small = try await runtime.swiftFunction(named: "SwiftValueFixtures.applySmallAsyncClosure(_:_:)",
        as: (@concurrent (NativeSwiftClosure<@Sendable @concurrent (Int64) async throws(SmallError) -> Int64>, Int64) async throws(SmallError) -> Int64).self)
    let smallBody: @Sendable (Int64) async throws(SmallError) -> Int64 = { (value: Int64) async throws(SmallError) in
        await Task.yield()
        if value < 0 { throw SmallError(0) }
        return value + 7
    }
    let callback = try NativeSwiftClosure<@Sendable @concurrent (Int64) async throws(SmallError) -> Int64>(smallBody)
    try check(try unsafe await small.unsafeInvoke(callback, 35) == 42, "Compiler caller invokes an authenticated async throwing callback")
    do {
        _ = try unsafe await small.unsafeInvoke(callback, -1)
        throw ArchitectureValidationFailure(description: "Expected typed async callback error")
    } catch let error as NativeSwiftError {
        try error.withUnderlyingError { try check(($0 as? SmallError)?.code == 0, "Zero-valued async callback errors preserve the native error indicator") }
    }

    let large = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyLargeAsyncClosure(_:_:_:)",
        as: (@concurrent (NativeSwiftClosure<@Sendable @concurrent (ErrorToken, Bool) async throws(LargeError) -> LargeError>, ErrorToken, Bool) async throws(LargeError) -> LargeError).self)
    let largeBody: @Sendable (ErrorToken, Bool) async throws(LargeError) -> LargeError = { (token: ErrorToken, fail: Bool) async throws(LargeError) in
        await Task.yield()
        if fail { throw LargeError(token) }
        return LargeError(token)
    }
    let largeCallback = try NativeSwiftClosure<@Sendable @concurrent (ErrorToken, Bool) async throws(LargeError) -> LargeError>(largeBody)
    let token = ErrorToken()
    let result = try unsafe await large.unsafeInvoke(largeCallback, token, false)
    try check(result.token === token && result.d == 4, "Async callback returns an owned indirect value")
    do {
        _ = try unsafe await large.unsafeInvoke(largeCallback, token, true)
        throw ArchitectureValidationFailure(description: "Expected indirect callback error")
    } catch let error as NativeSwiftError {
        try error.withUnderlyingError { try check(($0 as? LargeError)?.token === token, "Async callback errors use independent indirect storage") }
    }

    typealias Stack = NativeSwiftClosure<@Sendable @concurrent (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) async -> Int64>
    let stack = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyStackAsyncClosure(_:)",
        as: (@concurrent (Stack) async -> Int64).self)
    try check(try unsafe await stack.unsafeInvoke(Stack(asyncStack)) == 385, "Async callback cleans up native stack arguments before suspension")

    let make = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeConcurrentValueClosure(_:)",
        as: ((ErrorToken) -> Concurrent).self)
    let identity = try await runtime.swiftFunction(named: "SwiftValueFixtures.handoffConcurrentValueClosure(_:)",
        as: ((Concurrent) -> Concurrent).self)
    let retain = try await runtime.swiftFunction(named: "SwiftValueFixtures.retainConcurrentValueClosure(_:)",
        as: ((Concurrent) -> AsyncClosureHolder).self)
    weak var observed: ErrorToken?
    var stored: AsyncClosureHolder?
    do {
        let token = ErrorToken()
        observed = token
        var returned = try unsafe make.unsafeInvoke(token)
        for _ in 0..<5 { returned = try unsafe identity.unsafeInvoke(returned) }
        stored = try unsafe retain.unsafeInvoke(returned)
    }
    try check(observed != nil, "Native escaping copies retain async captures after repeated handoffs")
    let nativeGate = AsyncValueGate()
    let native: Task<String, Never>
    do { let owner = stored!; native = Task { await owner.body(nativeGate, 42) } }
    await nativeGate.waitUntilSuspended(); await nativeGate.open()
    try check(await native.value == "native:42", "Returned async closures authenticate and complete through native storage")
    stored = nil
    try check(observed == nil, "Final async closure release destroys the native capture")

    let inheritedFactory = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeCallerValueClosure(_:)",
        as: ((ErrorToken) -> Caller).self)
    let inheritedGate = AsyncValueGate()
    let returnedCaller = Task { @MainActor in
        let value = try unsafe inheritedFactory.unsafeInvoke(ErrorToken())
        return try await AsyncProbeLocal.$value.withValue(35) {
            try unsafe await value.unsafeInvoke(inheritedGate, 7)
        }
    }
    await inheritedGate.waitUntilSuspended(); await inheritedGate.open()
    try check(try await returnedCaller.value == 42, "Returned caller-isolated descriptor preserves its distinct authentication and hidden arguments")

    let cancellationGate = AsyncValueGate()
    let cancelled = Task {
        let body: @Sendable (AsyncValueGate) async throws -> Void = { gate in
            await gate.wait()
            try Task.checkCancellation()
        }
        let value = try NativeSwiftClosure<@Sendable @concurrent (AsyncValueGate) async throws -> Void>(body)
        try unsafe await value.unsafeInvoke(cancellationGate)
    }
    await cancellationGate.waitUntilSuspended(); cancelled.cancel(); await cancellationGate.open()
    do {
        try await cancelled.value
        throw ArchitectureValidationFailure(description: "Expected callback cancellation")
    } catch let error as NativeSwiftError {
        try error.withUnderlyingError { try check($0 is CancellationError, "Generated async callback observes cancellation of the original task") }
    }
    return checks
}
