import Foundation

@inline(never) public func borrowRuntimeValue<T: ~Copyable>(_ value: borrowing T) -> Int64 { Int64(MemoryLayout<T>.size) }
@inline(never) public func moveRuntimeValue<T: ~Copyable>(_ value: consuming T) -> T { value }
@inline(never) public func copyRuntimeValue<T>(_ value: T) -> T { value }
@inline(never) public func runtimeValueMetatype<T>(_ value: T) -> (Int64.Type, T) { (Int64.self, value) }
@inline(never) public func replaceRuntimeValue<T: ~Copyable>(_ target: inout T, _ value: consuming T) {
    target = consume value
}
@inline(never) public func consumeRuntimeValueAndThrow<T: ~Copyable>(_ value: consuming T) throws { throw SmallError(42) }
@inline(never) public nonisolated(nonsending) func borrowRuntimeValueAsync<T: ~Copyable>(_ value: borrowing T, _ gate: AsyncValueGate) async -> Int64 {
    await gate.wait()
    return Int64(MemoryLayout<T>.size)
}
@inline(never) public nonisolated(nonsending) func moveRuntimeValueAsync<T: ~Copyable>(_ value: consuming T) async -> T {
    await Task.yield()
    return value
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

private struct HiddenOpaqueValue: ExistentialValue, ExistentialLabel {
    let token: ErrorToken
    let number: Int64
    let message: String
    let numbers: [Int64]
    let vector: SIMD4<Float>
    var label: String { message }
    init(_ token: ErrorToken, _ number: Int64) {
        self.token = token; self.number = number
        message = String(repeating: "opaque", count: 100)
        numbers = [number, number + 1]
        vector = SIMD4(repeating: Float(number))
    }
}
@inline(never) public func makeOpaque(_ token: ErrorToken, _ number: Int64) -> some ExistentialValue & ExistentialLabel {
    HiddenOpaqueValue(token, number)
}
@inline(never) public func makeOpaqueInteger(_ number: Int64) -> some Any { number }
@inline(never) public func makeOpaqueEmpty() -> some Any { () }
@inline(never) public func makeNestedOpaque() -> () -> some Any {
    let body: () -> Int64 = { 42 }
    return body
}
@inline(never) public func makeOpaqueThrowing(_ token: ErrorToken, _ fail: Bool) throws(SmallError) -> some ExistentialValue {
    let value = HiddenOpaqueValue(token, 42)
    if fail { throw SmallError(42) }
    return value
}
@inline(never) @concurrent public func makeOpaqueAsync(_ gate: AsyncValueGate, _ token: ErrorToken, _ fail: Bool) async throws(SmallError) -> some ExistentialValue {
    await gate.wait()
    let value = HiddenOpaqueValue(token, 42)
    if fail || Task.isCancelled { throw SmallError(Task.isCancelled ? -1 : 42) }
    return value
}
public final class OpaqueOwner: Sendable {
    public let token: ErrorToken
    public init(_ token: ErrorToken) { self.token = token }
    public var summary: some ExistentialValue { HiddenOpaqueValue(token, 42) }
    @inline(never) public func make(_ number: Int64) -> some ExistentialValue { HiddenOpaqueValue(token, number) }
    @inline(never) public static func makeStatic(_ token: ErrorToken) -> some ExistentialValue { HiddenOpaqueValue(token, 43) }
    @inline(never) @concurrent public func makeAsync(_ gate: AsyncValueGate) async -> some ExistentialValue {
        await gate.wait()
        return HiddenOpaqueValue(token, 44)
    }
}
private struct HiddenGenericOpaque<Value> { let value: Value }
@inline(never) public func makeGenericOpaque<Value>(_ value: Value) -> some Any { HiddenGenericOpaque(value: value) }
private struct HiddenNoncopyableOpaque: ~Copyable { let value: Int64 }
@inline(never) public func makeNoncopyableOpaque() -> some ~Copyable { HiddenNoncopyableOpaque(value: 42) }

public struct OpaqueTicket: ~Copyable {
    public let token: ErrorToken
    public var number: Int64
    public func read() -> Int64 { number }
    public mutating func add(_ value: Int64) { number += value }
    public nonisolated(nonsending) func readAfter(_ gate: AsyncValueGate) async -> Int64 {
        await gate.wait()
        return number
    }
    public nonisolated(nonsending) consuming func takeNumber() async -> Int64 {
        await Task.yield()
        return number
    }
}
@inline(never) public func makeOpaqueTicket(_ token: ErrorToken) -> some ~Copyable {
    OpaqueTicket(token: token, number: 42)
}

public class OpaqueBase: @unchecked Sendable {
    public let token: ErrorToken
    public let number: Int64
    public init(_ token: ErrorToken, _ number: Int64) { self.token = token; self.number = number }
}
private final class HiddenOpaqueObject: OpaqueBase, ExistentialObjectValue, ExistentialValue, @unchecked Sendable {}
@inline(never) public func makeOpaqueClassAny(_ token: ErrorToken) -> some AnyObject { HiddenOpaqueObject(token, 41) }
@inline(never) public func makeOpaqueClassProtocol(_ token: ErrorToken) -> some ExistentialObjectValue { HiddenOpaqueObject(token, 42) }
@inline(never) public func makeOpaqueSuperclass(_ token: ErrorToken) -> some OpaqueBase & ExistentialObjectValue { HiddenOpaqueObject(token, 43) }
@inline(never) public func makeOpaqueUnconstrainedClass(_ token: ErrorToken) -> some ExistentialValue { HiddenOpaqueObject(token, 44) }
@inline(never) public func makeOpaqueClassThrowing(_ token: ErrorToken, _ fail: Bool) throws(SmallError) -> some ExistentialObjectValue {
    let object = HiddenOpaqueObject(token, 45)
    if fail { throw SmallError(42) }
    return object
}
@inline(never) @concurrent public func makeOpaqueClassAsync(_ gate: AsyncValueGate, _ token: ErrorToken) async -> some ExistentialObjectValue {
    await gate.wait()
    return HiddenOpaqueObject(token, 46)
}

private final class HiddenOpaqueObjC: NSObject {
    let token: ErrorToken
    init(_ token: ErrorToken) { self.token = token }
}
@inline(never) public func makeOpaqueObjC(_ token: ErrorToken) -> some NSObjectProtocol { HiddenOpaqueObjC(token) }

@inline(never) public func makeRuntimeOpaque<Value>(_ value: Value) -> some Any { value }
@inline(never) public func makeRuntimeOpaquePair<First, Second>(_ first: First, _ second: Second) -> (some Any, some Any) { (first, second) }
@inline(never) public func makeRuntimeOpaqueClosure<Value>(_ value: Value) -> () -> some Any {
    let body: () -> Value = { value }
    return body
}
public final class RuntimeOpaqueOwner<Value> {
    let value: Value
    public init(_ value: Value) { self.value = value }
    public var opaque: some Any { value }
    @inline(never) public func make<Other>(_ other: Other) -> some Any { (value, other) }
}
public protocol RuntimeExtendedSource<Element> { associatedtype Element }
private struct RuntimeExtendedValue<Element>: RuntimeExtendedSource, CustomStringConvertible {
    let value: Element
    var description: String { String(describing: value) }
}
@inline(never) public func makeRuntimeExtended<Value>(_ value: Value) -> any RuntimeExtendedSource<Value> {
    RuntimeExtendedValue(value: value)
}
public protocol RuntimeExtendedObject<Element>: AnyObject { associatedtype Element }
private final class RuntimeExtendedObjectValue<Element>: RuntimeExtendedObject, CustomStringConvertible {
    let value: Element
    init(_ value: Element) { self.value = value }
    var description: String { String(describing: value) }
}
@inline(never) public func makeRuntimeExtendedObject<Value>(_ value: Value) -> any RuntimeExtendedObject<Value> {
    RuntimeExtendedObjectValue(value)
}
@inline(never) public func applyRuntimeExtendedObject<Value>(_ body: (any RuntimeExtendedObject<Value>) -> Int, _ value: Value) -> Int {
    body(RuntimeExtendedObjectValue(value))
}

@inline(never) public func makeOptionalOpaqueObject(_ token: ErrorToken, _ present: Bool) -> (some ExistentialValue)? {
    present ? HiddenOpaqueObject(token, 42) : nil
}
@inline(never) public func makeOptionalClassOpaqueObject(_ token: ErrorToken, _ present: Bool) -> (some ExistentialObjectValue)? {
    present ? HiddenOpaqueObject(token, 42) : nil
}
@inline(never) public func makeOptionalOpaqueClosure(_ token: ErrorToken) -> (Bool) -> (some ExistentialValue)? {
    let body: (Bool) -> HiddenOpaqueObject? = { $0 ? HiddenOpaqueObject(token, 42) : nil }
    return body
}
@frozen public struct InlineOpaqueBox<Value>: CustomStringConvertible {
    public let value: Value
    public var description: String { String((value as? any ExistentialValue)?.number ?? -1) }
}
@inline(never) public func makeInlineOpaqueBox(_ token: ErrorToken) -> InlineOpaqueBox<some ExistentialValue> {
    InlineOpaqueBox(value: HiddenOpaqueObject(token, 42))
}

@inline(never) public func makeOptionalOpaqueThrowingClosure(_ token: ErrorToken) -> (Bool) throws(SmallError) -> (some ExistentialValue)? {
    let body: (Bool) throws(SmallError) -> HiddenOpaqueObject? = { present throws(SmallError) in
        if !present { throw SmallError(42) }
        return HiddenOpaqueObject(token, 42)
    }
    return body
}
@inline(never) public func makeOptionalOpaqueAsyncClosure(_ token: ErrorToken) -> @Sendable @concurrent (Bool) async -> (some ExistentialValue)? {
    let body: @Sendable @concurrent (Bool) async -> HiddenOpaqueObject? = { present in
        await Task.yield()
        return present ? HiddenOpaqueObject(token, 42) : nil
    }
    return body
}

@inline(never) public func makeOpaqueTupleClosure() -> ((Int64, String, ErrorToken)) -> some Any {
    let body: ((Int64, String, ErrorToken)) -> String = { value in
        withExtendedLifetime(value.2) { "\(value.0):\(value.1)" }
    }
    return body
}
@inline(never) public func makeOpaqueConsumingTupleClosure() -> (consuming (Int64, String, ErrorToken)) -> some Any {
    let body: (consuming (Int64, String, ErrorToken)) -> String = { (value: consuming (Int64, String, ErrorToken)) in
        withExtendedLifetime(value.2) { "\(value.0):\(value.1)" }
    }
    return body
}

public protocol RuntimeExtendedLeft<Element> { associatedtype Element }
public protocol RuntimeExtendedRight<Element> { associatedtype Element }
private struct RuntimeExtendedBoth: RuntimeExtendedLeft, RuntimeExtendedRight, CustomStringConvertible {
    typealias Element = Int
    var description: String { "both" }
}
@inline(never) public func makeLeftConstrainedComposition() -> any RuntimeExtendedLeft<Int> & RuntimeExtendedRight { RuntimeExtendedBoth() }
@inline(never) public func makeRightConstrainedComposition() -> any RuntimeExtendedLeft & RuntimeExtendedRight<Int> { RuntimeExtendedBoth() }

public enum RuntimeTicketFailure: Error { case rejected }
#if hasFeature(Lifetimes)
public protocol RuntimeScopedReadable: ~Copyable, ~Escapable {
    borrowing func read() -> Int64
}
public final class RuntimeScopedOwner {
    public var number: Int64
    public let counts: ArgumentCounts
    public init(_ number: Int64, _ counts: ArgumentCounts) { self.number = number; self.counts = counts }
    @_lifetime(borrow self)
    @inline(never) public func scoped() -> some RuntimeScopedReadable & ~Copyable & ~Escapable {
        RuntimeScopedResult(self)
    }
    @_lifetime(borrow self)
    @inline(never) public nonisolated(nonsending) func scopedAsync() async -> some RuntimeScopedReadable & ~Copyable & ~Escapable {
        await Task.yield()
        return RuntimeScopedResult(self)
    }
}
public struct RuntimeScopedResult: ~Copyable, ~Escapable, RuntimeScopedReadable {
    private let owner: Unmanaged<RuntimeScopedOwner>
    private let counts: ArgumentCounts
    @_lifetime(borrow owner)
    public init(_ owner: borrowing RuntimeScopedOwner) {
        self.owner = .passUnretained(owner); counts = owner.counts
    }
    public borrowing func read() -> Int64 { owner.takeUnretainedValue().number }
    deinit { counts.destroyed() }
}
@_lifetime(borrow owner)
@inline(never) public func makeRuntimeScoped(_ owner: borrowing RuntimeScopedOwner, _ fail: Bool) throws -> some RuntimeScopedReadable & ~Copyable & ~Escapable {
    if fail { throw RuntimeTicketFailure.rejected }
    return RuntimeScopedResult(owner)
}
@_lifetime(borrow owner)
@inline(never) public nonisolated(nonsending) func makeRuntimeScopedAsync(_ owner: borrowing RuntimeScopedOwner, _ fail: Bool) async throws -> some RuntimeScopedReadable & ~Copyable & ~Escapable {
    await Task.yield()
    if fail || Task.isCancelled { throw RuntimeTicketFailure.rejected }
    return RuntimeScopedResult(owner)
}
#endif
