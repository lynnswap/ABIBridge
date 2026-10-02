import ManagedSwiftFixtures

@inline(never) public func probeBorrowedTupleCallback(
    _ body: (RuntimeRecord) -> (Int64, Int64), _ value: RuntimeRecord
) -> (Int64, Int64) { body(value) }

@inline(never) public func probeNeverError() -> Int64 { genericErrorType(Never.self) }
@inline(never) public func probeExistentialError() throws -> Int64 { try genericErrorType((any Error).self) }
@inline(never) public func probeNeverErrorCallback(_ body: () -> Int64) -> Int64 { genericErrorCallback(body) }
@inline(never) public func probeExistentialErrorCallback(_ body: () throws -> Int64) throws -> Int64 {
    try genericErrorCallback(body)
}

@inline(never) public func probeThinMetatype(_ body: (Int64.Type) -> Int64.Type) -> Int64.Type { body(Int64.self) }
@inline(never) public func probeThickMetatype<Value>(_ body: (Value.Type) -> Value.Type, _ type: Value.Type) -> Value.Type { body(type) }
@inline(never) public func probeOptionalMetatype(_ body: (Int64.Type?) -> Int64.Type?) -> Int64.Type? { body(Int64.self) }
@inline(never) public func probeExistentialMetatype(_ body: (any CustomStringConvertible.Type) -> any CustomStringConvertible.Type) -> any CustomStringConvertible.Type { body(Int64.self) }
@inline(never) public func probeOptionalExistentialMetatype(_ body: ((any CustomStringConvertible.Type)?) -> (any CustomStringConvertible.Type)?) -> (any CustomStringConvertible.Type)? { body(Int64.self) }

@inline(never) public func probeGenericBool(_ apply: () -> Bool) -> Bool { runGeneric(apply) }
@inline(never) public func probeGenericString(_ value: String) -> String { echoGeneric(value) }
@inline(never) public func probeGenericCallback<Value>(_ apply: () -> Value) -> Value { apply() }
@inline(never) public func probeBorrowedCallback(_ body: (RuntimeRecord) -> Void, _ value: RuntimeRecord) { body(value) }
@inline(never) public func probeBorrowedGetter(_ value: RuntimeRecord) -> String { value.text }
@inline(never) public func probeBorrowedMethod(_ value: RuntimeRecord) { value.cancel() }
@inline(never) public func probeGenericTupleCallback<Value>(
    _ body: ((Value, Int8)) -> (Value, Int8, Int8), _ value: (Value, Int8)
) -> (Value, Int8, Int8) { body(value) }
@inline(never) public func probeConcreteTupleCallback(
    _ body: ((String, Int8)) -> (String, Int8, Int8), _ value: (String, Int8)
) -> (String, Int8, Int8) { body(value) }
@inline(never) public func probeGenericPackCallback<each Value>(
    _ body: (repeat each Value) -> (repeat each Value), _ values: repeat each Value
) -> (repeat each Value) { body(repeat each values) }
@inline(never) public func probeLargeFixedCallback(
    _ body: (LargeManagedValue) -> LargeManagedValue, _ value: LargeManagedValue
) -> LargeManagedValue { body(value) }
