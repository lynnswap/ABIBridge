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

@inline(never) public func callRuntimeThrowingCopy<Value>(_ body: (Value) throws -> Value, _ value: Value) rethrows -> Value {
    try body(value)
}

@inline(never) public nonisolated(nonsending) func callRuntimeThrowingAsyncCopy<Value>(
    _ body: nonisolated(nonsending) (Value) async throws -> Value, _ value: Value
) async rethrows -> Value { try await body(value) }
