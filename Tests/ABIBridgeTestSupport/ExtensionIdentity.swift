extension Int {
    @frozen public struct RuntimeExtensionIdentity<Value> {
        public var value: Value
        public init(_ value: Value) { self.value = value }
    }
}

public typealias SupportExtensionIdentity = Int.RuntimeExtensionIdentity<Int64>
