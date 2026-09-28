public typealias ConcurrentAsyncClosure = @Sendable @concurrent (AsyncGate, Int64) async -> String
public typealias CallerAsyncClosure = (nonisolated(nonsending) @Sendable (AsyncGate, Int64) async -> Int64)
public typealias TypedAsyncClosure = @Sendable @concurrent (AsyncGate, Bool) async throws(ManagedFailure) -> String
public typealias UntypedAsyncClosure = @Sendable @concurrent (AsyncGate, Bool) async throws -> String
public typealias IndirectAsyncClosure = @Sendable @concurrent (AsyncGate, Bool) async throws(LargeFailure) -> ErrorSuccessPayload

@inline(never) public func makeConcurrentAsyncClosure(_ token: ErrorLifetimeToken) -> ConcurrentAsyncClosure {
    { gate, value in
        await gate.wait()
        return withExtendedLifetime(token) { String(repeating: "closure:\(value)", count: 100) }
    }
}

@inline(never) public func makeCallerAsyncClosure(_ token: ErrorLifetimeToken, expectMainActor: Bool) -> CallerAsyncClosure {
    { gate, value in
        if expectMainActor { MainActor.preconditionIsolated() }
        await gate.wait()
        if expectMainActor { MainActor.preconditionIsolated() }
        return withExtendedLifetime(token) { value + AsyncTaskValues.marker }
    }
}

@inline(never) public func makeTypedAsyncClosure(_ token: ErrorLifetimeToken) -> TypedAsyncClosure {
    { (gate: AsyncGate, fail: Bool) async throws(ManagedFailure) in
        await gate.wait()
        if fail || Task.isCancelled { throw ManagedFailure(token, Task.isCancelled ? -1 : 42) }
        return "typed callback"
    }
}

@inline(never) public func makeUntypedAsyncClosure(_ token: ErrorLifetimeToken) -> UntypedAsyncClosure {
    { gate, fail in
        await gate.wait()
        try Task.checkCancellation()
        if fail { throw ManagedFailure(token, 43) }
        return "untyped callback"
    }
}

@inline(never) public func makeIndirectAsyncClosure(_ token: ErrorLifetimeToken) -> IndirectAsyncClosure {
    { (gate: AsyncGate, fail: Bool) async throws(LargeFailure) in
        await gate.wait()
        if fail { throw LargeFailure(token) }
        return ErrorSuccessPayload(token)
    }
}

@inline(never) @concurrent
public func applyConcurrentAsyncClosure(_ body: ConcurrentAsyncClosure, _ gate: AsyncGate, _ value: Int64) async -> String {
    await body(gate, value)
}

@inline(never) nonisolated(nonsending)
public func applyCallerAsyncClosure(_ body: CallerAsyncClosure, _ gate: AsyncGate, _ value: Int64) async -> Int64 {
    await body(gate, value)
}

@inline(never) @concurrent
public func applyTypedAsyncClosure(_ body: TypedAsyncClosure, _ gate: AsyncGate, _ fail: Bool) async throws(ManagedFailure) -> String {
    try await body(gate, fail)
}

@inline(never) @concurrent
public func applyUntypedAsyncClosure(_ body: UntypedAsyncClosure, _ gate: AsyncGate, _ fail: Bool) async throws -> String {
    try await body(gate, fail)
}

@inline(never) @concurrent
public func applyIndirectAsyncClosure(_ body: IndirectAsyncClosure, _ gate: AsyncGate, _ fail: Bool) async throws(LargeFailure) -> ErrorSuccessPayload {
    try await body(gate, fail)
}

public final class StoredAsyncClosure: Sendable {
    public let body: ConcurrentAsyncClosure
    public init(_ body: @escaping ConcurrentAsyncClosure) { self.body = body }
}

@inline(never) public func retainAsyncClosure(_ body: @escaping ConcurrentAsyncClosure) -> StoredAsyncClosure {
    StoredAsyncClosure(body)
}
