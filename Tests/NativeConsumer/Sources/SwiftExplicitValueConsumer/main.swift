import ABIBridge

public final class Payload {}

@frozen public struct Record: ABIBridgeSwiftValue {
    public let payload: Payload
    public let number: Double
    public static let swiftABIType = try! NativeType.structure(named: "Record", fields: [.pointer, .double])
}
@frozen public enum Choice: ABIBridgeSwiftValue {
    case number(Int64), payload(Payload), empty
    public static let swiftABIType = try! NativeType.structure(named: "Choice",
        fields: Array(repeating: .uint, count: MemoryLayout<Int64>.size / MemoryLayout<UInt>.size) + [.uint8])
}
@inline(never) public func change(_ record: Record) -> Record {
    Record(payload: record.payload, number: record.number + 1)
}
@inline(never) public func apply(_ callback: (Choice) -> Choice, _ value: Choice) -> Choice { callback(value) }

@frozen public struct Box<Value> {
    public let value: Value
}
extension Box: ABIBridgeSwiftValue where Value == Int64 {
    public static var swiftABIType: NativeType { .int64 }
}
@inline(never) public func applyBox(_ callback: (Box<Int64>) -> Box<Int64>, _ value: Box<Int64>) -> Box<Int64> {
    callback(value)
}

let runtime = ABIRuntime()
let transform = try await runtime.swiftFunction(named: "SwiftExplicitValueConsumer.change(_:)", as: ((Record) -> Record).self)
let apply = try await runtime.swiftFunction(
    named: "SwiftExplicitValueConsumer.apply(_:_:)",
    as: ((NativeSwiftClosure<Choice, Choice>, Choice) -> Choice).self
)
let identity = try NativeSwiftClosure<Choice, Choice> { $0 }
weak var observed: Payload?
var result: Choice?
do {
    let payload = Payload()
    observed = payload
    let record = try unsafe transform.unsafeInvoke(Record(payload: payload, number: 41))
    precondition(record.payload === payload && record.number == 42)
    result = try unsafe apply.unsafeInvoke(identity, .payload(payload))
}
withExtendedLifetime(result) { precondition(observed != nil) }
result = nil
precondition(observed == nil)
let boxed = try await runtime.swiftFunction(
    named: "SwiftExplicitValueConsumer.applyBox(_:_:)",
    as: ((NativeSwiftClosure<Box<Int64>, Box<Int64>>, Box<Int64>) -> Box<Int64>).self
)
let boxBody = try NativeSwiftClosure { (value: Box<Int64>) in Box(value: value.value + 7) }
let boxResult = try unsafe boxed.unsafeInvoke(boxBody, Box(value: 35))
precondition(boxResult.value == 42)
print("Explicit Swift value consumer passed")
