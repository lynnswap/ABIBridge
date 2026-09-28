import Foundation

public final class ErrorToken: Sendable {
    private let onDestroy: @Sendable () -> Void
    public init(_ onDestroy: @escaping @Sendable () -> Void = {}) { self.onDestroy = onDestroy }
    deinit { onDestroy() }
}
@frozen public struct SmallError: Error {
    public let code: Int64
    public init(_ code: Int64) { self.code = code }
}
@frozen public struct FloatingError: Error {
    public let value: Double
    public init(_ value: Double) { self.value = value }
}
public struct IndirectError: Error {
    public let token: ErrorToken
    public init(_ token: ErrorToken) { self.token = token }
}
@frozen public struct LargeError: Error {
    public let token: ErrorToken
    public let a, b, c, d: Int64
    public init(_ token: ErrorToken) { self.token = token; a = 1; b = 2; c = 3; d = 4 }
}
@inline(never) public func untypedError(_ token: ErrorToken, _ fail: Bool) throws -> String {
    if fail { throw NSError(domain: "DeviceError", code: 42, userInfo: ["token": token]) }
    return String(repeating: "owned", count: 100)
}
@inline(never) public func smallError(_ fail: Bool) throws(SmallError) -> Double {
    if fail { throw SmallError(0) }
    return 1.5
}
@inline(never) public func floatingError(_ fail: Bool) throws(FloatingError) -> Void {
    if fail { throw FloatingError(1.5) }
}
@inline(never) public func indirectError(_ token: ErrorToken, _ fail: Bool) throws(IndirectError) -> String {
    if fail { throw IndirectError(token) }
    return "success"
}
@inline(never) public func largeError(_ token: ErrorToken, _ fail: Bool) throws(LargeError) -> LargeError {
    if fail { throw LargeError(token) }
    return LargeError(token)
}
@frozen public struct ErrorCounter {
    public var count: Int64
    public init(_ count: Int64) { self.count = count }
    @inline(never) public mutating func advance(_ fail: Bool) throws(SmallError) -> Int64 {
        count += 1
        if fail { throw SmallError(count) }
        return count
    }
}
