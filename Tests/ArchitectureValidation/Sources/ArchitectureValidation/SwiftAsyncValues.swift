import ABIBridge
import SwiftValueFixtures

@MainActor func validateSwiftAsyncValues() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let text = try await runtime.swiftFunction(named: "SwiftValueFixtures.asyncText(_:_:)",
        as: (@concurrent (AsyncValueGate, ErrorToken) async -> String).self)
    let gate = AsyncValueGate(), token = ErrorToken()
    let task = Task { @MainActor in
        let value = try unsafe await text.unsafeInvoke(gate, token)
        MainActor.preconditionIsolated()
        return value
    }
    await gate.waitUntilSuspended(); await gate.open()
    try check(try await task.value == String(repeating: "async", count: 100),
              "Native async completion returns owned String storage to the caller executor")

    let inherited = try await runtime.swiftFunction(named: "SwiftValueFixtures.asyncInherited(_:_:)",
        as: (nonisolated(nonsending) (AsyncValueGate, Int64) async -> Int64).self)
    let inheritedGate = AsyncValueGate()
    let inheritedTask = Task { @MainActor in
        try await AsyncProbeLocal.$value.withValue(35) {
            let value = try unsafe await inherited.unsafeInvoke(inheritedGate, 7)
            MainActor.preconditionIsolated()
            return value
        }
    }
    await inheritedGate.waitUntilSuspended(); await inheritedGate.open()
    try check(try await inheritedTask.value == 42, "Caller-isolation payload and task-local values survive suspension")

    let failing = try await runtime.swiftFunction(named: "SwiftValueFixtures.asyncFailure(_:_:)",
        as: (@concurrent (AsyncValueGate, ErrorToken) async throws -> String).self)
    for cancel in [false, true] {
        let failureGate = AsyncValueGate()
        let failed = Task { try unsafe await failing.unsafeInvoke(failureGate, token) }
        await failureGate.waitUntilSuspended()
        if cancel { failed.cancel() }
        await failureGate.open()
        do {
            _ = try await failed.value
            throw ArchitectureValidationFailure(description: "Expected native failure")
        } catch let error as NativeSwiftError {
            try error.withUnderlyingError {
                if cancel { try check($0 is CancellationError, "Caller cancellation reaches the native Swift task") }
                else { try check(($0 as? IndirectError)?.token === token, "Untyped native async error retains its payload") }
            }
        }
    }

    let large = try await runtime.swiftFunction(named: "SwiftValueFixtures.asyncLarge(_:_:_:)",
        as: (@concurrent (AsyncValueGate, ErrorToken, Bool) async throws(LargeError) -> LargeError).self)
    for fail in [false, true] {
        let largeGate = AsyncValueGate()
        let operation = Task { try unsafe await large.unsafeInvoke(largeGate, token, fail) }
        await largeGate.waitUntilSuspended(); await largeGate.open()
        do {
            let result = try await operation.value
            try check(!fail && result.token === token && result.d == 4, "Async indirect success uses its ordinary output parameter")
        } catch let error as NativeSwiftError {
            try error.withUnderlyingError {
                try check(fail && ($0 as? LargeError)?.token === token, "Async indirect error uses separate owned storage")
            }
        }
    }

    let stack = try await runtime.swiftFunction(named: "SwiftValueFixtures.asyncStack(_:_:_:_:_:_:_:_:_:_:)",
        as: (@concurrent (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) async -> Int64).self)
    try check(try unsafe await stack.unsafeInvoke(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) == 385,
              "Async tail transfer preserves stack arguments")

    let type = try await runtime.swiftType(named: "SwiftValueFixtures.AsyncValueOwner")
    let member = try await type.method(named: "text(_:)", as: (@concurrent (AsyncValueGate) async -> String).self)
    let owner = AsyncValueOwner(token), memberGate = AsyncValueGate()
    let memberTask = Task { try unsafe await member.unsafeInvoke(on: owner, memberGate) }
    await memberGate.waitUntilSuspended(); await memberGate.open()
    try check(try await memberTask.value == String(repeating: "async", count: 100),
              "Async class member preserves its receiver and authenticated context")
    return checks
}
