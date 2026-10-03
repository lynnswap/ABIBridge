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
    public let token: ErrorLifetimeToken
    public let number: Int64
    public let a, b, c: Int64
    public var label: String { "boxed:\(number)" }
    public init(_ token: ErrorLifetimeToken, _ number: Int64) {
        self.token = token; self.number = number; a = 1; b = 2; c = 3
    }
}
public final class ExistentialObject: ExistentialObjectValue, ExistentialObjectA, ExistentialObjectB, ExistentialObjectC, ExistentialObjectD {
    public let token: ErrorLifetimeToken
    public let number: Int64
    public init(_ token: ErrorLifetimeToken, _ number: Int64) { self.token = token; self.number = number }
}
public typealias ManyObjectProtocols = any ExistentialObjectValue & ExistentialObjectA & ExistentialObjectB & ExistentialObjectC & ExistentialObjectD

@inline(never) public func echoAny(_ value: Any) -> Any { value }
@inline(never) public func echoExistential(_ value: any ExistentialValue) -> any ExistentialValue { value }
@inline(never) public func openExistential(_ value: any ExistentialValue) -> Int64 { value.number }
@inline(never) public func echoComposition(_ value: any ExistentialValue & ExistentialLabel) -> any ExistentialValue & ExistentialLabel { value }
@inline(never) public func echoClassExistential(_ value: any ExistentialObjectValue) -> any ExistentialObjectValue { value }
@inline(never) public func echoManyClassExistential(_ value: ManyObjectProtocols) -> ManyObjectProtocols { value }
@inline(never) public func echoErrorExistential(_ value: any Error) -> any Error { value }
@inline(never) public func echoClassErrorExistential(_ value: any Error & AnyObject) -> any Error & AnyObject { value }
@inline(never) public func echoOptionalExistential(_ value: (any ExistentialValue)?) -> (any ExistentialValue)? { value }
@inline(never) public func echoOptionalAny(_ value: Any?) -> Any? { value }
@inline(never) public func echoOptionalClass(_ value: (any ExistentialObjectValue)?) -> (any ExistentialObjectValue)? { value }
@inline(never) public func echoOptionalError(_ value: (any Error)?) -> (any Error)? { value }
@inline(never) public func consumeExistential(_ value: consuming any ExistentialValue, _ fail: Bool) throws(ScalarFailure) -> Int64 {
    if fail { throw ScalarFailure(value.number) }
    return value.number
}
@inline(never) public func replaceExistential(_ value: inout any ExistentialValue, _ replacement: any ExistentialValue, _ fail: Bool) throws(ScalarFailure) {
    value = replacement
    if fail { throw ScalarFailure(value.number) }
}
@inline(never) @concurrent public func asyncExistential(_ gate: AsyncGate, _ value: any ExistentialValue, _ fail: Bool) async throws(ScalarFailure) -> any ExistentialValue {
    await gate.wait()
    if fail || Task.isCancelled { throw ScalarFailure(value.number) }
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

public protocol ExistentialSource<Element>: AnyObject {
    associatedtype Element
    var element: Element { get }
}
public final class ExistentialIntSource: ExistentialSource {
    public let element: Int
    public init(_ element: Int) { self.element = element }
}
@inline(never) public func echoExtendedCollection(_ value: any Collection<Int>) -> any Collection<Int> { value }
@inline(never) public func echoExtendedSource(_ value: any ExistentialSource<Int>) -> any ExistentialSource<Int> { value }
@inline(never) public func echoGenericExtendedCollection<T>(_ value: any Collection<T>) -> any Collection<T> { value }
@inline(never) public func makeGenericExtendedCollection<T>(_ value: T) -> any Collection<T> { [value] }
@inline(never) public func applyExtendedSource(_ body: (any ExistentialSource<Int>) -> any ExistentialSource<Int>, _ value: any ExistentialSource<Int>) -> any ExistentialSource<Int> { body(value) }
@inline(never) public func applyExtendedCollection(_ body: (any Collection<Int>) -> any Collection<Int>, _ value: any Collection<Int>) -> any Collection<Int> { body(value) }

public protocol FreshExistentialSource<Element> { associatedtype Element; var element: Element { get } }
public struct FreshExistentialValue<Element>: FreshExistentialSource, CustomStringConvertible {
    public let element: Element
    public var description: String { String(describing: element) }
}
@inline(never) public func makeFreshExistential<Element>(_ value: Element) -> any FreshExistentialSource<Element> {
    FreshExistentialValue(element: value)
}

public protocol FreshExistentialPair<First, Second> { associatedtype First; associatedtype Second }
public struct FreshExistentialPairValue<First, Second>: FreshExistentialPair, CustomStringConvertible {
    let first: First
    let second: Second
    public var description: String { "\(first):\(second)" }
}
@inline(never) public func makeFreshExistentialPair<First, Second>(_ first: First, _ second: Second) -> any FreshExistentialPair<First, Second> {
    FreshExistentialPairValue(first: first, second: second)
}
public protocol FreshExistentialClass<Element>: AnyObject { associatedtype Element }
public final class FreshExistentialClassValue<Element>: FreshExistentialClass, CustomStringConvertible {
    let element: Element
    init(_ element: Element) { self.element = element }
    public var description: String { String(describing: element) }
}
@inline(never) public func makeFreshExistentialClass<Element>(_ value: Element) -> any FreshExistentialClass<Element> {
    FreshExistentialClassValue(value)
}

open class ExistentialSuperclass<Value> {
    public let element: Value
    public init(_ element: Value) { self.element = element }
}
public final class ExistentialSuperclassValue<Value>: ExistentialSuperclass<Value>, ExistentialSource {}
@inline(never) public func echoGenericSuperclass<Value>(
    _ value: any ExistentialSuperclass<Value> & ExistentialSource<Value>
) -> any ExistentialSuperclass<Value> & ExistentialSource<Value> { value }
@inline(never) public func makeGenericSuperclass<Value>(
    _ value: Value
) -> any ExistentialSuperclass<Value> & ExistentialSource<Value> { ExistentialSuperclassValue(value) }
