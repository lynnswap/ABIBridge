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
