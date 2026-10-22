import Dispatch

@inline(never) public func doubledOptional(_ value: Double?) -> Double? { value.map { $0 * 2 } }

@inline(never) public func invertedOptional(_ value: Bool?) -> Bool? { value.map { !$0 } }

@inline(never) public func incrementedNestedOptional(_ value: Int64??) -> Int64?? {
    value.map { $0.map { $0 + 1 } }
}

@inline(never) public func swappedOptionalPair(_ value: (Int64, Double)?) -> (Double, Int64)? {
    value.map { ($0.1, $0.0) }
}

@inline(never) public func applyOptionalClosure(_ body: ((Int64) -> Int64)?, _ value: Int64) -> Int64 {
    body?(value) ?? -1
}

@inline(never) public func makeOptionalClosure(_ enabled: Bool) -> ((Int64) -> Int64)? {
    enabled ? { $0 + 1 } : nil
}

@inline(never) public func passOptionalClosures(_ body: (((Int64) -> Int64)?) -> Int64) -> Int64 {
    body(nil) * 100 + body({ $0 * 10 })
}

@inline(never) public func firstOptionalFloat(_ value: (Float, Float, Float, Float, Float)?) -> Float {
    value?.0 ?? -1
}

@inline(never) public func areOptionalMetatypesNil(_ value: (Int.Type, Int.Type)?) -> Bool { value == nil }

@inline(never) public func applyNestedOptionalClosure(_ body: ((Int64) -> Int64)??) -> Int64 {
    (body ?? nil)?(1) ?? -1
}

@inline(never) public func replaceOptionalClosure(_ body: inout ((Int64) -> Int64)?, _ owner: AnyObject) {
    body = { value in withExtendedLifetime(owner) { value + 1 } }
}

@inline(never) public func makeOptionalClosureFactory() -> () -> (() -> Int64)? {
    { { 7 } }
}

@inline(never) public func passStaleNilClosure(
    _ body: (inout ((Int64) -> Int64)?) throws -> Void,
    _ owner: AnyObject
) throws -> Bool {
    var closure: ((Int64) -> Int64)? = nil
    // Nil is a null function pointer; Swift leaves the context word unspecified.
    withUnsafeMutableBytes(of: &closure) {
        $0.storeBytes(
            of: Unmanaged.passUnretained(owner).toOpaque(),
            toByteOffset: MemoryLayout<UInt>.size,
            as: UnsafeMutableRawPointer.self
        )
    }
    try body(&closure)
    return closure == nil
}

@inline(never) public func applyGenericOptionalClosure<Value>(_ body: ((Value) -> Value)?, _ value: Value) -> Value {
    body?(value) ?? value
}

@inline(never) public func makeGenericOptionalChecker<Value>(
    _: Value.Type
) -> (Value, ((Int64) -> Int64)?) -> Int64 {
    { _, body in body == nil ? -1 : 1 }
}

@inline(never) public func checkNilOptionalClosure(_ checker: (Int64, ((Int64) -> Int64)?) -> Int64) -> Int64 {
    checker(0, nil)
}

@inline(never) public func applyEscapingClosure(_ body: @escaping (Int64) -> Int64) -> Int64 { body(1) }

// Runtime-only values: tests reach these types only through NativeSwiftValue.
public struct OptionalRuntimeRecord {
    public var name: String
    public var count: Int64
    public init(name: String, count: Int64) { self.name = name; self.count = count }
}

@frozen public struct OptionalFrozenRecord {
    public var name: String
    public var count: Int64
    public init(name: String, count: Int64) { self.name = name; self.count = count }
}

@inline(never) public func makeOptionalRuntimeRecord(_ count: Int64) -> OptionalRuntimeRecord? {
    count < 0 ? nil : OptionalRuntimeRecord(name: "record", count: count)
}

@inline(never) public func describeOptionalRuntimeRecord(_ record: OptionalRuntimeRecord?) -> String {
    record.map { "\($0.name)#\($0.count)" } ?? "nil"
}

@inline(never) public func bumpOptionalRuntimeRecord(_ record: consuming OptionalRuntimeRecord?) -> OptionalRuntimeRecord? {
    record.map { OptionalRuntimeRecord(name: $0.name, count: $0.count + 1) }
}

@inline(never) public func visitOptionalRuntimeRecords(
    _ body: (OptionalRuntimeRecord?) throws -> OptionalRuntimeRecord?
) rethrows -> String {
    try [body(nil), body(OptionalRuntimeRecord(name: "visit", count: 1))]
        .map(describeOptionalRuntimeRecord).joined(separator: ",")
}

@inline(never) public func makeOptionalFrozenRecord(_ count: Int64) -> OptionalFrozenRecord? {
    count < 0 ? nil : OptionalFrozenRecord(name: "frozen", count: count)
}

@inline(never) public func describeOptionalFrozenRecord(_ record: OptionalFrozenRecord?) -> String {
    record.map { "\($0.name)#\($0.count)" } ?? "nil"
}

@inline(never) public func makeOptionalFrozenRecordPair(
    _ count: Int64
) -> (OptionalFrozenRecord?, Int64) {
    (makeOptionalFrozenRecord(count), count)
}

@inline(never) public func describeOptionalFrozenRecordPair(
    _ pair: (OptionalFrozenRecord?, Int64)
) -> String {
    describeOptionalFrozenRecord(pair.0) + "@\(pair.1)"
}

@inline(never) public func makeOptionalRuntimeRecordTuple(
    _ count: Int64
) -> (OptionalRuntimeRecord, Int64)? {
    count < 0 ? nil : (OptionalRuntimeRecord(name: "record", count: count), count + 1)
}

@inline(never) public func describeOptionalRuntimeRecordTuple(
    _ pair: (OptionalRuntimeRecord, Int64)?
) -> String {
    pair.map { "\($0.0.name)#\($0.0.count)@\($0.1)" } ?? "nil"
}

// Optionals of scalars and pointers pass as their enum storage: `UInt32?` as
// one integer, `Int64?` and `Double?` as a payload and a tag byte, `Bool?` in
// its payload's spare bits, and a pointer with nil as the null pointer.
@inline(never) public func incrementedOptionalUInt32(_ value: UInt32?) -> UInt32? {
    value.map { $0 &+ 1 }
}

@inline(never) public func negatedOptionalInt64(_ value: Int64?) -> Int64? { value.map { -$0 } }

@inline(never) public func advancedOptionalPointer(
    _ pointer: UnsafePointer<Int64>?
) -> UnsafePointer<Int64>? {
    pointer.map { $0 + 1 }
}

@inline(never) public func describeOptionalScalars(
    _ id: UInt32?,
    _ count: Int64?,
    _ scale: Double?,
    _ flag: Bool?,
    _ pointer: UnsafeRawPointer?
) -> String {
    [
        id.map { "\($0)" }, count.map { "\($0)" }, scale.map { "\($0)" }, flag.map { "\($0)" },
        pointer.map { "\($0.load(as: Int64.self))" },
    ].map { $0 ?? "nil" }.joined(separator: ",")
}

@inline(never) public func visitOptionalScalars(
    _ body: (UInt32?, Int64?, Double?, Bool?, UnsafeRawPointer?) -> String
) -> String {
    let some = withUnsafePointer(to: Int64(7)) {
        body(4_000_000_000, -5, 0.5, false, UnsafeRawPointer($0))
    }
    return body(nil, nil, nil, nil, nil) + "|" + some
}

@inline(never) public func makeOptionalScalarDescriber()
    -> (UInt32?, Int64?, Double?, Bool?, UnsafeRawPointer?) -> String
{
    { describeOptionalScalars($0, $1, $2, $3, $4) }
}

/// ABIBridgeTests gives `OptionalScreenNumber?` a wrong ABIBridgeSwiftValue
/// conformance, which applies to every use of that Optional in the tests.
@frozen public struct OptionalScreenNumber {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

@inline(never) public func nextOptionalScreenNumber(
    _ number: OptionalScreenNumber?
) -> OptionalScreenNumber? {
    number.map { OptionalScreenNumber(rawValue: $0.rawValue + 1) }
}

/// The shape of SimulatorKit's `SimDeviceScreenAdapter.register(screenID:queue:handler:)`.
public final class OptionalScreenAdapter {
    public final class Registration {
        public let screenID: UInt32?
        init(screenID: UInt32?) { self.screenID = screenID }
    }

    public let screens: [UInt32]
    public init(screens: [UInt32]) { self.screens = screens }

    /// Calls `handler` on `queue` with each screen that `screenID` selects; nil selects every screen.
    @inline(never) public func register(
        screenID: UInt32?,
        queue: DispatchQueue,
        handler: @escaping (UInt32?) -> Void
    ) -> Registration {
        let selected = screens.filter { screenID == nil || $0 == screenID }
        queue.sync { selected.forEach { handler($0) } }
        return Registration(screenID: screenID)
    }
}

extension Optional {
    /// The payload's size, or -1 for nil. A generic extension's method takes
    /// `self` by address, even when the Optional fits a register.
    @inline(never) public func optionalPayloadSize() -> Int64 {
        switch self {
        case .none: -1
        case .some: Int64(MemoryLayout<Wrapped>.size)
        }
    }
}

extension Optional where Wrapped == UInt32 {
    /// The screen ID, or -1 for nil. A concrete `self` passes as its enum storage.
    @inline(never) public func screenIDOrMinusOne() -> Int64 { map { Int64($0) } ?? -1 }
}
