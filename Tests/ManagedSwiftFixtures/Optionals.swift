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
