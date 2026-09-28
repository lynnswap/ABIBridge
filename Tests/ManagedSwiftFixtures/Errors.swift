import Foundation

public final class ErrorLifetimeToken: Sendable {
    private let onDestroy: @Sendable () -> Void
    public init(onDestroy: @escaping @Sendable () -> Void = {}) { self.onDestroy = onDestroy }
    deinit { onDestroy() }
}

@frozen public struct ScalarFailure: Error {
    public let code: Int64
    public init(_ code: Int64) { self.code = code }
}
@frozen public struct FloatingFailure: Error {
    public let value: Double
    public init(_ value: Double) { self.value = value }
}
@frozen public struct ManagedFailure: Error {
    public let token: ErrorLifetimeToken
    public let code: Int64
    public init(_ token: ErrorLifetimeToken, _ code: Int64) { self.token = token; self.code = code }
}
@frozen public struct LargeFailure: Error {
    public let token: ErrorLifetimeToken
    public let a, b, c, d: Int64
    public init(_ token: ErrorLifetimeToken) { self.token = token; a = 1; b = 2; c = 3; d = 4 }
}
public struct ResilientFailure: Error {
    private let payload: ManagedFailure
    public init(_ token: ErrorLifetimeToken, _ code: Int64) { payload = ManagedFailure(token, code) }
    public var token: ErrorLifetimeToken { payload.token }
    public var code: Int64 { payload.code }
}
public final class ReferenceFailure: Error {
    public let token: ErrorLifetimeToken
    public let code: Int64
    public init(_ token: ErrorLifetimeToken, _ code: Int64) { self.token = token; self.code = code }
}

@inline(never) public func untypedResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws -> String {
    if fail { throw ManagedFailure(token, 42) }
    return String(repeating: "success", count: 100)
}
@inline(never) public func scalarErrorResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws(ScalarFailure) -> String {
    if fail { throw ScalarFailure(0) }
    return String(repeating: "success", count: 100)
}
@inline(never) public func floatingErrorResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws(FloatingFailure) -> String {
    if fail { throw FloatingFailure(1.5) }
    return String(repeating: "success", count: 100)
}
@inline(never) public func scalarErrorFloatingResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws(ScalarFailure) -> Double {
    if fail { throw ScalarFailure(42) }
    return 1.5
}
@inline(never) public func scalarErrorVoidResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws(ScalarFailure) {
    if fail { throw ScalarFailure(42) }
}

@inline(never) public func managedErrorResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws(ManagedFailure) -> String {
    if fail { throw ManagedFailure(token, 42) }
    return String(repeating: "success", count: 100)
}
@inline(never) public func largeErrorResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws(LargeFailure) -> String {
    if fail { throw LargeFailure(token) }
    return String(repeating: "success", count: 100)
}
@inline(never) public func resilientErrorResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws(ResilientFailure) -> String {
    if fail { throw ResilientFailure(token, 42) }
    return String(repeating: "success", count: 100)
}
@inline(never) public func referenceErrorResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws(ReferenceFailure) -> String {
    if fail { throw ReferenceFailure(token, 42) }
    return String(repeating: "success", count: 100)
}

@frozen public struct ErrorSuccessPayload: Sendable {
    public let token: ErrorLifetimeToken
    public let a, b, c, d: Int64
    public init(_ token: ErrorLifetimeToken) { self.token = token; a = 10; b = 20; c = 30; d = 40 }
}
@inline(never) public func bothIndirectResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws(LargeFailure) -> ErrorSuccessPayload {
    if fail { throw LargeFailure(token) }
    return ErrorSuccessPayload(token)
}
@inline(never) public func cocoaErrorResult(_ token: ErrorLifetimeToken, _ fail: Bool) throws -> String {
    if fail { throw NSError(domain: "ABIFixture", code: 42, userInfo: ["token": token]) }
    return String(repeating: "success", count: 100)
}

@frozen public struct ThrowingCounter {
    public var count: Int64
    public init(_ count: Int64) { self.count = count }
    @inline(never) public mutating func advance(_ fail: Bool) throws(ScalarFailure) -> Int64 {
        count += 1
        if fail { throw ScalarFailure(count) }
        return count
    }
    public var rejected: Int64 { get throws(ScalarFailure) { throw ScalarFailure(count) } }
    public static var rejected: Int64 { get throws(ScalarFailure) { throw ScalarFailure(99) } }
    @inline(never) public static func result(_ fail: Bool) throws(ScalarFailure) -> Int8 {
        if fail { throw ScalarFailure(42) }
        return 7
    }
}

@inline(never) public func stackedErrorResult(
    _ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ e: Int64, _ f: Int64, _ g: Int64, _ h: Int64,
    _ token: ErrorLifetimeToken, _ fail: Bool
) throws(LargeFailure) -> Int64 {
    if fail { throw LargeFailure(token) }
    return a + b + c + d + e + f + g + h
}

public final class ThrowingOwner {
    public let token: ErrorLifetimeToken
    public init(_ token: ErrorLifetimeToken, _ fail: Bool) throws(ManagedFailure) {
        if fail { throw ManagedFailure(token, 43) }
        self.token = token
    }
    @inline(never) public func value(_ fail: Bool) throws(ManagedFailure) -> String {
        if fail { throw ManagedFailure(token, 44) }
        return String(repeating: "member", count: 100)
    }
}
