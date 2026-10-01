import ManagedSwiftFixtures

@inline(never) public func probeGenericBool(_ apply: () -> Bool) -> Bool { runGeneric(apply) }
@inline(never) public func probeGenericString(_ value: String) -> String { echoGeneric(value) }
@inline(never) public func probeGenericCallback<Value>(_ apply: () -> Value) -> Value { apply() }
@inline(never) public func probeBorrowedCallback(_ body: (RuntimeRecord) -> Void, _ value: RuntimeRecord) { body(value) }
@inline(never) public func probeBorrowedGetter(_ value: RuntimeRecord) -> String { value.text }
@inline(never) public func probeBorrowedMethod(_ value: RuntimeRecord) { value.cancel() }
