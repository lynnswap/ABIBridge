import ManagedSwiftFixtures

@inline(never) @concurrent
public func compiledConcurrentAsyncClosure(_ body: ConcurrentAsyncClosure, _ gate: AsyncGate, _ value: Int64) async -> String {
    await applyConcurrentAsyncClosure(body, gate, value)
}
@inline(never) nonisolated(nonsending)
public func compiledCallerAsyncClosure(_ body: CallerAsyncClosure, _ gate: AsyncGate, _ value: Int64) async -> Int64 {
    await applyCallerAsyncClosure(body, gate, value)
}
@inline(never) @concurrent
public func compiledTypedAsyncClosure(_ body: TypedAsyncClosure, _ gate: AsyncGate, _ fail: Bool) async throws(ManagedFailure) -> String {
    try await applyTypedAsyncClosure(body, gate, fail)
}
@inline(never) @concurrent
public func compiledUntypedAsyncClosure(_ body: UntypedAsyncClosure, _ gate: AsyncGate, _ fail: Bool) async throws -> String {
    try await applyUntypedAsyncClosure(body, gate, fail)
}
@inline(never) @concurrent
public func compiledIndirectAsyncClosure(_ body: IndirectAsyncClosure, _ gate: AsyncGate, _ fail: Bool) async throws(LargeFailure) -> ErrorSuccessPayload {
    try await applyIndirectAsyncClosure(body, gate, fail)
}
