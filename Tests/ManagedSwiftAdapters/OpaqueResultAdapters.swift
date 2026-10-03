import ManagedSwiftFixtures

@inline(never) public func eraseOpaqueReference(_ token: ErrorLifetimeToken, _ number: Int64) -> Any {
    makeOpaque(token, number)
}
@inline(never) public func copyOpaqueReference(_ token: ErrorLifetimeToken, _ number: Int64) -> (Any, Any) {
    let value = makeOpaque(token, number)
    return (value, value)
}
@inline(never) public func eraseOpaqueIntegerReference(_ number: Int64) -> Any { makeOpaqueInteger(number) }
@inline(never) public func eraseOpaqueEmptyReference() -> Any { makeOpaqueEmpty() }
@inline(never) public func eraseOpaqueThrowingReference(_ token: ErrorLifetimeToken, _ fail: Bool) throws(ScalarFailure) -> Any {
    try makeOpaqueThrowing(token, fail)
}
@inline(never) @concurrent public func eraseOpaqueAsyncReference(_ gate: AsyncGate, _ token: ErrorLifetimeToken, _ fail: Bool) async throws(ScalarFailure) -> any Sendable {
    try await makeOpaqueAsync(gate, token, fail)
}

@inline(never) public func eraseOpaqueClassAnyReference(_ token: ErrorLifetimeToken) -> Any { makeOpaqueClassAny(token) }
@inline(never) public func eraseOpaqueClassProtocolReference(_ token: ErrorLifetimeToken) -> Any { makeOpaqueClassProtocol(token) }
@inline(never) public func eraseOpaqueSuperclassReference(_ token: ErrorLifetimeToken) -> Any { makeOpaqueSuperclass(token) }
@inline(never) public func eraseOpaqueUnconstrainedClassReference(_ token: ErrorLifetimeToken) -> Any { makeOpaqueUnconstrainedClass(token) }
@inline(never) public func eraseOpaqueObjCReference(_ token: ErrorLifetimeToken) -> Any { makeOpaqueObjC(token) }
@inline(never) @concurrent public func eraseOpaqueClassAsyncReference(_ gate: AsyncGate, _ token: ErrorLifetimeToken) async -> any Sendable {
    await makeOpaqueClassAsync(gate, token)
}

#if hasFeature(Lifetimes)
@inline(never) public func readScopedReference(_ owner: RuntimeScopedOwner, _ fail: Bool) throws -> Int64 {
    let result = try makeRuntimeScoped(owner, fail)
    return result.read()
}
@inline(never) public nonisolated(nonsending) func readScopedAsyncReference(_ owner: RuntimeScopedOwner, _ fail: Bool) async throws -> Int64 {
    let result = try await makeRuntimeScopedAsync(owner, fail)
    await Task.yield()
    return result.read()
}
#endif
