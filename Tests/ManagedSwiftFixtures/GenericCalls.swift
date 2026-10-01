@inline(never) public func runGeneric<Value>(_ apply: () -> Value) -> Value { apply() }
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
