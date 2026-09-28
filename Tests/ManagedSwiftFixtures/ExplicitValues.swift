@frozen public struct ManagedVector {
    public let token: LifetimeToken
    public let x, y: Double
    public init(token: LifetimeToken, x: Double, y: Double) { self.token = token; self.x = x; self.y = y }
}

@frozen public enum ManagedChoice {
    case number(Int64)
    case token(LifetimeToken)
    case empty
}

@frozen public struct LargeManagedValue {
    public let token: LifetimeToken
    public let a, b, c, d: Int64
    public init(token: LifetimeToken, a: Int64, b: Int64, c: Int64, d: Int64) {
        self.token = token; self.a = a; self.b = b; self.c = c; self.d = d
    }
}

@inline(never) public func transformManagedVector(_ value: ManagedVector) -> ManagedVector {
    ManagedVector(token: value.token, x: value.x + 1, y: value.y + 2)
}
@inline(never) public func echoManagedChoice(_ value: ManagedChoice) -> ManagedChoice { value }
@inline(never) public func echoLargeManagedValue(_ value: LargeManagedValue) -> LargeManagedValue { value }
@inline(never) public func applyManagedVector(
    _ callback: (ManagedVector) -> ManagedVector, _ value: ManagedVector
) -> ManagedVector { callback(value) }
@inline(never) public func applyManagedChoice(
    _ callback: (ManagedChoice) -> ManagedChoice, _ value: ManagedChoice
) -> ManagedChoice { callback(value) }
@inline(never) public func applyLargeManagedValue(
    _ callback: (LargeManagedValue) -> LargeManagedValue, _ value: LargeManagedValue
) -> LargeManagedValue { callback(value) }
@inline(never) public func makeManagedVectorClosure(_ delta: Double) -> (ManagedVector) -> ManagedVector {
    { ManagedVector(token: $0.token, x: $0.x + delta, y: $0.y + delta) }
}
@inline(never) public func makeManagedChoiceClosure() -> (ManagedChoice) -> ManagedChoice { { $0 } }

public final class ExplicitValueStore {
    public var value: ManagedChoice
    public init(_ value: ManagedChoice) { self.value = value }
    @inline(never) public func replace(_ value: ManagedChoice) -> ManagedChoice {
        let previous = self.value
        self.value = value
        return previous
    }
}
