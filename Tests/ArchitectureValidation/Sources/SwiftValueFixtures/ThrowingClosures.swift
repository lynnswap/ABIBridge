public typealias SmallThrowingValue = (Int64) throws(SmallError) -> Int64
public typealias LargeThrowingValue = (ErrorToken, Bool) throws(LargeError) -> LargeError
@inline(never) public func applySmallThrowing(_ body: SmallThrowingValue, _ value: Int64) throws(SmallError) -> Int64 {
    try body(value)
}
@inline(never) public func applyLargeThrowing(_ body: LargeThrowingValue, _ token: ErrorToken, _ fail: Bool) throws(LargeError) -> LargeError {
    try body(token, fail)
}
@inline(never) public func returnSmallThrowing(_ token: ErrorToken) -> SmallThrowingValue {
    { (value: Int64) throws(SmallError) in
        if value < 0 { throw SmallError(42) }
        return withExtendedLifetime(token) { value + 7 }
    }
}
public final class ThrowingValueHolder {
    private let body: SmallThrowingValue
    public init(_ body: @escaping SmallThrowingValue) { self.body = body }
    public func value(_ input: Int64) throws(SmallError) -> Int64 { try body(input) }
}
@inline(never) public func retainSmallThrowing(_ body: @escaping SmallThrowingValue) -> ThrowingValueHolder {
    ThrowingValueHolder(body)
}
