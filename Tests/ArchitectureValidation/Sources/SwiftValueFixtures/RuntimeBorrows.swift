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
