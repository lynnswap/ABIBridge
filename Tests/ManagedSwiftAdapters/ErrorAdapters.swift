import ManagedSwiftFixtures

// On success only result is initialized; on failure only the exact Error type
// is initialized. All pointers refer to distinct, correctly aligned storage.
@inline(never) public func captureThrowingResult<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result, result: UnsafeMutableRawPointer, failure: UnsafeMutableRawPointer
) -> Bool {
    do {
        result.bindMemory(to: Result.self, capacity: 1).initialize(to: try body())
        return true
    } catch {
        failure.bindMemory(to: Failure.self, capacity: 1).initialize(to: error)
        return false
    }
}

@_cdecl("ABIUntypedErrorCall")
public func untypedErrorCall(_ token: UnsafeRawPointer, _ fail: Bool,
                             _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ try untypedResult(value, fail) }, result: result, failure: failure)
}
@_cdecl("ABIScalarErrorCall")
public func scalarErrorCall(_ token: UnsafeRawPointer, _ fail: Bool,
                            _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ () throws(ScalarFailure) -> String in try scalarErrorResult(value, fail) },
                                 result: result, failure: failure)
}
@_cdecl("ABIFloatingErrorCall")
public func floatingErrorCall(_ token: UnsafeRawPointer, _ fail: Bool,
                              _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ () throws(FloatingFailure) -> String in try floatingErrorResult(value, fail) },
                                 result: result, failure: failure)
}
@_cdecl("ABIScalarErrorFloatingCall")
public func scalarErrorFloatingCall(_ token: UnsafeRawPointer, _ fail: Bool,
                                   _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ () throws(ScalarFailure) -> Double in try scalarErrorFloatingResult(value, fail) },
                                 result: result, failure: failure)
}
@_cdecl("ABIScalarErrorVoidCall")
public func scalarErrorVoidCall(_ token: UnsafeRawPointer, _ fail: Bool,
                               _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ () throws(ScalarFailure) -> Void in try scalarErrorVoidResult(value, fail) },
                                 result: result, failure: failure)
}

@_cdecl("ABIManagedErrorCall")
public func managedErrorCall(_ token: UnsafeRawPointer, _ fail: Bool,
                             _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ () throws(ManagedFailure) -> String in try managedErrorResult(value, fail) },
                                 result: result, failure: failure)
}
@_cdecl("ABILargeErrorCall")
public func largeErrorCall(_ token: UnsafeRawPointer, _ fail: Bool,
                           _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ () throws(LargeFailure) -> String in try largeErrorResult(value, fail) },
                                 result: result, failure: failure)
}
@_cdecl("ABIResilientErrorCall")
public func resilientErrorCall(_ token: UnsafeRawPointer, _ fail: Bool,
                               _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ () throws(ResilientFailure) -> String in try resilientErrorResult(value, fail) },
                                 result: result, failure: failure)
}
@_cdecl("ABIReferenceErrorCall")
public func referenceErrorCall(_ token: UnsafeRawPointer, _ fail: Bool,
                               _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ () throws(ReferenceFailure) -> String in try referenceErrorResult(value, fail) },
                                 result: result, failure: failure)
}
@_cdecl("ABIBothIndirectErrorCall")
public func bothIndirectErrorCall(_ token: UnsafeRawPointer, _ fail: Bool,
                                  _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ () throws(LargeFailure) -> ErrorSuccessPayload in try bothIndirectResult(value, fail) },
                                 result: result, failure: failure)
}
@_cdecl("ABICocoaErrorCall")
public func cocoaErrorCall(_ token: UnsafeRawPointer, _ fail: Bool,
                          _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ try cocoaErrorResult(value, fail) }, result: result, failure: failure)
}

@_cdecl("ABIThrowingInitializer")
public func throwingInitializer(_ token: UnsafeRawPointer, _ fail: Bool,
                                _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ErrorLifetimeToken>.fromOpaque(token).takeUnretainedValue()
    return captureThrowingResult({ () throws(ManagedFailure) -> ThrowingOwner in try ThrowingOwner(value, fail) },
                                 result: result, failure: failure)
}
@_cdecl("ABIThrowingMember")
public func throwingMember(_ owner: UnsafeRawPointer, _ fail: Bool,
                           _ result: UnsafeMutableRawPointer, _ failure: UnsafeMutableRawPointer) -> Bool {
    let value = Unmanaged<ThrowingOwner>.fromOpaque(owner).takeUnretainedValue()
    return captureThrowingResult({ () throws(ManagedFailure) -> String in try value.value(fail) },
                                 result: result, failure: failure)
}
