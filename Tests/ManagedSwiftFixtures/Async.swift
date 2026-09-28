public actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    public init() {}

    public func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
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

public enum AsyncTaskValues {
    @TaskLocal public static var marker: Int64 = 0
}

@inline(never) nonisolated(nonsending)
public func asyncImmediate(_ value: Int64) async -> Int64 { value + 1 }

@inline(never) @concurrent
public func asyncConcurrent(_ gate: AsyncGate, _ token: ErrorLifetimeToken, _ value: Int64) async -> String {
    await gate.wait()
    return withExtendedLifetime(token) { String(repeating: "value:\(value)", count: 100) }
}

@inline(never) nonisolated(nonsending)
public func asyncCaller(_ gate: AsyncGate, _ value: Int64) async -> Int64 {
    await gate.wait()
    return value + AsyncTaskValues.marker
}

@inline(never) @MainActor
public func asyncMainActor(_ gate: AsyncGate) async -> Bool {
    MainActor.preconditionIsolated()
    await gate.wait()
    MainActor.preconditionIsolated()
    return true
}

@inline(never) @concurrent
public func asyncUntyped(_ gate: AsyncGate, _ token: ErrorLifetimeToken, _ fail: Bool) async throws -> String {
    await gate.wait()
    try Task.checkCancellation()
    if fail { throw ManagedFailure(token, 42) }
    return withExtendedLifetime(token) { String(repeating: "success", count: 100) }
}

@inline(never) @concurrent
public func asyncTyped(_ gate: AsyncGate, _ token: ErrorLifetimeToken, _ fail: Bool) async throws(ManagedFailure) -> String {
    await gate.wait()
    if fail || Task.isCancelled { throw ManagedFailure(token, Task.isCancelled ? -1 : 42) }
    return withExtendedLifetime(token) { String(repeating: "success", count: 100) }
}

@inline(never) @concurrent
public func asyncBothIndirect(
    _ gate: AsyncGate, _ token: ErrorLifetimeToken, _ fail: Bool
) async throws(LargeFailure) -> ErrorSuccessPayload {
    await gate.wait()
    if fail { throw LargeFailure(token) }
    return ErrorSuccessPayload(token)
}

@inline(never) @concurrent
public func asyncFloatingError(_ gate: AsyncGate, _ fail: Bool) async throws(FloatingFailure) -> Double {
    await gate.wait()
    if fail { throw FloatingFailure(1.5) }
    return 2.5
}

@inline(never) @concurrent
public func asyncMany(
    _ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ e: Int64,
    _ f: Int64, _ g: Int64, _ h: Int64, _ i: Int64, _ j: Int64,
    _ k: Double, _ l: Double, _ m: Double, _ n: Double, _ o: Double,
    _ p: Double, _ q: Double, _ r: Double, _ s: Double, _ t: Double
) async -> Double {
    await Task.yield()
    let integers = a + 2*b + 3*c + 4*d + 5*e + 6*f + 7*g + 8*h + 9*i + 10*j
    let floating = k + 2*l + 3*m + 4*n + 5*o + 6*p + 7*q + 8*r + 9*s + 10*t
    return Double(integers) + floating
}

public final class AsyncOwner: Sendable {
    public let token: ErrorLifetimeToken
    public init(_ token: ErrorLifetimeToken) { self.token = token }
    @inline(never) @concurrent public func value(_ gate: AsyncGate) async -> String {
        await asyncConcurrent(gate, token, 42)
    }
}

public actor AsyncCounter {
    private var value: Int64
    public init(_ value: Int64) { self.value = value }
    @inline(never) public func add(_ delta: Int64, _ gate: AsyncGate) async -> Int64 {
        await gate.wait()
        value += delta
        return value
    }
}
