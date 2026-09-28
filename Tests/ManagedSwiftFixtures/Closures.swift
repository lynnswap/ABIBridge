public typealias IntegerClosure = (Int64) -> Int64
public typealias SendableIntegerClosure = @Sendable (Int64) -> Int64
public typealias IsolatedIntegerClosure = @MainActor (Int64) -> Int64

public final class StoredIntegerClosure {
    private let callback: IntegerClosure
    public init(_ callback: @escaping IntegerClosure) { self.callback = callback }
    public func callAsFunction(_ value: Int64) -> Int64 { callback(value) }
    public func apply(_ transform: IntegerClosure, _ value: Int64) -> Int64 { transform(callback(value)) }
}

@inline(never) public func applyIntegerClosure(_ callback: IntegerClosure, _ value: Int64) -> Int64 {
    callback(value)
}

@inline(never) public func retainIntegerClosure(_ callback: @escaping IntegerClosure) -> StoredIntegerClosure {
    StoredIntegerClosure(callback)
}

@inline(never) public func makeIntegerClosure(_ token: LifetimeToken, _ bias: Int64) -> IntegerClosure {
    { value in withExtendedLifetime(token) { value + bias } }
}

@inline(never) public func applySendableIntegerClosure(_ callback: SendableIntegerClosure, _ value: Int64) -> Int64 {
    callback(value)
}

@MainActor @inline(never) public func applyIsolatedIntegerClosure(
    _ callback: IsolatedIntegerClosure, _ value: Int64
) -> Int64 {
    callback(value)
}
