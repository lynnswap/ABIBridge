public final class LifetimeToken {
    private let onDestroy: () -> Void

    public init(onDestroy: @escaping () -> Void = {}) { self.onDestroy = onDestroy }
    deinit { onDestroy() }
}

@frozen public struct ManagedRecord {
    public let token: LifetimeToken
    public let number: Int64

    public init(token: LifetimeToken, number: Int64) {
        self.token = token
        self.number = number
    }
}

// This target enables library evolution. Clients must not know this layout.
public struct ResilientRecord {
    private let payload: ManagedRecord

    public init(token: LifetimeToken, number: Int64) {
        payload = ManagedRecord(token: token, number: number)
    }

    public var token: LifetimeToken { payload.token }
    public var number: Int64 { payload.number }
}

@inline(never) public func transformManaged(_ value: ManagedRecord) -> ManagedRecord {
    ManagedRecord(token: value.token, number: value.number + 1)
}

@inline(never) public func transformOptional(_ value: Int64?) -> Int64? {
    value.map { $0 + 1 }
}

@inline(never) public func transformResilient(_ value: ResilientRecord) -> ResilientRecord {
    ResilientRecord(token: value.token, number: value.number + 1)
}

/// Library evolution does not record whether a public struct with a String
/// field is frozen; its frozen lowering takes five registers.
public struct WideLabel {
    public var name: String
    public var a: Int64
    public var b: Int64
    public var c: Int64
    public init(name: String, a: Int64) { self.name = name; self.a = a; b = a + 1; c = a + 2 }
}

@inline(never) public func describeWideLabel(_ value: WideLabel) -> String {
    "\(value.name):\(value.a),\(value.b),\(value.c)"
}

@inline(never) public func makeWideLabel(_ name: String) -> WideLabel { WideLabel(name: name, a: 1) }

@inline(never) public func applyWideLabel(
    _ callback: (WideLabel) -> WideLabel, _ value: WideLabel
) -> String { describeWideLabel(callback(value)) }

@inline(never) public func describeWideLabelPair(_ pair: (WideLabel, Int64)) -> String {
    describeWideLabel(pair.0) + "#\(pair.1)"
}

@inline(never) public func makeWideLabelPair(_ name: String) -> (WideLabel, Int64) {
    (makeWideLabel(name), 8)
}

extension Int {
    /// A class whose demangled name leads with the extension that nests it.
    public final class RuntimeNestedCounter {
        public init() {}
        public func value() -> Int { 7 }
    }
}

/// A class with a method that a class's allocating initializer would spell.
public final class RuntimeAllocatorNamedMethod {
    public init() {}
    public func __allocating_init(_ value: Int64) -> Int64 { value + 1 }
}

/// A function that a class's allocating initializer would spell.
@inline(never) public func __allocating_init(_ value: Int64) -> Int64 { value + 2 }
