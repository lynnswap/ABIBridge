import Foundation

public final class GenericSourcePack<each Value: Equatable> {
    public init() {}
}
@inline(never) private func countEqualPack<each Value: Equatable>(_ values: repeat each Value) -> Int64 {
    var count: Int64 = 0
    func countValue<Element: Equatable>(_ value: Element) { if value == value { count += 1 } }
    repeat countValue(each values)
    return count
}
@inline(never) public func packClassSourceGeneric<each Value: Equatable>(
    _ source: GenericSourcePack<repeat each Value>, _ values: repeat each Value
) -> Int64 { countEqualPack(repeat each values) }
@inline(never) public func packMetatypeSourceGeneric<each Value: Equatable>(
    _ type: GenericSourcePack<repeat each Value>.Type, _ values: repeat each Value
) -> Int64 { countEqualPack(repeat each values) }
@inline(never) public func packValueMetatypeGeneric<each Value: Equatable>(
    _ type: GenericTypePack<repeat each Value>.Type, _ values: repeat each Value
) -> Int64 { countEqualPack(repeat each values) }
@inline(never) public func prefixedPackSourceGeneric<each Value: Equatable>(
    _ source: GenericSourcePack<Int64, repeat each Value>, _ values: repeat each Value
) -> Int64 { countEqualPack(repeat each values) }
@inline(never) public func arrayPackSourceGeneric<each Value: Equatable>(
    _ source: GenericSourcePack<repeat [each Value]>, _ values: repeat each Value
) -> Int64 { countEqualPack(repeat each values) }

public protocol GenericSourceParent { var sourceNumber: Int64 { get } }
public protocol GenericSourceChild: GenericSourceParent {}
public struct GenericSourceValue: GenericSourceChild {
    public let sourceNumber: Int64
    public init(_ value: Int64) { sourceNumber = value }
}
public class GenericSourceBox<Value: GenericSourceChild> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
public final class GenericSourceLeaf: GenericSourceBox<GenericSourceValue> {}
public class GenericSourceNested<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
@inline(never) public func classSourceGeneric<Value: GenericSourceChild, Other>(
    _ box: GenericSourceBox<Value>, _ other: Other
) -> (Int64, Other) { (box.value.sourceNumber, other) }
@inline(never) public func tupleSourceGeneric<Value: GenericSourceChild>(
    _ input: (GenericSourceBox<Value>, Int64)
) -> Int64 { input.0.value.sourceNumber + input.1 }
@inline(never) public func metatypeSourceGeneric<Value: GenericSourceChild>(
    _ type: GenericSourceBox<Value>.Type
) -> Int64 { 72 }
@inline(never) public func nestedSourceGeneric<Value>(
    _ box: GenericSourceNested<[Value]>
) -> Value { box.value[0] }
@inline(never) public func superclassSourceGeneric<Value: GenericSourceChild, Object: GenericSourceBox<Value>>(
    _ object: Object
) -> Int64 { object.value.sourceNumber }

@frozen public struct GenericObjectValue<Value: AnyObject> {
    public var value: Value
    public init(_ value: Value) { self.value = value }
    @inline(never) public func project() -> Value { value }
}

@frozen public struct GenericSuperclassValue<Value: NSObject> {
    public var value: Value
    public init(_ value: Value) { self.value = value }
    @inline(never) public func project() -> Value { value }
}

@frozen public struct GenericNestedValue<Value> {
    public var box: GenericValueBox<Value>
    public init(_ value: Value) { box = GenericValueBox(value) }
    @inline(never) public func project() -> Value { box.value }
}

public struct GenericSameTypeValue<Values: Collection> where Values.Element == ManagedRecord {
    public var values: Values
    public init(_ values: Values) { self.values = values }
    @inline(never) public func number() -> Int64 { values.first?.number ?? -1 }
}

public protocol GenericObjectContainer { associatedtype Item: AnyObject }
public struct GenericObjectCarrier: GenericObjectContainer { public typealias Item = NSObject }

@inline(never) public func associatedObjectGeneric<Value: GenericObjectContainer>(
    _ type: Value.Type, _ value: Value.Item
) -> Value.Item { value }

@objc public protocol GenericObjCConstraint { var genericNumber: Int { get } }
public class GenericObjCValue: NSObject, GenericObjCConstraint {
    public var genericNumber: Int { 42 }
}
@inline(never) public func objcConstraintGeneric<Value: GenericObjCConstraint>(_ value: Value) -> Value { value }
@inline(never) public func superclassConstraintGeneric<Value: GenericObjCValue>(_ value: Value) -> Value { value }

extension GenericValueBox {
    @inline(never) public func first<Element>() -> Element where Value == [Element] { value[0] }
}

public protocol GenericTree { associatedtype Child: GenericTree }
public struct GenericLeaf: GenericTree, Equatable { public typealias Child = GenericLeaf }
public struct GenericRecursive<Value: GenericTree> where Value.Child.Child: Equatable {}

public class GenericTypeClass<Value: Equatable>: NSObject {
    private var storage: Value
    public var value: Value {
        @inline(never) get { storage }
        @inline(never) set { storage = newValue }
    }
    public init(_ value: Value) { storage = value }
    @inline(never) public static func identity(_ value: Value) -> Value { value }
    @inline(never) public func compare<Other: Equatable>(_ other: Other) -> (Value, Other, Bool) {
        (storage, other, storage == storage && other == other)
    }
}
public final class GenericTypeDerived<Value: Equatable>: GenericTypeClass<[Value]> {}
public enum GenericTypeEnum<Value> {
    case value(Value)
    @inline(never) public func payload() -> Value {
        switch self { case .value(let value): value }
    }
}

@frozen public struct GenericValueBox<Value> {
    public var value: Value
    public init(_ value: Value) { self.value = value }
    @inline(never) public func project() -> Value { value }
    @inline(never) public mutating func replace(_ value: Value) { self.value = value }
    @inline(never) public consuming func take() -> Value { value }
    @inline(never) public func paired<Other: Equatable>(_ other: Other) -> (Value, Other, Bool) {
        (value, other, other == other)
    }
    @inline(never) public func checked<Failure: Error>(_ failure: Failure, fail: Bool) throws(Failure) -> Value {
        if fail { throw failure }
        return value
    }
    @inline(never) public static func identity(_ value: Value) -> Value { value }
}

extension GenericValueBox where Value: Sendable {
    @inline(never) public nonisolated(nonsending) func asynchronously() async -> Value { value }
}
extension GenericValueBox where Value == Int {
    @inline(never) public func concrete() -> Int { value }
}
extension GenericValueBox where Value: AnyObject {
    @inline(never) public func reference() -> Value { value }
}
extension GenericValueBox where Value: Equatable {
    @inline(never) public func selected() -> Int64 { 11 }
    public var selectedValue: Int64 { 12 }
    @inline(never) public static func selectedStatic() -> Int64 { 13 }
    public static var selectedStaticValue: Int64 { 14 }
}
extension GenericValueBox where Value: Hashable {
    @inline(never) public func selected() -> Int64 { 21 }
    public var selectedValue: Int64 { 22 }
    @inline(never) public static func selectedStatic() -> Int64 { 23 }
    public static var selectedStaticValue: Int64 { 24 }
}

@frozen public struct GenericPhantom<Value> {
    public var number: Int64
    public init(_ number: Int64) { self.number = number }
    @inline(never) public func read() -> Int64 { number }
    @inline(never) public func paired<Other>(_ other: Other) -> (Int64, Other) { (number, other) }
}

@inline(never) public func phantomGeneric<Value>(_ value: GenericPhantom<Value>) -> GenericPhantom<Value> { value }
@inline(never) public func boxedGeneric<Value>(_ value: GenericValueBox<Value>) -> GenericValueBox<Value> { value }
@inline(never) public func optionalArrayGeneric<Value>(_ value: [Value]?) -> [Value]? { value }

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
    @inline(never) public func project() -> Value { value }
    @inline(never) public func measure() -> Int64 { value.metric }
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
