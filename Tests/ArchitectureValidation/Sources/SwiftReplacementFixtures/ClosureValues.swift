import CoreGraphics

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
