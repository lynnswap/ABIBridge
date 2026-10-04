import Foundation

public protocol ExistentialValue: Sendable { var number: Int64 { get } }
public protocol ExistentialLabel: Sendable { var label: String { get } }
public protocol ExistentialObjectValue: AnyObject, Sendable { var number: Int64 { get } }
public protocol ExistentialObjectA: AnyObject {}
public protocol ExistentialObjectB: AnyObject {}
public protocol ExistentialObjectC: AnyObject {}
public protocol ExistentialObjectD: AnyObject {}

@frozen public struct InlineExistentialValue: ExistentialValue, ExistentialLabel {
    public let number: Int64
    public var label: String { "inline:\(number)" }
    public init(_ number: Int64) { self.number = number }
}
// This resilient payload exceeds an opaque existential's three-word inline buffer.
public struct BoxedExistentialValue: ExistentialValue, ExistentialLabel {
    public let token: ErrorToken
    public let number: Int64
    public let a, b, c: Int64
    public var label: String { "boxed:\(number)" }
    public init(_ token: ErrorToken, _ number: Int64) {
        self.token = token; self.number = number; a = 1; b = 2; c = 3
    }
}
public final class ExistentialObject: ExistentialObjectValue, ExistentialObjectA, ExistentialObjectB, ExistentialObjectC, ExistentialObjectD {
    public let token: ErrorToken
    public let number: Int64
    public init(_ token: ErrorToken, _ number: Int64) { self.token = token; self.number = number }
}
public typealias ManyObjectProtocols = any ExistentialObjectValue & ExistentialObjectA & ExistentialObjectB & ExistentialObjectC & ExistentialObjectD

@inline(never) public func echoAny(_ value: Any) -> Any { value }
@inline(never) public func echoExistential(_ value: any ExistentialValue) -> any ExistentialValue { value }
@inline(never) public func openExistential(_ value: any ExistentialValue) -> Int64 { value.number }
@inline(never) public func echoComposition(_ value: any ExistentialValue & ExistentialLabel) -> any ExistentialValue & ExistentialLabel { value }
@inline(never) public func echoClassExistential(_ value: any ExistentialObjectValue) -> any ExistentialObjectValue { value }
@inline(never) public func echoManyClassExistential(_ value: ManyObjectProtocols) -> ManyObjectProtocols { value }
@inline(never) public func echoErrorExistential(_ value: any Error) -> any Error { value }
@inline(never) public func echoOptionalExistential(_ value: (any ExistentialValue)?) -> (any ExistentialValue)? { value }
@inline(never) public func echoOptionalAny(_ value: Any?) -> Any? { value }
@inline(never) public func echoOptionalClass(_ value: (any ExistentialObjectValue)?) -> (any ExistentialObjectValue)? { value }
@inline(never) public func echoOptionalError(_ value: (any Error)?) -> (any Error)? { value }
@inline(never) public func consumeExistential(_ value: consuming any ExistentialValue, _ fail: Bool) throws(SmallError) -> Int64 {
    if fail { throw SmallError(value.number) }
    return value.number
}
@inline(never) public func replaceExistential(_ value: inout any ExistentialValue, _ replacement: any ExistentialValue, _ fail: Bool) throws(SmallError) {
    value = replacement
    if fail { throw SmallError(value.number) }
}
@inline(never) @concurrent public func asyncExistential(_ gate: AsyncValueGate, _ value: any ExistentialValue, _ fail: Bool) async throws(SmallError) -> any ExistentialValue {
    await gate.wait()
    if fail || Task.isCancelled { throw SmallError(value.number) }
    return value
}
@inline(never) public func applyAnyExistentialClosure(_ body: (Any) -> Any, _ value: Any) -> Any { body(value) }
@inline(never) public func applyExistentialClosure(_ body: (any ExistentialValue) -> any ExistentialValue, _ value: any ExistentialValue) -> any ExistentialValue { body(value) }
@inline(never) public func applyClassExistentialClosure(_ body: (any ExistentialObjectValue) -> any ExistentialObjectValue, _ value: any ExistentialObjectValue) -> any ExistentialObjectValue { body(value) }
@inline(never) public func applyManyClassExistentialClosure(_ body: (ManyObjectProtocols) -> ManyObjectProtocols, _ value: ManyObjectProtocols) -> ManyObjectProtocols { body(value) }
@inline(never) public func applyErrorExistentialClosure(_ body: (any Error) -> any Error, _ value: any Error) -> any Error { body(value) }
@inline(never) public func applyOptionalClassClosure(_ body: ((any ExistentialObjectValue)?) -> (any ExistentialObjectValue)?, _ value: (any ExistentialObjectValue)?) -> (any ExistentialObjectValue)? { body(value) }
@inline(never) public func applyOptionalErrorClosure(_ body: ((any Error)?) -> (any Error)?, _ value: (any Error)?) -> (any Error)? { body(value) }
@inline(never) public func makeExistentialClosure(_ value: any ExistentialValue) -> (any ExistentialValue) -> any ExistentialValue {
    { input in input.number == 0 ? value : input }
}
@inline(never) @concurrent public func applyAsyncExistentialClosure(_ body: @concurrent @Sendable (any ExistentialValue) async -> any ExistentialValue, _ value: any ExistentialValue) async -> any ExistentialValue {
    await body(value)
}

open class RuntimeExtendedSuperclass<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
private final class RuntimeExtendedSubclass<Element>: RuntimeExtendedSuperclass<Element>, RuntimeExtendedObject, CustomStringConvertible {
    var description: String { String(describing: value) }
}
@inline(never) public func makeRuntimeExtendedSuperclass<Value>(
    _ value: Value
) -> any RuntimeExtendedSuperclass<Value> & RuntimeExtendedObject<Value> { RuntimeExtendedSubclass(value) }
@inline(never) public func applyRuntimeExtendedSuperclass<Value>(
    _ body: (any RuntimeExtendedSuperclass<Value> & RuntimeExtendedObject<Value>) -> Int, _ value: Value
) -> Int { body(RuntimeExtendedSubclass(value)) }
@inline(never) public func makeRuntimeExtendedSuperclassClosure<Value>(
    _ value: Value
) -> () -> any RuntimeExtendedSuperclass<Value> & RuntimeExtendedObject<Value> { { RuntimeExtendedSubclass(value) } }

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

public protocol RuntimeSharedBase<Element> { associatedtype Element; var value: Element { get } }
public protocol RuntimeSharedLeft: RuntimeSharedBase {}
public protocol RuntimeSharedRight: RuntimeSharedBase {}
public struct RuntimeSharedBoth<Element>: RuntimeSharedLeft, RuntimeSharedRight {
    public let value: Element
}
@inline(never) public func makeRuntimeSharedComposition<Element>(_ value: Element) -> any RuntimeSharedLeft & RuntimeSharedRight & RuntimeSharedBase<Element> {
    RuntimeSharedBoth(value: value)
}

public protocol ExistentialPackMarker: AnyObject { var number: Int64 { get } }
public class ExistentialPackBase<each Value> {
    public let number: Int64
    public init(_ number: Int64) { self.number = number }
}
extension ExistentialPackBase: ExistentialPackMarker {}
@inline(never) public func makeSuperclassPackExistential<each Value>(_ number: Int64) -> any ExistentialPackBase<repeat each Value> & ExistentialPackMarker {
    ExistentialPackBase<repeat each Value>(number)
}
@inline(never) public func echoSuperclassPackExistential<each Value>(_ value: any ExistentialPackBase<repeat each Value> & ExistentialPackMarker) -> any ExistentialPackBase<repeat each Value> & ExistentialPackMarker { value }
@inline(never) public func applySuperclassPackExistential<each Value>(_ value: any ExistentialPackBase<repeat each Value> & ExistentialPackMarker,
    _ body: (any ExistentialPackBase<repeat each Value> & ExistentialPackMarker) throws -> any ExistentialPackBase<repeat each Value> & ExistentialPackMarker
) rethrows -> any ExistentialPackBase<repeat each Value> & ExistentialPackMarker { try body(value) }
@inline(never) public func echoNSObjectCopying<Value>(_ value: any NSObject & NSCopying, _ tag: Value) -> any NSObject & NSCopying { value }
