@inline(never) public func produceGeneric<Value>(_ body: () -> Value) -> Value { body() }
@inline(never) public func replayGeneric<Value>(_ value: Value) -> Value { value }

public struct BorrowedRuntimeRecord {
    public let text: String
    private let object: AnyObject
    private let cancellations: UnsafeMutablePointer<Int32>
    public init(text: String, object: AnyObject, cancellations: UnsafeMutablePointer<Int32>) {
        self.text = text; self.object = object; self.cancellations = cancellations
    }
    public var changed: AnyObject? { object }
    public func length() -> Int { text.count }
    public func cancel() { cancellations.pointee += 1 }
}

nonisolated(unsafe) private var savedBorrowedCallback: ((BorrowedRuntimeRecord) -> Void)?

public func observeGeneric<Value>(
    _ apply: () -> Value, _ text: String, _ object: AnyObject,
    _ cancellations: UnsafeMutablePointer<Int32>, _ body: @escaping (BorrowedRuntimeRecord) -> Void
) -> Value {
    savedBorrowedCallback = body
    let record = BorrowedRuntimeRecord(text: text, object: object, cancellations: cancellations)
    for _ in 0..<3 { body(record) }
    return apply()
}

public func fireBorrowedRecord(_ text: String, _ object: AnyObject, _ cancellations: UnsafeMutablePointer<Int32>) {
    savedBorrowedCallback?(BorrowedRuntimeRecord(text: text, object: object, cancellations: cancellations))
}
public func clearBorrowedRecord() { savedBorrowedCallback = nil }
public func referenceProducedString(_ value: String) -> String { produceGeneric { value + "!" } }

@inline(never) public func visitRuntimeCallback<Value: ~Copyable>(
    _ value: borrowing Value, _ body: (borrowing Value) throws -> Int64
) rethrows -> Int64 { try body(value) }

@inline(never) public nonisolated(nonsending) func visitRuntimeCallbackAsync<Value: ~Copyable>(
    _ value: borrowing Value, _ body: nonisolated(nonsending) (borrowing Value) async throws -> Int64
) async rethrows -> Int64 { try await body(value) }

@inline(never) public func callRuntimeCallbackCopy<Value>(_ body: (Value) -> Value, _ value: Value) -> Value { body(value) }

@inline(never) public func makeConcreteRuntimeCallback() -> (String) -> String { { $0 + "!" } }

@inline(never) public func callRuntimeCallbackResult<Value>(_ body: (Value) throws -> Value, _ value: Value) rethrows -> Value { try body(value) }

@inline(never) public nonisolated(nonsending) func callRuntimeAsyncCallbackResult<Value>(
    _ body: nonisolated(nonsending) (Value) async throws -> Value, _ value: Value
) async rethrows -> Value { try await body(value) }
@inline(never) public func visitNestedRuntime<Value>(
    _ value: Value, _ body: ((Value) -> Value, Value) throws -> Value
) rethrows -> Value { try body({ $0 }, value) }

@inline(never) public func makeNestedRuntimeCaller<Value>(_ type: Value.Type) -> ((Value) -> Value, Value) -> Value {
    { callback, value in callback(value) }
}

@inline(never) public func callNestedRuntimeProducer<Value>(
    _ body: () throws -> (Value) -> Value, _ value: Value
) rethrows -> Value { try body()(value) }

private func nestedRuntimeIdentity<Value>(_ type: Value.Type) -> (Value) -> Value { { $0 } }
@inline(never) public func visitNestedRuntimePack<each Value>(
    _ types: repeat (each Value).Type, body: (repeat @escaping (each Value) -> each Value) throws -> Int64
) rethrows -> Int64 { try body(repeat nestedRuntimeIdentity((each Value).self)) }

@inline(never) public nonisolated(nonsending) func visitNestedRuntimeAsync<Value>(
    _ value: Value,
    _ body: nonisolated(nonsending) (nonisolated(nonsending) (Value) async -> Value, Value) async throws -> Value
) async rethrows -> Value {
    try await body({ value in await Task.yield(); return value }, value)
}

@inline(never) public func makeConcreteNestedCaller() -> ((Int64) -> Int64, Int64) -> Int64 {
    { callback, value in callback(value) }
}

@inline(never) public func callNestedRuntimeCaller<Value>(
    _ body: ((Value) -> Value, Value) -> Value, _ value: Value
) -> Value { body({ $0 }, value) }

@inline(never) public func callConcreteNestedCaller(_ body: ((Int64) -> Int64, Int64) -> Int64) -> Int64 {
    body({ $0 + 7 }, 35)
}

@inline(never) public func makeConcreteNestedProducer() -> () -> (Int64) -> Int64 { { { $0 + 7 } } }

@inline(never) public func makeNestedRuntimeProducer<Value>(_ type: Value.Type) -> () -> (Value) -> Value { { { $0 } } }

@inline(never) public func callNonthrowingNestedRuntimeProducer<Value>(
    _ body: () -> (Value) -> Value, _ value: Value
) -> Value { body()(value) }

@inline(never) public func callConcreteNestedProducer(_ body: () -> (Int64) -> Int64) -> Int64 { body()(42) }

@inline(never) public func makeConcreteNestedAsyncCaller()
    -> nonisolated(nonsending) (nonisolated(nonsending) (Int64) async -> Int64, Int64) async -> Int64 {
    { callback, value in await Task.yield(); return await callback(value) }
}

@inline(never) public nonisolated(nonsending) func callNestedRuntimeAsyncCaller<Value>(
    _ body: nonisolated(nonsending) (nonisolated(nonsending) (Value) async -> Value, Value) async -> Value, _ value: Value
) async -> Value { await body({ value in await Task.yield(); return value }, value) }

@inline(never) public func makeNestedRuntimeAsyncCaller<Value>(_ type: Value.Type)
    -> nonisolated(nonsending) (nonisolated(nonsending) (Value) async -> Value, Value) async -> Value {
    { callback, value in await Task.yield(); return await callback(value) }
}

@inline(never) public nonisolated(nonsending) func callConcreteNestedAsyncCaller(
    _ body: nonisolated(nonsending) (nonisolated(nonsending) (Int64) async -> Int64, Int64) async -> Int64
) async -> Int64 { await body({ value in await Task.yield(); return value + 7 }, 35) }

private final class RuntimeNestedClosureLifetime {
    let onDestroy: () -> Void
    init(_ onDestroy: @escaping () -> Void) { self.onDestroy = onDestroy }
    deinit { onDestroy() }
}

@inline(never) public func makeRetainedConcreteNestedProducer(_ onDestroy: @escaping () -> Void) -> () -> (Int64) -> Int64 {
    let lifetime = RuntimeNestedClosureLifetime(onDestroy)
    return { { value in withExtendedLifetime(lifetime) { value + 7 } } }
}

@inline(never) public func takeNestedRuntimeProducer<Value>(_ body: () -> (Value) -> Value) -> (Value) -> Value { body() }

@inline(never) public func makeConcreteNestedAsyncProducer()
    -> nonisolated(nonsending) () async -> nonisolated(nonsending) (Int64) async -> Int64 {
    { await Task.yield(); return { value in await Task.yield(); return value + 7 } }
}

@inline(never) public nonisolated(nonsending) func callNestedRuntimeAsyncProducer<Value>(
    _ body: nonisolated(nonsending) () async -> nonisolated(nonsending) (Value) async -> Value, _ value: Value
) async -> Value { let callback = await body(); return await callback(value) }

@inline(never) public func makeConcreteNestedPackCaller() -> ((Int64, String) -> Int64, Int64, String) -> Int64 {
    { callback, value, text in callback(value, text) }
}

private func makeNestedPackAnswer<each Value>(_ values: repeat each Value) -> (repeat each Value) -> Int64 {
    { (_: repeat each Value) in 42 }
}

@inline(never) public func callNestedRuntimePackCaller<each Value>(
    _ values: repeat each Value, body: (@escaping (repeat each Value) -> Int64, repeat each Value) -> Int64
) -> Int64 { body(makeNestedPackAnswer(repeat each values), repeat each values) }

@inline(never) public func visitConsumingRuntimeValue<T: ~Copyable>(
    _ value: consuming T, _ body: (consuming T) throws -> Int64
) rethrows -> Int64 { try body(consume value) }

@inline(never) public func visitConsumingString(
    _ value: consuming String, _ body: (consuming String) -> Int64
) -> Int64 { body(consume value) }

@inline(never) public func makeRuntimeConsumer<T: ~Copyable>(_ type: T.Type) -> (consuming T) -> Int64 {
    { (value: consuming T) in Int64(MemoryLayout<T>.size) }
}

@inline(never) public nonisolated(nonsending) func visitConsumingRuntimeValueAsync<T: ~Copyable>(
    _ value: consuming T, _ body: nonisolated(nonsending) (consuming T) async throws -> Int64
) async rethrows -> Int64 { try await body(consume value) }

@inline(never) public func visitNonthrowingConsumingRuntimeValue<T: ~Copyable>(
    _ value: consuming T, _ body: (consuming T) -> Int64
) -> Int64 { body(consume value) }

@inline(never) public func visitRuntimeInout<T: ~Copyable>(
    _ value: inout T, _ body: (inout T) throws -> Void
) rethrows { try body(&value) }

@inline(never) public nonisolated(nonsending) func visitRuntimeInoutAsync<T: ~Copyable>(
    _ value: inout T, _ body: nonisolated(nonsending) (inout T) async throws -> Void
) async rethrows { try await body(&value) }

@inline(never) public func holdRuntimeInout<T: ~Copyable>(_ value: inout T, _ body: () -> Bool) -> Bool { body() }

@inline(never) public func makeRuntimeSwap<T: ~Copyable>(_ type: T.Type) -> (inout T, inout T) -> Void {
    { first, second in swap(&first, &second) }
}

@inline(never) public func visitStringInout(_ value: inout String, _ body: (inout String) -> Void) { body(&value) }

@inline(never) public func makeRuntimeInoutReader<T: ~Copyable>(_ type: T.Type) -> (inout T) -> Int64 {
    { value in Int64(MemoryLayout<T>.size) }
}
@inline(never) public func visitOwnedNested<Value>(
    _ value: Value, _ onDestroy: @escaping () -> Void,
    _ body: (consuming @escaping (Value) -> Value) -> Void
) {
    let lifetime = RuntimeNestedClosureLifetime(onDestroy)
    body { _ in withExtendedLifetime(lifetime) { value } }
}

@inline(never) public func visitOwnedNestedThrowing<Value>(
    _ value: Value, _ onDestroy: @escaping () -> Void,
    _ body: (consuming @escaping (Value) -> Value) throws -> Void
) rethrows {
    let lifetime = RuntimeNestedClosureLifetime(onDestroy)
    try body { _ in withExtendedLifetime(lifetime) { value } }
}

public typealias OwnedNestedAsync<Value> = nonisolated(nonsending) (Value) async -> Value
@frozen public struct RuntimeFixedPair {
    public var first: Int64
    public var second: Int64
    public init(_ first: Int64, _ second: Int64) { self.first = first; self.second = second }
    public func sum() -> Int64 { first + second }
    public func inspect(_ body: (RuntimeFixedPair) -> Int64) -> Int64 { body(self) }
}

public final class RuntimeFixedPairStore {
    public var value: RuntimeFixedPair
    public init(_ value: RuntimeFixedPair) { self.value = value }
    public static func echo(_ value: RuntimeFixedPair) -> RuntimeFixedPair { value }
}

@inline(never) public func makeRuntimeFixedPair(_ first: Int64, _ second: Int64) -> RuntimeFixedPair {
    RuntimeFixedPair(first, second)
}

@inline(never) public func inspectRuntimeFixedPair(_ value: RuntimeFixedPair, _ body: (RuntimeFixedPair) -> Int64) -> Int64 {
    body(value)
}

@inline(never) public func makeOpaqueUsingCallback(_ body: (Int64) -> Int64) -> some Equatable { body(41) }

@inline(never) public nonisolated(nonsending) func visitOwnedNestedAsync<Value>(
    _ value: Value, _ onDestroy: @escaping () -> Void,
    _ body: nonisolated(nonsending) (consuming @escaping OwnedNestedAsync<Value>) async -> Void
) async {
    let lifetime = RuntimeNestedClosureLifetime(onDestroy)
    await body { _ in await Task.yield(); return withExtendedLifetime(lifetime) { value } }
}

@inline(never) public func makeConcreteOwnedNestedCaller()
    -> (consuming @escaping (Int64) -> Int64, Int64) -> Int64 { { callback, value in callback(value) } }

@inline(never) public func makeOwnedNestedRuntimeCaller<Value>(_ type: Value.Type)
    -> (consuming @escaping (Value) -> Value, Value) -> Value { { callback, value in callback(value) } }

@inline(never) public func callOwnedNestedRuntimeCaller<Value>(
    _ body: (consuming @escaping (Value) -> Value, Value) -> Value, _ value: Value, _ onDestroy: @escaping () -> Void
) -> Value {
    let lifetime = RuntimeNestedClosureLifetime(onDestroy)
    return body({ _ in withExtendedLifetime(lifetime) { value } }, value)
}

@inline(never) public func callConcreteOwnedNestedCaller(
    _ body: (consuming @escaping (Int64) -> Int64, Int64) -> Int64, _ value: Int64, _ onDestroy: @escaping () -> Void
) -> Int64 {
    let lifetime = RuntimeNestedClosureLifetime(onDestroy)
    return body({ _ in withExtendedLifetime(lifetime) { value } }, value)
}

@inline(never) public func makeConcreteOwnedNestedAsyncCaller()
    -> nonisolated(nonsending) (consuming @escaping OwnedNestedAsync<Int64>, Int64) async -> Int64 {
    { callback, value in await Task.yield(); return await callback(value) }
}

@inline(never) public nonisolated(nonsending) func callOwnedNestedRuntimeAsyncCaller<Value>(
    _ body: nonisolated(nonsending) (consuming @escaping OwnedNestedAsync<Value>, Value) async -> Value,
    _ value: Value, _ onDestroy: @escaping () -> Void
) async -> Value {
    let lifetime = RuntimeNestedClosureLifetime(onDestroy)
    return await body({ _ in await Task.yield(); return withExtendedLifetime(lifetime) { value } }, value)
}

@inline(never) public func makeMixedRuntimeReader<A, B>(_ first: A.Type, _ second: B.Type) -> (A, B) -> Int64 {
    { _, _ in 42 }
}
@inline(never) public func callMixedRuntimeReader<A, B>(_ body: (A, B) -> Int64, _ first: A, _ second: B) -> Int64 {
    body(first, second)
}
@inline(never) public func makeMixedRuntimeAsyncReader<A, B>(_ first: A.Type, _ second: B.Type)
    -> nonisolated(nonsending) (A, B) async -> Int64 {
    { _, _ in await Task.yield(); return 42 }
}
@inline(never) public nonisolated(nonsending) func callMixedRuntimeAsyncReader<A, B>(
    _ body: nonisolated(nonsending) (A, B) async -> Int64, _ first: A, _ second: B
) async -> Int64 { await body(first, second) }

@inline(never) public func makeRawRuntimeProducer<Value>(_ value: Value) -> () -> Value { { value } }
