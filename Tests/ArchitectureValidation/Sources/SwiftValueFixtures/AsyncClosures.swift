public typealias ConcurrentValueClosure = @Sendable @concurrent (AsyncValueGate, Int64) async -> String
public typealias CallerValueClosure = (nonisolated(nonsending) @Sendable (AsyncValueGate, Int64) async -> Int64)
public typealias SmallAsyncClosure = @Sendable @concurrent (Int64) async throws(SmallError) -> Int64
public typealias LargeAsyncClosure = @Sendable @concurrent (ErrorToken, Bool) async throws(LargeError) -> LargeError
public typealias StackAsyncClosure = @Sendable @concurrent (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) async -> Int64

@concurrent public func applyConcurrentValueClosure(_ body: ConcurrentValueClosure, _ gate: AsyncValueGate, _ value: Int64) async -> String {
    await body(gate, value)
}
nonisolated(nonsending) public func applyCallerValueClosure(_ body: CallerValueClosure, _ gate: AsyncValueGate, _ value: Int64) async -> Int64 {
    await body(gate, value)
}
@concurrent public func applySmallAsyncClosure(_ body: SmallAsyncClosure, _ value: Int64) async throws(SmallError) -> Int64 {
    try await body(value)
}
@concurrent public func applyLargeAsyncClosure(_ body: LargeAsyncClosure, _ token: ErrorToken, _ fail: Bool) async throws(LargeError) -> LargeError {
    try await body(token, fail)
}
@concurrent public func applyStackAsyncClosure(_ body: StackAsyncClosure) async -> Int64 {
    await body(1,2,3,4,5,6,7,8,9,10)
}
public func makeConcurrentValueClosure(_ token: ErrorToken) -> ConcurrentValueClosure {
    { gate, value in
        await gate.wait()
        return withExtendedLifetime(token) { "native:\(value)" }
    }
}
public func makeCallerValueClosure(_ token: ErrorToken) -> CallerValueClosure {
    { gate, value in
        MainActor.preconditionIsolated()
        await gate.wait()
        MainActor.preconditionIsolated()
        return withExtendedLifetime(token) { value + AsyncProbeLocal.value }
    }
}
public func handoffConcurrentValueClosure(_ body: @escaping ConcurrentValueClosure) -> ConcurrentValueClosure { body }
public final class AsyncClosureHolder: Sendable {
    public let body: ConcurrentValueClosure
    public init(_ body: @escaping ConcurrentValueClosure) { self.body = body }
}
public func retainConcurrentValueClosure(_ body: @escaping ConcurrentValueClosure) -> AsyncClosureHolder { AsyncClosureHolder(body) }
