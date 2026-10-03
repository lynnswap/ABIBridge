import ManagedSwiftFixtures

public struct GuaranteedClosureInitializer {
    public let value: Int64
    public init(_ body: IntegerClosure) { value = body(35) }
}

@inline(never) public func consumeEscapingClosure(_ body: consuming @escaping IntegerClosure) -> Int64 {
    body(35)
}

@_cdecl("ABIIntegerClosureApply")
public func integerClosureApply(_ input: UnsafeRawPointer, _ value: Int64) -> Int64 {
    applyIntegerClosure(input.load(as: IntegerClosure.self), value)
}

@_cdecl("ABIIntegerClosureRetain")
public func integerClosureRetain(_ input: UnsafeRawPointer) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(retainIntegerClosure(input.load(as: IntegerClosure.self))).toOpaque()
}

@_cdecl("ABIIntegerClosureCallRetained")
public func integerClosureCallRetained(_ input: UnsafeRawPointer, _ value: Int64) -> Int64 {
    Unmanaged<StoredIntegerClosure>.fromOpaque(input).takeUnretainedValue()(value)
}

@_cdecl("ABIIntegerClosureRelease")
public func integerClosureRelease(_ input: UnsafeMutableRawPointer) {
    Unmanaged<StoredIntegerClosure>.fromOpaque(input).release()
}

@_cdecl("ABIIntegerClosureReturn")
public func integerClosureReturn(_ token: UnsafeRawPointer, _ bias: Int64, _ output: UnsafeMutableRawPointer) {
    let token = Unmanaged<LifetimeToken>.fromOpaque(token).takeUnretainedValue()
    output.bindMemory(to: IntegerClosure.self, capacity: 1).initialize(to: makeIntegerClosure(token, bias))
}

@_cdecl("ABISendableIntegerClosureApply")
public func sendableIntegerClosureApply(_ input: UnsafeRawPointer, _ value: Int64) -> Int64 {
    applySendableIntegerClosure(input.load(as: SendableIntegerClosure.self), value)
}

// The caller supplies the actor contract; a C symbol does not encode it.
@MainActor @_cdecl("ABIIsolatedIntegerClosureApply")
public func isolatedIntegerClosureApply(_ input: UnsafeRawPointer, _ value: Int64) -> Int64 {
    applyIsolatedIntegerClosure(input.load(as: IsolatedIntegerClosure.self), value)
}

@inline(never) public func invokeGenericClosure<Argument, Result>(
    _ callback: (Argument) -> Result, _ argument: Argument
) -> Result {
    callback(argument)
}

@inline(never) public func concreteThroughGeneric(_ callback: IntegerClosure, _ value: Int64) -> Int64 {
    invokeGenericClosure(callback, value)
}
