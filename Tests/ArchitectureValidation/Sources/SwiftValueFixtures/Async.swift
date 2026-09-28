public actor AsyncValueGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func wait() async {
        await withCheckedContinuation {
            waiters.append($0)
            let ready = observers
            observers.removeAll()
            for observer in ready { observer.resume() }
        }
    }
    public func waitUntilSuspended() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { observers.append($0) }
    }
    public func open() {
        let ready = waiters
        waiters.removeAll()
        for waiter in ready { waiter.resume() }
    }
}
public enum AsyncProbeLocal { @TaskLocal public static var value: Int64 = 0 }

@concurrent public func asyncText(_ gate: AsyncValueGate, _ token: ErrorToken) async -> String {
    await gate.wait()
    return withExtendedLifetime(token) { String(repeating: "async", count: 100) }
}
nonisolated(nonsending) public func asyncInherited(_ gate: AsyncValueGate, _ value: Int64) async -> Int64 {
    await gate.wait()
    return value + AsyncProbeLocal.value
}
@concurrent public func asyncFailure(_ gate: AsyncValueGate, _ token: ErrorToken) async throws -> String {
    await gate.wait()
    try Task.checkCancellation()
    throw IndirectError(token)
}
@concurrent public func asyncLarge(_ gate: AsyncValueGate, _ token: ErrorToken, _ fail: Bool) async throws(LargeError) -> LargeError {
    await gate.wait()
    if fail { throw LargeError(token) }
    return LargeError(token)
}
@concurrent public func asyncStack(
    _ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ e: Int64,
    _ f: Int64, _ g: Int64, _ h: Int64, _ i: Int64, _ j: Int64
) async -> Int64 {
    await Task.yield()
    return a + 2*b + 3*c + 4*d + 5*e + 6*f + 7*g + 8*h + 9*i + 10*j
}
public final class AsyncValueOwner: Sendable {
    public let token: ErrorToken
    public init(_ token: ErrorToken) { self.token = token }
    @concurrent public func text(_ gate: AsyncValueGate) async -> String { await asyncText(gate, token) }
}
