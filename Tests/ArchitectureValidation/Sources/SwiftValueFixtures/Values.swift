public final class ValueToken {
    public init() {}
}

public struct ResilientValue {
    private let owner: ValueToken
    private let payload: Int64
    public init(token: ValueToken, number: Int64) { owner = token; payload = number }
    public var token: ValueToken { owner }
    public var number: Int64 { payload }
    public func advanced(_ amount: Int64) -> Self { Self(token: owner, number: payload + amount) }
}

@frozen public struct GenericValue<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
public enum Namespace {
    @frozen public struct 箱<Value> {
        public let value: Value
        public init(_ value: Value) { self.value = value }
    }
}

@inline(never) public func echoResilient(_ value: ResilientValue) -> ResilientValue { value }
@inline(never) public func applyResilient(
    _ body: (ResilientValue) -> ResilientValue, _ value: ResilientValue
) -> ResilientValue { body(value) }
@inline(never) public func returnResilient(_ amount: Int64) -> (ResilientValue) -> ResilientValue {
    { $0.advanced(amount) }
}
@inline(never) public func applyGeneric(
    _ body: (GenericValue<Int64>) -> GenericValue<Int64>, _ value: GenericValue<Int64>
) -> GenericValue<Int64> { body(value) }
@inline(never) public func returnGeneric(_ amount: Int64) -> (GenericValue<Int64>) -> GenericValue<Int64> {
    { GenericValue($0.value + amount) }
}
@inline(never) public func applyNested(
    _ body: (Namespace.箱<Int64>) -> Namespace.箱<Int64>, _ value: Namespace.箱<Int64>
) -> Namespace.箱<Int64> { body(value) }
