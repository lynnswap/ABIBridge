import CoreGraphics

public final class EvaluatedIntegerClosure {
    public let value: Int64
    @inline(never) public init(_ body: (Int64) -> Int64) { value = body(35) }
}

@inline(never) public func visitOwnedNestedClosure(
    _ closure: @escaping (Int64) -> Int64,
    _ body: (@escaping (Int64) -> Int64) throws -> Int64
) rethrows -> Int64 {
    let result = try body(closure)
    return result + closure(1)
}

@inline(never) public func echoClosureValue(_ callback: @escaping (Int64) -> Int64) -> (Int64) -> Int64 { callback }

public final class ClosureValueHolder {
    private let callback: (Int64) -> Int64
    init(_ callback: @escaping (Int64) -> Int64) { self.callback = callback }
    public func callAsFunction(_ value: Int64) -> Int64 { callback(value) }
}

@inline(never) public func callClosureValue(_ callback: (Int64) -> Int64, _ value: Int64) -> Int64 {
    callback(value)
}

@inline(never) public func holdClosureValue(_ callback: @escaping (Int64) -> Int64) -> ClosureValueHolder {
    ClosureValueHolder(callback)
}

@inline(never) public func makeStringClosureValue(_ prefix: String) -> (String) -> String {
    { prefix + $0 }
}

@inline(never) public func callRectClosureValue(_ callback: (CGRect) -> CGRect, _ value: CGRect) -> CGRect {
    callback(value)
}

@inline(never) public func callPointerClosureValue(
    _ callback: (UnsafePointer<Int64>?) -> Int64, _ value: UnsafePointer<Int64>?
) -> Int64 {
    callback(value)
}

@inline(never) public func callArrayClosureValue(
    _ callback: ([String]) -> [String], _ value: [String]
) -> [String] { callback(value) }

@inline(never) public func makeArrayClosureValue(_ suffix: String) -> ([String]) -> [String] {
    { $0 + [suffix] }
}

@inline(never) public func callOptionalArrayClosureValue(
    _ callback: ([String]?) -> [String]?, _ value: [String]?
) -> [String]? { callback(value) }

@inline(never) public func callOptionalStringClosureValue(
    _ callback: (String?) -> String?, _ value: String?
) -> String? { callback(value) }

@inline(never) public func makeOptionalStringClosureValue(_ suffix: String) -> (String?) -> String? {
    { $0.map { $0 + suffix } }
}

public final class ExplicitValueToken {
    public let number: Int64
    public init(_ number: Int64) { self.number = number }
}
@frozen public struct ExplicitVector {
    public let token: ExplicitValueToken
    public let x, y: Double
    public init(token: ExplicitValueToken, x: Double, y: Double) { self.token = token; self.x = x; self.y = y }
}
@frozen public enum ExplicitChoice {
    case number(Int64)
    case token(ExplicitValueToken)
    case empty
}
@frozen public struct ExplicitLarge {
    public let token: ExplicitValueToken
    public let a, b, c, d: Int64
    public init(token: ExplicitValueToken, a: Int64, b: Int64, c: Int64, d: Int64) {
        self.token = token; self.a = a; self.b = b; self.c = c; self.d = d
    }
}
@inline(never) public func callExplicitVector(
    _ callback: (ExplicitVector) -> ExplicitVector, _ value: ExplicitVector
) -> ExplicitVector { callback(value) }
@inline(never) public func callExplicitChoice(
    _ callback: (ExplicitChoice) -> ExplicitChoice, _ value: ExplicitChoice
) -> ExplicitChoice { callback(value) }
@inline(never) public func makeExplicitChoice() -> (ExplicitChoice) -> ExplicitChoice { { $0 } }
@inline(never) public func callExplicitLarge(
    _ callback: (ExplicitLarge) -> ExplicitLarge, _ value: ExplicitLarge
) -> ExplicitLarge { callback(value) }

@inline(never) public func callVoidClosureValue(_ callback: () -> Void) {
    callback()
}
@inline(never) public func visitNestedClosure(_ body: ((Int64) -> Int64) throws -> Int64) rethrows -> Int64 {
    var total: Int64 = 1
    let result = try body { total += $0; return total }
    return result + total
}

@inline(never) public nonisolated(nonsending) func visitNestedAsyncClosure(
    _ body: nonisolated(nonsending) (nonisolated(nonsending) (Int64) async -> Int64) async throws -> Int64
) async rethrows -> Int64 {
    var total: Int64 = 1
    let result = try await body { value in
        await Task.yield()
        total += value
        return total
    }
    return result + total
}

@inline(never) public func callClosureProducer(_ body: () throws -> (Int64) -> Int64) rethrows -> Int64 {
    try body()(35)
}

@inline(never) public func visitEscapingNestedClosure(
    _ body: (@escaping (Int64) -> Int64) throws -> Void
) rethrows {
    var total: Int64 = 7
    try body { total += $0; return total }
}

@inline(never) public nonisolated(nonsending) func visitEscapingNestedAsyncClosure(
    _ body: nonisolated(nonsending) (nonisolated(nonsending) @escaping (Int64) async -> Int64) async throws -> Void
) async rethrows {
    var total: Int64 = 7
    try await body { value in await Task.yield(); total += value; return total }
}

@inline(never) public func visitAsyncClosureSynchronously(
    _ body: (nonisolated(nonsending) (Int64) async -> Int64) -> Void
) {
    var total: Int64 = 1
    body { value in await Task.yield(); total += value; return total }
}

@inline(never) public func inspectAsyncClosureSynchronously(
    _ body: nonisolated(nonsending) (Int64) async -> Int64
) -> Int64 { 42 }

@inline(never) public nonisolated(nonsending) func applyBorrowedClosureAsync(
    _ body: (Int64) -> Int64, _ value: Int64
) async -> Int64 { await Task.yield(); return body(value) }

@inline(never) public nonisolated(nonsending) func applyBorrowedAsyncClosure(
    _ body: nonisolated(nonsending) (Int64) async -> Int64, _ value: Int64
) async -> Int64 { await body(value) }

@inline(never) public func visitClosureSynchronously(_ body: ((Int64) -> Int64) -> Void) {
    var total: Int64 = 1
    body { total += $0; return total }
}

@inline(never) public func callUnmanagedClosureValue(
    _ body: (Unmanaged<AnyObject>?) -> Unmanaged<AnyObject>?, _ value: Unmanaged<AnyObject>?
) -> Unmanaged<AnyObject>? { body(value) }

@inline(never) public func makeUnmanagedClosureValue() -> (Unmanaged<AnyObject>?) -> Unmanaged<AnyObject>? {
    { $0 }
}
