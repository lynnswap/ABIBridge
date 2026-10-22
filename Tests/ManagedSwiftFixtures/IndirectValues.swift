public struct IndirectRecord {
    private let storage: ManagedRecord
    public init(token: LifetimeToken, number: Int64) { storage = ManagedRecord(token: token, number: number) }
    public var token: LifetimeToken { storage.token }
    public var number: Int64 { storage.number }
    @inline(never) public func advanced(_ amount: Int64) -> IndirectRecord {
        IndirectRecord(token: token, number: number + amount)
    }
}

@frozen public struct ExplicitBox<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
public enum BoxNamespace {
    @frozen public struct Container<Value> {
        public let value: Value
        public init(_ value: Value) { self.value = value }
    }
}
@frozen public struct 箱<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

@inline(never) public func echoIndirectRecord(_ value: IndirectRecord) -> IndirectRecord { value }
@inline(never) public func applyIndirectRecord(
    _ callback: (IndirectRecord) -> IndirectRecord, _ value: IndirectRecord
) -> IndirectRecord { callback(value) }
@inline(never) public func makeIndirectRecordClosure(_ amount: Int64) -> (IndirectRecord) -> IndirectRecord {
    { $0.advanced(amount) }
}
@inline(never) public func applyExplicitBox(
    _ callback: (ExplicitBox<Int64>) -> ExplicitBox<Int64>, _ value: ExplicitBox<Int64>
) -> ExplicitBox<Int64> { callback(value) }
@inline(never) public func applyDoubleBox(
    _ callback: (ExplicitBox<Double>) -> ExplicitBox<Double>, _ value: ExplicitBox<Double>
) -> ExplicitBox<Double> { callback(value) }
@inline(never) public func applyStringBox(
    _ callback: (ExplicitBox<String>) -> ExplicitBox<String>, _ value: ExplicitBox<String>
) -> ExplicitBox<String> { callback(value) }

@inline(never) public func makeExplicitBoxClosure(_ amount: Int64) -> (ExplicitBox<Int64>) -> ExplicitBox<Int64> {
    { ExplicitBox($0.value + amount) }
}
@inline(never) public func applyNestedBox(
    _ callback: (BoxNamespace.Container<Int64>) -> BoxNamespace.Container<Int64>, _ value: BoxNamespace.Container<Int64>
) -> BoxNamespace.Container<Int64> { callback(value) }
@inline(never) public func applyUnicodeBox(
    _ callback: (箱<Int64>) -> 箱<Int64>, _ value: 箱<Int64>
) -> 箱<Int64> { callback(value) }

// Two elements return indirectly, and the five Int64 elements form a direct
// part too large for registers, so the compiler passes no result in the
// indirect-result register.
@inline(never) public func indirectRecordsAndWords(
    _ first: IndirectRecord,
    _ second: IndirectRecord
) -> (IndirectRecord, Int64, IndirectRecord, Int64, Int64, Int64, Int64) {
    (first.advanced(1), 10, second.advanced(2), 20, 30, 40, 50)
}
@inline(never) public func applyIndirectRecordsAndWords(
    _ body: (IndirectRecord, IndirectRecord) -> (
        IndirectRecord, Int64, IndirectRecord, Int64, Int64, Int64, Int64
    ),
    _ first: IndirectRecord,
    _ second: IndirectRecord
) -> (IndirectRecord, Int64, IndirectRecord, Int64, Int64, Int64, Int64) {
    let (a, b, c, d, e, f, g) = body(first, second)
    return (a.advanced(100), b + 1, c.advanced(100), d + 1, e + 1, f + 1, g + 1)
}
@inline(never) public func makeIndirectRecordsAndWordsClosure(
    _ amount: Int64
) -> (IndirectRecord, IndirectRecord) -> (
    IndirectRecord, Int64, IndirectRecord, Int64, Int64, Int64, Int64
) {
    {
        (
            $0.advanced(amount), amount, $1.advanced(amount * 2), amount + 1, amount + 2,
            amount + 3, amount + 4
        )
    }
}
@inline(never) public func asyncIndirectRecordsAndWords(
    _ first: IndirectRecord,
    _ second: IndirectRecord
) async -> (IndirectRecord, Int64, IndirectRecord, Int64, Int64, Int64, Int64) {
    await Task.yield()
    return (first.advanced(1), 10, second.advanced(2), 20, 30, 40, 50)
}
@inline(never) public func applyAsyncIndirectRecordsAndWords(
    _ body:
        @Sendable (IndirectRecord, IndirectRecord) async -> (
            IndirectRecord, Int64, IndirectRecord, Int64, Int64, Int64, Int64
        ),
    _ first: IndirectRecord,
    _ second: IndirectRecord
) async -> (IndirectRecord, Int64, IndirectRecord, Int64, Int64, Int64, Int64) {
    let (a, b, c, d, e, f, g) = await body(first, second)
    return (a.advanced(100), b + 1, c.advanced(100), d + 1, e + 1, f + 1, g + 1)
}
