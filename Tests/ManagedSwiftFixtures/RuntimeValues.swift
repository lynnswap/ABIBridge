public enum RuntimeTicketFailure: Error { case rejected }

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
