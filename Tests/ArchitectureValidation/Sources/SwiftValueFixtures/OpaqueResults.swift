import Foundation

@inline(never) public func borrowRuntimeValue<T: ~Copyable>(_ value: borrowing T) -> Int64 { Int64(MemoryLayout<T>.size) }
@inline(never) public func moveRuntimeValue<T: ~Copyable>(_ value: consuming T) -> T { value }
@inline(never) public func copyRuntimeValue<T>(_ value: T) -> T { value }
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
