public enum RuntimeTicketFailure: Error { case rejected }

@inline(never) public func visitRuntimeValue<T: ~Copyable>(
    _ value: borrowing T, _ body: (borrowing T) throws -> Int64
) rethrows -> Int64 { try body(value) }

@inline(never) public nonisolated(nonsending) func visitRuntimeValueAsync<T: ~Copyable>(
    _ value: borrowing T, _ body: (nonisolated(nonsending) (borrowing T) async throws -> Int64)
) async rethrows -> Int64 { try await body(value) }

@inline(never) public func visitConcreteRuntimeValue<Tag>(
    _ tag: Tag, _ value: String, _ body: (String) throws -> Int64
) rethrows -> Int64 { try body(value) }

@inline(never) public func inspectRuntimePack<each Value>(
    _ body: (repeat each Value) throws -> Int64, _ values: repeat each Value
) rethrows -> Int64 { try body(repeat each values) }


@inline(never) public func borrowRuntimeValue<T: ~Copyable>(_ value: borrowing T) -> Int64 {
    Int64(MemoryLayout<T>.size)
}

@inline(never) public func moveRuntimeValue<T: ~Copyable>(_ value: consuming T) -> T { value }

@inline(never) public func copyRuntimeValue<T>(_ value: T) -> T { value }

@inline(never) public func consumeRuntimeValueAndThrow<T: ~Copyable>(_ value: consuming T) throws {
    throw RuntimeTicketFailure.rejected
}

@inline(never) public func replaceRuntimeValue<T: ~Copyable>(_ target: inout T, _ value: consuming T) {
    target = consume value
}

@inline(never) public func moveRuntimeValueAfterArgument<T: ~Copyable>(_ value: consuming T, _ count: Int64) -> T {
    value
}

public struct RuntimeTicket: ~Copyable {
    public let token: AnyObject
    public var number: Int64
    public init(token: AnyObject, number: Int64) {
        self.token = token
        self.number = number
    }
    public func read() -> Int64 { number }
    public mutating func add(_ value: Int64) { number += value }
    public consuming func takeNumber() -> Int64 { number }
    public nonisolated(nonsending) func readAsync() async -> Int64 {
        await Task.yield()
        return number
    }
    public nonisolated(nonsending) mutating func addThenThrow(_ value: Int64) async throws {
        await Task.yield()
        number += value
        throw RuntimeTicketFailure.rejected
    }
    public nonisolated(nonsending) consuming func takeNumberAsync() async -> Int64 {
        await Task.yield()
        return number
    }
}

@inline(never) public func makeRuntimeTicket(_ token: AnyObject) -> some ~Copyable {
    RuntimeTicket(token: token, number: 42)
}

public struct RuntimeValueBox<Value: ~Copyable>: ~Copyable {
    public var value: Value
    public init(_ value: consuming Value) { self.value = value }
    public consuming func takeValue() -> Value { value }
    public func copiedValue() -> Value where Value: Copyable { value }
}

public struct RuntimeConditionalValueBox<Value: ~Copyable>: ~Copyable {
    public var value: Value
    public init(_ value: consuming Value) { self.value = value }
}
extension RuntimeConditionalValueBox: Copyable where Value: Copyable {}

public struct RuntimeRecord {
    public let object: AnyObject
    public let text: String
    private let cancellations: UnsafeMutablePointer<Int32>

    public init(object: AnyObject, text: String, cancellations: UnsafeMutablePointer<Int32>) {
        self.object = object
        self.text = text
        self.cancellations = cancellations
    }

    public var changed: AnyObject? { object }
    public func length() -> Int64 { Int64(text.count) }
    public nonisolated(nonsending) func lengthAsync() async -> Int64 {
        await Task.yield()
        return Int64(text.count)
    }
    public func cancel() { cancellations.pointee += 1 }
}

@inline(never) public func visitRuntimeRecord(
    _ object: AnyObject, _ text: String, _ cancellations: UnsafeMutablePointer<Int32>,
    _ body: (RuntimeRecord) -> Void
) {
    let record = RuntimeRecord(object: object, text: text, cancellations: cancellations)
    for _ in 0..<3 { body(record) }
}

nonisolated(unsafe) private var savedRuntimeCallback: ((RuntimeRecord) -> Void)?
public func saveRuntimeCallback(_ body: @escaping (RuntimeRecord) -> Void) { savedRuntimeCallback = body }
public func clearRuntimeCallback() { savedRuntimeCallback = nil }
public func fireRuntimeCallback(_ object: AnyObject, _ text: String, _ cancellations: UnsafeMutablePointer<Int32>) {
    savedRuntimeCallback?(RuntimeRecord(object: object, text: text, cancellations: cancellations))
}

// A compiler-generated reference call for a consumer that cannot import RuntimeRecord.
public func referenceRuntimeRecord(_ object: AnyObject, _ text: String, _ cancellations: UnsafeMutablePointer<Int32>) -> String {
    var result = ""
    visitRuntimeRecord(object, text, cancellations) { record in
        result += record.text
        record.cancel()
    }
    return result
}

@inline(never) public func makeRuntimeReader<T: ~Copyable>(_ type: T.Type) -> (borrowing T) -> Int64 {
    { _ in Int64(MemoryLayout<T>.size) }
}

@inline(never) public func makeRuntimeCopy<T>(_ type: T.Type) -> (T) -> T { { $0 } }

@inline(never) public func makeRuntimeProducer<T>(_ value: T) -> () -> T { { value } }

@inline(never) public func makeRuntimeAsyncCopy<T>(_ type: T.Type)
    -> nonisolated(nonsending) (T) async -> T {
    { value in await Task.yield(); return value }
}

@inline(never) public func makeRuntimePackReader<each T>(_ values: repeat each T) -> (repeat each T) -> Int64 {
    { (_: repeat each T) in 42 }
}

@inline(never) public func inspectRuntimeReader<T: ~Copyable>(_ value: borrowing T, _ body: (borrowing T) -> Int64) -> Int64 {
    body(value)
}

@inline(never) public func inspectRuntimePackReader<each T>(_ body: (repeat each T) -> Int64, _ values: repeat each T) -> Int64 {
    body(repeat each values)
}

@inline(never) public func callRuntimeCopy<T>(_ body: (T) -> T, _ value: T) -> T { body(value) }

@inline(never) public func makeRuntimeThrowingCopy<T, Failure: Error>(_ type: T.Type, _ failure: Failure, _ fail: Bool) -> (T) throws(Failure) -> T {
    { value throws(Failure) in
        if fail { throw failure }
        return value
    }
}

@inline(never) public func makeConcreteRuntimeReader<Tag>(_ tag: Tag) -> (Int64, String) -> Int64 {
    { number, text in number + Int64(text.count) }
}

@inline(never) public func makeRuntimeNeverCopy<Value, Failure: Error>(_ value: Value.Type, _ failure: Failure.Type) -> (Value) throws(Failure) -> Value {
    { value throws(Failure) in value }
}

@inline(never) public func makeRuntimeNeverAsyncCopy<Value, Failure: Error>(_ value: Value.Type, _ failure: Failure.Type)
    -> nonisolated(nonsending) (Value) async throws(Failure) -> Value {
    { value async throws(Failure) in await Task.yield(); return value }
}

@inline(never) public nonisolated(nonsending) func callRuntimeAsyncCopy<Value>(
    _ body: nonisolated(nonsending) (Value) async -> Value, _ value: Value
) async -> Value { await body(value) }

@inline(never) public func callRuntimeProducer<Value: ~Copyable>(_ body: () throws -> Value) rethrows -> Value {
    try body()
}

@inline(never) public func makeConcreteRuntimeCopy() -> (String) -> String { { $0 + "!" } }

@inline(never) public func applyConcreteRuntimeCopy(_ body: (String) throws -> String, _ value: String) rethrows -> String {
    try body(value)
}

public final class RuntimeCallbackHost {
    public init() {}
    @inline(never) public func copy() -> (String) -> String { makeConcreteRuntimeCopy() }
    @inline(never) public func apply(_ body: (String) throws -> String, _ value: String) rethrows -> String { try body(value) }
    public var copier: (String) -> String { makeConcreteRuntimeCopy() }
}

@inline(never) public func callRuntimeThrowingCopy<Value>(_ body: (Value) throws -> Value, _ value: Value) rethrows -> Value {
    try body(value)
}

@inline(never) public nonisolated(nonsending) func callRuntimeThrowingAsyncCopy<Value>(
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

public typealias CompositionSnapshot = (
    lead: Int8,
    record: RuntimeFixedPair,
    nested: (callback: (Int64) -> Int64, text: String, tail: Int8)
)

@frozen public struct RuntimeWeakRecord {
    public weak var object: AnyObject?
    public var number: Int64
    public init(_ object: AnyObject?, _ number: Int64) { self.object = object; self.number = number }
    public func hasObject() -> Bool { object != nil }
}

public struct RuntimeResilientWeakRecord {
    public weak var object: AnyObject?
    public var number: Int64
    public init(_ object: AnyObject?, _ number: Int64) { self.object = object; self.number = number }
    public func hasObject() -> Bool { object != nil }
}

@inline(never) public func transformRuntimeTuple<Value>(
    _ value: (Int8, Value, Int64), _ body: ((Int8, Value, Int64)) throws -> (Int8, Value, Int64)
) rethrows -> (Int8, Value, Int64) { try body(value) }

@inline(never) public nonisolated(nonsending) func transformRuntimeTupleAsync<Value>(
    _ value: (Int8, Value, Int64),
    _ body: nonisolated(nonsending) ((Int8, Value, Int64)) async throws -> (Int8, Value, Int64)
) async rethrows -> (Int8, Value, Int64) { try await body(value) }

@inline(never) public func transformRuntimePack<each Value>(
    _ body: (repeat each Value) throws -> (repeat each Value), _ values: repeat each Value
) rethrows -> (repeat each Value) { try body(repeat each values) }

@inline(never) public func makeCompositionSnapshot(
    _ object: AnyObject, _ first: Int64, _ second: Int64, _ text: String
) -> CompositionSnapshot {
    let record = RuntimeFixedPair(first, second)
    return (11, record, ({ value in withExtendedLifetime(object) { value + record.sum() } }, text, -7))
}

@inline(never) public func echoCompositionSnapshot(_ value: CompositionSnapshot) -> CompositionSnapshot { value }

@inline(never) public func consumeCompositionSnapshot(_ value: consuming CompositionSnapshot) -> CompositionSnapshot { value }

@inline(never) public func inspectCompositionSnapshot(
    _ value: CompositionSnapshot, _ body: (CompositionSnapshot) throws -> Int64
) rethrows -> Int64 { try body(value) }

@inline(never) public func mutateCompositionSnapshot(_ value: inout CompositionSnapshot, _ offset: Int64) {
    let previous = value.nested.callback
    value.nested.callback = { previous($0) + offset }
    value.nested.tail -= 1
}

@inline(never) public func editCompositionSnapshot(
    _ value: inout CompositionSnapshot, _ body: (inout CompositionSnapshot) throws -> Void
) rethrows { try body(&value) }

@inline(never) public func invokeCompositionClosure(_ body: (Int64) -> Int64, _ value: Int64) -> Int64 {
    body(value)
}

@inline(never) public func inspectCompositionClosure(
    _ value: (Int64) -> Int64, _ body: ((Int64) -> Int64) throws -> Int64
) rethrows -> Int64 { try withoutActuallyEscaping(value) { try body($0) } }

@inline(never) public func swapRuntimeClosures<Value>(
    _ first: inout (Value) -> Value, _ second: inout (Value) -> Value
) { swap(&first, &second) }

@inline(never) public func visitRuntimeClosure<Value>(
    _ value: inout (Value) -> Value, _ body: (inout (Value) -> Value) throws -> Void
) rethrows { try body(&value) }

@inline(never) public func visitRuntimeClosurePair<Value>(
    _ first: inout (Value) -> Value, _ second: inout (Value) -> Value,
    _ body: (inout (Value) -> Value, inout (Value) -> Value) throws -> Int64
) rethrows -> Int64 { try body(&first, &second) }

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

@inline(never) public func makeRuntimeOpaque<Value>(_ value: Value) -> some Any { value }
@inline(never) public func makeRuntimeOpaquePair<First, Second>(_ first: First, _ second: Second) -> (some Any, some Any) { (first, second) }
@inline(never) public func makeRuntimeOpaqueClosure<Value>(_ value: Value) -> () -> some Any {
    let body: () -> Value = { value }
    return body
}
public final class RuntimeOpaqueOwner<Value> {
    let value: Value
    public init(_ value: Value) { self.value = value }
    public var opaque: some Any { value }
    @inline(never) public func make<Other>(_ other: Other) -> some Any { (value, other) }
}
public protocol RuntimeExtendedSource<Element> { associatedtype Element }
private struct RuntimeExtendedValue<Element>: RuntimeExtendedSource, CustomStringConvertible {
    let value: Element
    var description: String { String(describing: value) }
}
@inline(never) public func makeRuntimeExtended<Value>(_ value: Value) -> any RuntimeExtendedSource<Value> {
    RuntimeExtendedValue(value: value)
}
public protocol RuntimeExtendedObject<Element>: AnyObject { associatedtype Element }
private final class RuntimeExtendedObjectValue<Element>: RuntimeExtendedObject, CustomStringConvertible {
    let value: Element
    init(_ value: Element) { self.value = value }
    var description: String { String(describing: value) }
}
@inline(never) public func makeRuntimeExtendedObject<Value>(_ value: Value) -> any RuntimeExtendedObject<Value> {
    RuntimeExtendedObjectValue(value)
}
@inline(never) public func applyRuntimeExtendedObject<Value>(_ body: (any RuntimeExtendedObject<Value>) -> Int, _ value: Value) -> Int {
    body(RuntimeExtendedObjectValue(value))
}

public protocol RuntimeExtendedLeft<Element> { associatedtype Element }
public protocol RuntimeExtendedRight<Element> { associatedtype Element }
private struct RuntimeExtendedBoth: RuntimeExtendedLeft, RuntimeExtendedRight, CustomStringConvertible {
    typealias Element = Int
    var description: String { "both" }
}
@inline(never) public func makeLeftConstrainedComposition() -> any RuntimeExtendedLeft<Int> & RuntimeExtendedRight { RuntimeExtendedBoth() }
@inline(never) public func makeRightConstrainedComposition() -> any RuntimeExtendedLeft & RuntimeExtendedRight<Int> { RuntimeExtendedBoth() }

public protocol RuntimeClassLeft<Element>: AnyObject { associatedtype Element }
public protocol RuntimeClassRight<Element>: AnyObject { associatedtype Element }
public protocol RuntimeClassFirst<First>: AnyObject { associatedtype First }
public protocol RuntimeClassSecond<Second>: AnyObject { associatedtype Second }
public final class RuntimeClassBoth<Element>: RuntimeClassLeft, RuntimeClassRight, RuntimeClassFirst, RuntimeClassSecond {
    public typealias First = Element
    public typealias Second = Element
    public let value: Element
    public init(_ value: Element) { self.value = value }
}
@inline(never) public func makeRuntimeClassComposition<Element>(_ value: Element) -> any RuntimeClassLeft<Element> & RuntimeClassRight<Element> {
    RuntimeClassBoth(value)
}
@inline(never) public func echoRuntimeClassComposition<Element>(_ value: any RuntimeClassLeft<Element> & RuntimeClassRight<Element>) -> any RuntimeClassLeft<Element> & RuntimeClassRight<Element> { value }
@inline(never) public func makeRuntimeDistinctClassComposition<Element>(_ value: Element) -> any RuntimeClassFirst<Element> & RuntimeClassSecond<Element> {
    RuntimeClassBoth(value)
}
@inline(never) public func echoRuntimeDistinctClassComposition<Element>(_ value: any RuntimeClassFirst<Element> & RuntimeClassSecond<Element>) -> any RuntimeClassFirst<Element> & RuntimeClassSecond<Element> { value }
@inline(never) public func echoRuntimeParameterizedMetatype<Element>(_ value: any RuntimeClassLeft<Element>.Type) -> any RuntimeClassLeft<Element>.Type { value }
@inline(never) public func makeRuntimeParameterizedMetatype<Element>(_ value: Element) -> any RuntimeClassLeft<Element>.Type { RuntimeClassBoth<Element>.self }
@inline(never) public func applyRuntimeParameterizedMetatype<Element>(_ body: (any RuntimeClassLeft<Element>.Type) -> any RuntimeClassLeft<Element>.Type, _ value: Element) -> any RuntimeClassLeft<Element>.Type {
    body(RuntimeClassBoth<Element>.self)
}
@inline(never) public func echoRuntimeParameterizedMetatypeTuple<Element>(_ value: (any RuntimeClassLeft<Element>.Type, Int)) -> (any RuntimeClassLeft<Element>.Type, Int) { value }
@inline(never) public func echoRuntimeOptionalParameterizedMetatype<Element>(_ value: (any RuntimeClassLeft<Element>.Type)?) -> (any RuntimeClassLeft<Element>.Type)? { value }
@inline(never) public func replaceRuntimeParameterizedMetatype<Element>(_ value: inout any RuntimeClassLeft<Element>.Type, _ replacement: any RuntimeClassLeft<Element>.Type) { value = replacement }

public protocol RuntimeSharedBase<Element> { associatedtype Element; var value: Element { get } }
public protocol RuntimeSharedLeft: RuntimeSharedBase {}
public protocol RuntimeSharedRight: RuntimeSharedBase {}
public struct RuntimeSharedBoth<Element>: RuntimeSharedLeft, RuntimeSharedRight {
    public let value: Element
}
@inline(never) public func makeRuntimeSharedComposition<Element>(_ value: Element) -> any RuntimeSharedLeft & RuntimeSharedRight & RuntimeSharedBase<Element> {
    RuntimeSharedBoth(value: value)
}
