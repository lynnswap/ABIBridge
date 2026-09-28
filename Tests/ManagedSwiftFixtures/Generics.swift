@_cdecl("ABIGenericResilientArgument")
public func genericResilientArgument() -> UnsafeRawPointer {
    unsafeBitCast(ResilientRecord.self, to: UnsafeRawPointer.self)
}

public protocol GenericMetric {
    var metric: Int64 { get }
}

extension ManagedRecord: GenericMetric { public var metric: Int64 { number } }
extension ResilientRecord: GenericMetric { public var metric: Int64 { number } }

@frozen public struct GenericRecord<Value: GenericMetric> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

@frozen public struct ConditionalMetric<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
extension ConditionalMetric: GenericMetric where Value: GenericMetric {
    public var metric: Int64 { value.metric }
}

@inline(never) public func makeGenericRecord<Value: GenericMetric>(_ value: Value) -> GenericRecord<Value> {
    GenericRecord(value)
}

@inline(never) public func measureGenericRecord<Value: GenericMetric>(_ record: GenericRecord<Value>) -> Int64 {
    record.value.metric
}
