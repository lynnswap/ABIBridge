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
