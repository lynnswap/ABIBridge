import Foundation

public class BindingCandidateBase {
    public init() {}
    @inline(never) public func inheritedChoice() -> Int64 { 42 }
}
public final class BindingCandidateBox<Value>: BindingCandidateBase {}
extension BindingCandidateBox where Value: Collection, Value.Element == Int {
    @inline(never) public func inheritedChoice() -> Int64 { 41 }
    @inline(never) public func constraintChoice() -> Int64 { 43 }
}
extension BindingCandidateBox where Value == Bool {
    @inline(never) public func constraintChoice() -> Int64 { 42 }
}
extension BindingCandidateBox where Value == NSObject {
    @inline(never) public func classIdentity() -> Int64 { 42 }
}
extension BindingCandidateBox where Value == (first: Int64, second: String) {
    @inline(never) public func tupleIdentity() -> Int64 { 42 }
}
public final class BindingCallbackConventions<Value> {
    public init() {}
    @inline(never) public func callback(_ body: (Int64) -> Int64) -> Int64 { body(40) }
    @inline(never) public func callback(_ body: @convention(c) (Int64) -> Int64) -> Int64 { body(41) }
    @inline(never) public func callback(_ body: @convention(block) (Int64) -> Int64) -> Int64 { body(43) }
    @inline(never) public func foreignC(_ body: @convention(c) (Int64) -> Int64) -> Int64 { body(40) }
    @inline(never) public func foreignBlock(_ body: @convention(block) (Int64) -> Int64) -> Int64 { body(40) }
    @inline(never) public func returnedCallback() -> (Int64) -> Int64 { { $0 + 2 } }
    @inline(never) public func returnedCallback() -> @convention(c) (Int64) -> Int64 { { $0 + 1 } }
    @inline(never) public func returnedCallback() -> @convention(block) (Int64) -> Int64 { { $0 + 3 } }
}

public protocol GenericReceiverMetric { var text: String { get } }
public protocol BindingNotAnyObject {}
@inline(never) public func bindingSimilarConstraint<Value: BindingNotAnyObject>(_ value: Value) -> Value { value }

public struct GenericReceiverNumber: GenericReceiverMetric, CustomStringConvertible {
    public let number: Int
    public init(_ number: Int) { self.number = number }
    public var text: String { String(number) }
    public var description: String { text }
}

public struct GenericReceiverText: GenericReceiverMetric {
    public let text: String
    public init(_ text: String) { self.text = text }
}

public class GenericMemberReceiver<Value: GenericReceiverMetric>: NSObject {
    private let value: Value
    public init(_ value: Value) { self.value = value }
    @inline(never) public func concrete(_ prefix: String) -> String { prefix + value.text }
    @inline(never) public func read(_ value: Int64) -> Int64 { value + 1 }
    @inline(never) public func read(_ value: String) -> some Any { value }
    public var valueText: String { @inline(never) get { value.text } }
    @inline(never) public func projected() -> Value { value }
    @inline(never) public func echo(_ value: Value) -> Value { value }
    @inline(never) public func independent<Other>(_ value: Other) -> Other { value }
}

public final class InheritedGenericMemberReceiver: GenericMemberReceiver<GenericReceiverNumber> {}

extension GenericMemberReceiver where Value == GenericReceiverNumber {
    @inline(never) public func read(_ value: Double) -> Double { value + 2 }
    @inline(never) public func specialized(_ prefix: String) -> String { prefix + valueText }
    public var specializedText: String { @inline(never) get { valueText } }
}
extension GenericMemberReceiver where Value: CustomStringConvertible {
    @inline(never) public func witnessText() -> String { value.description }
}

public struct BindingBorrowedRecord<Value: GenericReceiverMetric> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
    @inline(never) public func measure() -> Int64 { Int64(value.text.count) }
    public var measured: Int64 { Int64(value.text.count) }
}
@inline(never) public func visitBindingBorrowedRecord(
    _ number: Int64, _ body: (BindingBorrowedRecord<GenericReceiverNumber>) -> (Int64, Int64)
) -> (Int64, Int64) { body(BindingBorrowedRecord(GenericReceiverNumber(Int(number)))) }

public protocol BindingWitnessA { static func first() -> Int64 }
public protocol BindingWitnessZ { static func last() -> Int64 }
public struct BindingWitnessValue: BindingWitnessA, BindingWitnessZ {
    public static func first() -> Int64 { 4 }
    public static func last() -> Int64 { 2 }
}
public struct BindingWitnessOwner<Value: BindingWitnessZ> {}
extension BindingWitnessOwner where Value: BindingWitnessA {
    @inline(never) public static func orderedWitnesses() -> Int64 { Value.first() * 10 + Value.last() }
}
public struct BindingHashOwner<Value: Equatable> {}
extension BindingHashOwner where Value: Hashable {
    @inline(never) public static func refinedWitness(_ value: Value) -> Int { value.hashValue }
}
extension BindingHashOwner where Value == Int {
    @inline(never) public static func concreteWitness<Other: Hashable>(_ value: Other) -> Int { value.hashValue }
}

public final class BindingBox<Value: Equatable> {
    public var value: Value
    public init(_ value: Value) { self.value = value }
    @inline(never) public func compare<Other: Equatable>(_ other: Other) -> (Value, Other, Bool) {
        (value, other, value == value && other == other)
    }
}
@frozen public struct BindingValue<Value> {
    public var value: Value
    public init(_ value: Value) { self.value = value }
    @inline(never) public mutating func replace(_ value: Value) { self.value = value }
    @inline(never) public consuming func take() -> Value { value }
}
public final class BindingGetter<Value, Failure: Error> {
    public var value: Value
    public var failure: Failure
    public var shouldThrow: Bool
    @inline(never) public func compareFlag(_ flag: Bool) -> Bool { flag == shouldThrow }
    public init(_ value: Value, _ failure: Failure, _ shouldThrow: Bool) {
        self.value = value; self.failure = failure; self.shouldThrow = shouldThrow
    }
    public var checkedNumber: Int64 {
        get throws(Failure) { if shouldThrow { throw failure }; return 42 }
    }
    public var fixedNumber: Int64 {
        get throws(SmallError) { if shouldThrow { throw SmallError(43) }; return 43 }
    }
    nonisolated(nonsending) public var delayed: Value {
        get async throws(Failure) { await Task.yield(); if shouldThrow { throw failure }; return value }
    }
}

@inline(never) public func bindingSelect<Value, Values: Collection>(
    _ fallback: Value, _ values: Values
) -> Value where Values.Element == Value { values.first ?? fallback }
@inline(never) public func bindingPack<each Value: Equatable>(_ values: repeat each Value) -> (repeat each Value) {
    (repeat each values)
}
@inline(never) public func bindingPackCallback<each Value>(
    _ body: (repeat each Value) -> (repeat each Value), _ values: repeat each Value
) -> (repeat each Value) { body(repeat each values) }
public final class BindingPackSource<each Value: Equatable> { public init() {} }
@inline(never) public func bindingPackSource<each Value: Equatable>(
    _ source: BindingPackSource<repeat each Value>, _ values: repeat each Value
) -> Int64 {
    var count: Int64 = 0
    func equal<Element: Equatable>(_ value: Element) { if value == value { count += 1 } }
    repeat equal(each values)
    return count
}
@inline(never) public func bindingTransform<Input, Output>(
    _ values: [Input], _ body: (Input) throws -> Output
) rethrows -> [Output] { try values.map(body) }
@inline(never) public func bindingClosure<Value>(_ value: Value) -> (Value) -> Value { { _ in value } }
@inline(never) public func bindingError<Failure: Error>(_ type: Failure.Type) throws(Failure) -> Int64 { 44 }
@inline(never) public func bindingErrorCallback<Failure: Error>(
    _ body: () throws(Failure) -> Int64
) throws(Failure) -> Int64 { try body() }
@inline(never) public nonisolated(nonsending) func bindingAsync<Value>(_ value: Value) async -> Value {
    await Task.yield(); return value
}
@inline(never) public nonisolated(nonsending) func bindingAsyncCallback<Value, Failure: Error>(
    _ value: Value, _ body: (nonisolated(nonsending) (Value) async throws(Failure) -> Value)
) async throws(Failure) -> Value { await Task.yield(); return try await body(value) }
@inline(never) public func bindingAsyncClosure<Value: Sendable>(
    _ value: Value
) -> (nonisolated(nonsending) @Sendable (Value) async -> Value) {
    { _ in await Task.yield(); return value }
}
@inline(never) public func bindingMutate<Value, Failure: Error>(
    _ value: inout Value, _ replacement: consuming Value, _ failure: Failure, _ shouldThrow: Bool
) throws(Failure) { value = replacement; if shouldThrow { throw failure } }
@inline(never) public func bindingMetatypes<Value>(
    _ type: Value.Type, _ optional: Int64.Type?, _ value: Value
) -> (Value.Type, Int64.Type?, Value) { (type, optional == nil ? Int64.self : nil, value) }
@inline(never) public func bindingMetatypeCallback<Value>(
    _ type: Value.Type, _ body: (Value.Type) -> Value.Type
) -> Value.Type { body(type) }
@inline(never) public func bindingExistentialMetatype<Value>(
    _ type: any CustomStringConvertible.Type, _ protocolType: (any CustomStringConvertible).Type, _ value: Value
) -> (any CustomStringConvertible.Type, (any CustomStringConvertible).Type, Value) { (type, protocolType, value) }

// This module cannot see the retroactive conformance in SwiftOpaqueExtensions.
public protocol BindingDeclaredScore { static func score() -> Int64 }
open class BindingDeclaredBase { public init() {} }
public struct BindingDeclaredUnknown<Value: BindingDeclaredScore> {}
extension BindingDeclaredUnknown where Value: BindingDeclaredBase {
    @inline(never) public static func entry<Failure: Error>(
        _ error: Failure, _ shouldThrow: Bool
    ) throws(Failure) -> Int64 {
        if shouldThrow { throw error }
        return Value.score()
    }
}

public final class BindingClosureOwner<Value> {
    public var body: () -> Value
    public init(_ body: @escaping () -> Value) { self.body = body }
    @inline(never) public func run() -> Value { body() }
}
@inline(never) public func bindingConsumeClosure<Value, Failure: Error>(
    _ body: consuming @escaping () -> Value, _ error: Failure, _ shouldThrow: Bool
) throws(Failure) -> Value {
    if shouldThrow { throw error }
    return body()
}

public final class BindingObjectBox<Value: AnyObject> {
    private let value: Value
    public init(_ value: Value) { self.value = value }
    @inline(never) public func project() -> Value { value }
}
@inline(never) public func bindingObjectIdentity<Value: AnyObject>(_ value: Value) -> Value { value }
@inline(never) public func bindingProtocolIdentity<Value: NSObjectProtocol>(_ value: Value) -> Value { value }
@inline(never) public func bindingSuperclassIdentity<Value: NSObject>(
    _ value: Value, _ protocolValue: any NSObjectProtocol
) -> Value { value }
