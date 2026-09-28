@inline(never) public func handoffScalarThrowing(_ body: @escaping () throws(ScalarFailure) -> Int64) -> () throws(ScalarFailure) -> Int64 { body }

public typealias UntypedThrowingClosure = (Bool) throws -> String
public typealias TypedThrowingClosure = (Bool) throws(ManagedFailure) -> String
public typealias LargeThrowingClosure = (ErrorLifetimeToken, Bool) throws(LargeFailure) -> ErrorSuccessPayload
public typealias FloatingThrowingClosure = (Bool) throws(FloatingFailure) -> Double

@inline(never) public func applyUntypedThrowing(_ body: UntypedThrowingClosure, _ fail: Bool) throws -> String {
    try body(fail)
}
@inline(never) public func applyTypedThrowing(_ body: TypedThrowingClosure, _ fail: Bool) throws(ManagedFailure) -> String {
    try body(fail)
}
@inline(never) public func catchTypedThrowing(_ body: TypedThrowingClosure) -> Int64 {
    do { _ = try body(true); return -1 }
    catch { return error.code }
}
@inline(never) public func applyLargeThrowing(
    _ body: LargeThrowingClosure, _ token: ErrorLifetimeToken, _ fail: Bool
) throws(LargeFailure) -> ErrorSuccessPayload { try body(token, fail) }
@inline(never) public func applyFloatingThrowing(_ body: FloatingThrowingClosure, _ fail: Bool) throws(FloatingFailure) -> Double {
    try body(fail)
}

@inline(never) public func makeTypedThrowing(_ token: ErrorLifetimeToken) -> TypedThrowingClosure {
    { (fail: Bool) throws(ManagedFailure) -> String in
        if fail { throw ManagedFailure(token, 42) }
        return withExtendedLifetime(token) { String(repeating: "returned", count: 100) }
    }
}
@inline(never) public func makeUntypedThrowing(_ token: ErrorLifetimeToken) -> UntypedThrowingClosure {
    { fail in
        if fail { throw ManagedFailure(token, 43) }
        return withExtendedLifetime(token) { String(repeating: "returned", count: 100) }
    }
}
public final class StoredThrowingClosure {
    private let body: TypedThrowingClosure
    public init(_ body: @escaping TypedThrowingClosure) { self.body = body }
    public func value(_ fail: Bool) throws(ManagedFailure) -> String { try body(fail) }
}
@inline(never) public func retainTypedThrowing(_ body: @escaping TypedThrowingClosure) -> StoredThrowingClosure {
    StoredThrowingClosure(body)
}
