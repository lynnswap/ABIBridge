import CoreGraphics

public final class ClosurePropertyOwner {
    public var callback: (Int64) -> Int64 = { $0 + 7 }
    public init() {}
    public func readCallback() -> (Int64) -> Int64 { callback }
}

@inline(never) public func echoClosure(_ callback: @escaping (Int64) -> Int64) -> (Int64) -> Int64 { callback }
import Dispatch
import Synchronization

private final class ClosureAccumulator: Sendable { let value = Mutex<Int64>(0) }

@inline(never) public func applyConcurrentClosure(_ callback: @escaping @Sendable (Int64) -> Int64) -> Int64 {
    let total = ClosureAccumulator()
    DispatchQueue.concurrentPerform(iterations: 64) { index in
        let result = callback(Int64(index))
        total.value.withLock { $0 += result }
    }
    return total.value.withLock { $0 }
}

@inline(never) public func makeNoncapturingClosure() -> (Int64) -> Int64 { { $0 * 2 } }

@inline(never) public func applyEmptyTupleClosure(_ callback: (()) -> Int64) -> Int64 { callback(()) }

@inline(never) public func applyStringClosure(_ callback: (String) -> String, _ value: String) -> String {
    callback(value)
}

@inline(never) public func makeStringClosure(_ prefix: String) -> (String) -> String {
    { prefix + $0 }
}

@inline(never) public func applyOptionalObjectClosure(
    _ callback: (LifetimeToken?) -> LifetimeToken?, _ value: LifetimeToken?
) -> LifetimeToken? {
    callback(value)
}

@inline(never) public func applyRectClosure(_ callback: (CGRect) -> CGRect, _ value: CGRect) -> CGRect {
    callback(value)
}
