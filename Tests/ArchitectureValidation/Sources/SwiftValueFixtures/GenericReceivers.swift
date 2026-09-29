import Foundation

public protocol GenericReceiverMetric { var text: String { get } }

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
    public var valueText: String { @inline(never) get { value.text } }
    @inline(never) public func projected() -> Value { value }
    @inline(never) public func echo(_ value: Value) -> Value { value }
    @inline(never) public func independent<Other>(_ value: Other) -> Other { value }
}

public final class InheritedGenericMemberReceiver: GenericMemberReceiver<GenericReceiverNumber> {}

extension GenericMemberReceiver where Value == GenericReceiverNumber {
    @inline(never) public func specialized(_ prefix: String) -> String { prefix + valueText }
    public var specializedText: String { @inline(never) get { valueText } }
}
extension GenericMemberReceiver where Value: CustomStringConvertible {
    @inline(never) public func witnessText() -> String { value.description }
}
