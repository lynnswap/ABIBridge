import ManagedSwiftFixtures

// These independently compiled callers let Swift own the async context,
// executor transitions, and result/error transfer. They are reference calls
// for comparison with the dynamic frontend, not blocking C wrappers.
@inline(never) nonisolated(nonsending)
public func compiledAsyncImmediate(_ value: Int64) async -> Int64 {
    await asyncImmediate(value)
}
@inline(never) @concurrent
public func compiledAsyncConcurrent(_ gate: AsyncGate, _ token: ErrorLifetimeToken, _ value: Int64) async -> String {
    await asyncConcurrent(gate, token, value)
}
@inline(never) nonisolated(nonsending)
public func compiledAsyncCaller(_ gate: AsyncGate, _ value: Int64) async -> Int64 {
    await asyncCaller(gate, value)
}
@inline(never) @MainActor
public func compiledAsyncMainActor(_ gate: AsyncGate) async -> Bool {
    await asyncMainActor(gate)
}
@inline(never) @concurrent
public func compiledAsyncUntyped(_ gate: AsyncGate, _ token: ErrorLifetimeToken, _ fail: Bool) async throws -> String {
    try await asyncUntyped(gate, token, fail)
}
@inline(never) @concurrent
public func compiledAsyncTyped(_ gate: AsyncGate, _ token: ErrorLifetimeToken, _ fail: Bool) async throws(ManagedFailure) -> String {
    try await asyncTyped(gate, token, fail)
}
@inline(never) @concurrent
public func compiledAsyncBothIndirect(
    _ gate: AsyncGate, _ token: ErrorLifetimeToken, _ fail: Bool
) async throws(LargeFailure) -> ErrorSuccessPayload {
    try await asyncBothIndirect(gate, token, fail)
}
@inline(never) @concurrent
public func compiledAsyncFloatingError(_ gate: AsyncGate, _ fail: Bool) async throws(FloatingFailure) -> Double {
    try await asyncFloatingError(gate, fail)
}
@inline(never) @concurrent
public func compiledAsyncMany() async -> Double {
    await asyncMany(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5)
}
@inline(never) @concurrent
public func compiledAsyncMember(_ owner: AsyncOwner, _ gate: AsyncGate) async -> String {
    await owner.value(gate)
}
@inline(never) @concurrent
public func compiledAsyncActor(_ owner: AsyncCounter, _ delta: Int64, _ gate: AsyncGate) async -> Int64 {
    await owner.add(delta, gate)
}
