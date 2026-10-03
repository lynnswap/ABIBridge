import Foundation

private struct HiddenOpaqueValue: ExistentialValue, ExistentialLabel {
    let token: ErrorLifetimeToken
    let number: Int64
    let message: String
    let numbers: [Int64]
    let vector: SIMD4<Float>
    var label: String { message }
    init(_ token: ErrorLifetimeToken, _ number: Int64) {
        self.token = token; self.number = number
        message = String(repeating: "opaque", count: 100)
        numbers = [number, number + 1]
        vector = SIMD4(repeating: Float(number))
    }
}
@inline(never) public func makeOpaque(_ token: ErrorLifetimeToken, _ number: Int64) -> some ExistentialValue & ExistentialLabel {
    HiddenOpaqueValue(token, number)
}
@inline(never) public func makeOpaqueInteger(_ number: Int64) -> some Any { number }
@inline(never) public func makeOpaqueEmpty() -> some Any { () }
@inline(never) public func makeNestedOpaque() -> () -> some Any {
    let body: () -> Int64 = { 42 }
    return body
}
@inline(never) public func makeOpaqueThrowing(_ token: ErrorLifetimeToken, _ fail: Bool) throws(ScalarFailure) -> some ExistentialValue {
    let value = HiddenOpaqueValue(token, 42)
    if fail { throw ScalarFailure(42) }
    return value
}
@inline(never) @concurrent public func makeOpaqueAsync(_ gate: AsyncGate, _ token: ErrorLifetimeToken, _ fail: Bool) async throws(ScalarFailure) -> some ExistentialValue {
    await gate.wait()
    let value = HiddenOpaqueValue(token, 42)
    if fail || Task.isCancelled { throw ScalarFailure(Task.isCancelled ? -1 : 42) }
    return value
}
public final class OpaqueOwner: Sendable {
    public let token: ErrorLifetimeToken
    public init(_ token: ErrorLifetimeToken) { self.token = token }
    public var summary: some ExistentialValue { HiddenOpaqueValue(token, 42) }
    @inline(never) public func make(_ number: Int64) -> some ExistentialValue { HiddenOpaqueValue(token, number) }
    @inline(never) public static func makeStatic(_ token: ErrorLifetimeToken) -> some ExistentialValue { HiddenOpaqueValue(token, 43) }
    @inline(never) @concurrent public func makeAsync(_ gate: AsyncGate) async -> some ExistentialValue {
        await gate.wait()
        return HiddenOpaqueValue(token, 44)
    }
}
private struct HiddenGenericOpaque<Value> { let value: Value }
@inline(never) public func makeGenericOpaque<Value>(_ value: Value) -> some Any { HiddenGenericOpaque(value: value) }
private struct HiddenNoncopyableOpaque: ~Copyable { let value: Int64 }
@inline(never) public func makeNoncopyableOpaque() -> some ~Copyable { HiddenNoncopyableOpaque(value: 42) }
@inline(never) public func makeCopyableNoncopyableOpaque() -> some ~Copyable { Int64(42) }
@inline(never) public func makeOpaqueRuntimeTicket(_ token: ErrorLifetimeToken) -> some ~Copyable {
    RuntimeTicket(token: token, number: 42)
}

public class OpaqueBase: @unchecked Sendable {
    public let token: ErrorLifetimeToken
    public let number: Int64
    public init(_ token: ErrorLifetimeToken, _ number: Int64) { self.token = token; self.number = number }
}
private final class HiddenOpaqueObject: OpaqueBase, ExistentialObjectValue, ExistentialValue, @unchecked Sendable {}
@inline(never) public func makeOpaqueClassAny(_ token: ErrorLifetimeToken) -> some AnyObject { HiddenOpaqueObject(token, 41) }
@inline(never) public func makeOpaqueClassProtocol(_ token: ErrorLifetimeToken) -> some ExistentialObjectValue { HiddenOpaqueObject(token, 42) }
@inline(never) public func makeOpaqueSuperclass(_ token: ErrorLifetimeToken) -> some OpaqueBase & ExistentialObjectValue { HiddenOpaqueObject(token, 43) }
@inline(never) public func makeOpaqueUnconstrainedClass(_ token: ErrorLifetimeToken) -> some ExistentialValue { HiddenOpaqueObject(token, 44) }
@inline(never) public func makeOpaqueClassThrowing(_ token: ErrorLifetimeToken, _ fail: Bool) throws(ScalarFailure) -> some ExistentialObjectValue {
    let object = HiddenOpaqueObject(token, 45)
    if fail { throw ScalarFailure(42) }
    return object
}
@inline(never) @concurrent public func makeOpaqueClassAsync(_ gate: AsyncGate, _ token: ErrorLifetimeToken) async -> some ExistentialObjectValue {
    await gate.wait()
    return HiddenOpaqueObject(token, 46)
}

private final class HiddenOpaqueObjC: NSObject {
    let token: ErrorLifetimeToken
    init(_ token: ErrorLifetimeToken) { self.token = token }
}
@inline(never) public func makeOpaqueObjC(_ token: ErrorLifetimeToken) -> some NSObjectProtocol { HiddenOpaqueObjC(token) }

private struct HiddenConstrainedOpaque<Value: ExistentialValue>: ExistentialValue {
    let value: Value
    var number: Int64 { value.number }
}
@inline(never) public func makeConstrainedOpaque<Value: ExistentialValue>(_ value: Value) -> some ExistentialValue {
    HiddenConstrainedOpaque(value: value)
}
@inline(never) public func makeGenericOpaqueObject<Value: ExistentialObjectValue>(_ value: Value) -> some ExistentialObjectValue {
    value
}
public final class GenericOpaqueOwner<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
    public var opaque: some Any { HiddenGenericOpaque(value: value) }
    @inline(never) public func make<Other>(_ other: Other) -> some Any {
        HiddenGenericOpaque(value: (value, other))
    }
}

@inline(never) public func makeGenericOpaquePair<First, Second>(_ first: First, _ second: Second) -> (some Any, some Any) {
    (first, second)
}
