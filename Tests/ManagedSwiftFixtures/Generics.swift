import Foundation

public class GenericTypeClass<Value: Equatable>: NSObject {}
public final class GenericTypeDerived<Value: Equatable>: GenericTypeClass<[Value]> {}
public enum GenericTypeEnum<Value> { case value(Value) }
public struct GenericTypeCollection<Value: Collection> where Value.Element: Equatable {
    public let value: Value
}
public struct GenericTypeRelated<Values: Collection, Element> where Values.Element == Element {
    public let values: Values
}
public struct GenericTypeOuter<Value> {
    public struct Inner<Element> {}
    public struct FixedInner {}
}
extension GenericTypeOuter where Value: Equatable {
    public struct InExtension<Element> {}
}
extension GenericTypeOuter.Inner where Value: Collection, Value.Element == Element, Element: Equatable {
    public struct Constrained<Third> {}
}
public enum GenericTypeNamespace {
    public struct Member<Value> {}
}
public struct GenericTypePack<each Value: Equatable> {
    public let values: (repeat each Value)
}
public struct GenericTypeMixedPack<First, each Element> {
    public let first: First
    public let elements: (repeat each Element)
}

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
