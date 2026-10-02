@inline(never) public func runGeneric<Value>(_ apply: () -> Value) -> Value { apply() }

@frozen public struct GenericMetatypeValue<Value> {}
@inline(never) public func valueMetatypeGeneric<Value>(
    _ type: GenericMetatypeValue<Value>.Type, _ value: Int64
) -> (GenericMetatypeValue<Value>.Type, Int64) { (type, value + 1) }
@inline(never) public func archetypeMetatypeGeneric<Value>(
    _ type: Value.Type, _ value: Int64
) -> (Value.Type, Int64) { (type, value + 2) }
@inline(never) public func callbackMetatypeGeneric<Value>(
    _ type: Value.Type, _ body: (Value.Type) -> Value.Type
) -> Value.Type { body(type) }
@inline(never) public func makeMetatypeClosureGeneric<Value>() -> (Value.Type) -> Value.Type { { $0 } }
@inline(never) public nonisolated(nonsending) func callbackAsyncMetatypeGeneric<Value>(
    _ type: Value.Type, _ body: (nonisolated(nonsending) (Value.Type) async -> Value.Type)
) async -> Value.Type { await body(type) }
@inline(never) public func makeAsyncMetatypeClosureGeneric<Value>() -> (nonisolated(nonsending) @Sendable (Value.Type) async -> Value.Type) {
    { type in await Task.yield(); return type }
}
@inline(never) public func concreteMetatype(_ pair: (Int64.Type, Int64)) -> (Int64.Type, Int64) { (pair.0, pair.1 + 3) }
@inline(never) public func optionalMetatype(_ type: Int64.Type?) -> Int64.Type? { type == nil ? Int64.self : nil }
@inline(never) public func optionalMetatypeGeneric<Value>(_ type: Value.Type?) -> Value.Type? { type }
@inline(never) public func optionalNominalMetatypeGeneric<Value>(
    _ type: GenericMetatypeValue<Value>.Type?, _ value: Value
) -> (GenericMetatypeValue<Value>.Type?, Int8, Value, Int8) {
    (type == nil ? GenericMetatypeValue<Value>.self : nil, 13, value, 14)
}
@inline(never) public func metatypeAndValueGeneric<Value>(_ value: Value) -> (Int64.Type, Value) { (Int64.self, value) }
@inline(never) public func echoGeneric<Value>(_ value: Value) -> Value { value }
@inline(never) public func chooseGeneric<Value>(_ value: Value, _ apply: () -> Value, _ useCallback: Bool) -> Value {
    useCallback ? apply() : value
}
@inline(never) public func countedGeneric<Value>(_ value: Value, _ extra: Int64, _ count: UnsafeMutablePointer<Int32>) -> Value {
    count.pointee += 1
    return value
}
public func referenceGenericBool(_ value: Bool) -> Bool { runGeneric { value } }
public func referenceGenericString(_ value: String) -> String { runGeneric { value + "!" } }

@inline(never) public func runAndVisitGeneric<Value>(
    _ apply: () -> Value, _ object: AnyObject, _ text: String,
    _ cancellations: UnsafeMutablePointer<Int32>, _ body: (RuntimeRecord) -> Void
) -> Value {
    let result = apply()
    visitRuntimeRecord(object, text, cancellations, body)
    return result
}


nonisolated(unsafe) private var savedGenericAction: (() -> Void)?
public func storeGeneric<Value>(_ apply: @escaping () -> Value) -> Value {
    savedGenericAction = { _ = apply() }
    return apply()
}
public func fireGeneric() { savedGenericAction?() }
public func clearGeneric() { savedGenericAction = nil }
public func genericCallbackThenArgument<Value>(_ apply: () -> Value, _ argument: Int64) -> Value { apply() }

@inline(never) public func equalGeneric<Value: Equatable>(_ left: Value, _ right: Value) -> Bool { left == right }
@inline(never) public func selectGeneric<Value, Values: Collection>(_ fallback: Value, _ values: Values) -> Value where Values.Element == Value {
    values.first ?? fallback
}
@inline(never) public func transformGeneric<Input, Output>(_ values: [Input], _ transform: (Input) throws -> Output) rethrows -> [Output] {
    try values.map(transform)
}
@inline(never) public func optionalGeneric<Value>(_ value: Value?) -> Value? { value }
@inline(never) public func makeClosureGeneric<Value>(_ value: Value) -> (Value) -> Value { { _ in value } }
@inline(never) public func makeOwnedClosureGeneric<Value>(_ value: Value) -> () -> Value { { value } }
@inline(never) public func makeThrowingClosureGeneric<Value, Failure: Error>(
    _ value: Value, _ failure: Failure
) -> (Bool) throws(Failure) -> Value {
    { shouldThrow throws(Failure) in if shouldThrow { throw failure }; return value }
}
@inline(never) public func makeAsyncClosureGeneric<Value: Sendable>(
    _ value: Value
) -> (nonisolated(nonsending) @Sendable (Value) async -> Value) {
    { _ in await Task.yield(); return value }
}
@inline(never) public func makePackClosureGeneric<each Value>() -> (repeat each Value) -> (repeat each Value) {
    { (values: repeat each Value) in (repeat each values) }
}
@inline(never) public func packGeneric<each Value>(_ values: repeat each Value) -> (repeat each Value) { (repeat each values) }
@inline(never) public func Rvz<Value, each Element>(_ value: Value, _ elements: repeat each Element) -> (Value, repeat each Element) {
    (value, repeat each elements)
}
@inline(never) public func constrainedPackGeneric<each Value: Equatable>(_ values: repeat each Value) -> (repeat each Value) {
    (repeat each values)
}
@inline(never) public func mixedPackGeneric<Value, each Element>(
    _ value: Value, _ elements: repeat each Element
) -> (Int8, Value, repeat each Element, Int8) { (1, value, repeat each elements, 2) }
@inline(never) public func nestedPackGeneric<each Value>(
    _ values: (Int8, repeat each Value, Int8)
) -> (Int8, repeat each Value, Int8) { values }
@inline(never) public func pairedPackGeneric<each First, each Second>(
    _ values: repeat (each First, each Second)
) -> (repeat (each Second, each First)) { (repeat ((each values).1, (each values).0)) }
@inline(never) public nonisolated(nonsending) func suspendedPackGeneric<each Value>(
    _ values: repeat each Value
) async -> (repeat each Value) { await Task.yield(); return (repeat each values) }
@inline(never) public func callbackPackGeneric<each Value>(
    _ body: (repeat each Value) -> (repeat each Value), _ values: repeat each Value
) -> (repeat each Value) { body(repeat each values) }
@inline(never) public func tupleGeneric<Value>(_ value: (Value, Int8, Int8)) -> (Value, Int8, Int8) { value }
@inline(never) public func pairGeneric<First, Second>(_ value: (First, Second)) -> (Second, First) { (value.1, value.0) }
@inline(never) public func largeTupleGeneric<Value>(_ value: (Value, LargeManagedValue, Int64)) -> (Value, LargeManagedValue, Int64) { value }
@inline(never) public func tupleCallbackGeneric<Value>(
    _ value: (Value, Int8), _ body: ((Value, Int8)) -> (Value, Int8, Int8)
) -> (Value, Int8, Int8) { body(value) }
@inline(never) public nonisolated(nonsending) func suspendedPairGeneric<First, Second>(
    _ value: (First, Second)
) async -> (Second, First) { await Task.yield(); return (value.1, value.0) }
@inline(never) public nonisolated(nonsending) func suspendedTransformGeneric<Input, Output>(
    _ value: Input, _ body: (nonisolated(nonsending) (Input) async throws -> (Output, Int8))
) async rethrows -> (Output, Int8) { try await body(value) }
@inline(never) public nonisolated(nonsending) func suspendedLargeTupleGeneric<Value>(
    _ value: (Value, LargeManagedValue, Int64)
) async -> (Value, LargeManagedValue, Int64) { await Task.yield(); return value }
@inline(never) public func genericFailure<Value, Failure: Error>(_ value: Value, _ failure: Failure, _ shouldThrow: Bool) throws(Failure) -> Value {
    if shouldThrow { throw failure }
    return value
}
@inline(never) public nonisolated(nonsending) func suspendedGeneric<Value>(_ value: Value) async -> Value {
    await Task.yield()
    return value
}
@inline(never) public nonisolated(nonsending) func suspendedGenericFailure<Value, Failure: Error>(
    _ value: Value, _ failure: Failure, _ shouldThrow: Bool
) async throws(Failure) -> Value {
    await Task.yield()
    if shouldThrow { throw failure }
    return value
}
