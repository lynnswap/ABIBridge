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
