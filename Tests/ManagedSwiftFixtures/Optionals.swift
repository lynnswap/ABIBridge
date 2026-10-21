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
