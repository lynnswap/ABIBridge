import ABIBridge
import SwiftValueFixtures

@MainActor func validateSwiftThrowingClosures() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let apply = try await runtime.swiftFunction(named: "SwiftValueFixtures.applySmallThrowing(_:_:)",
        as: ((NativeSwiftClosure<(Int64) throws(SmallError) -> Int64>, Int64) throws(SmallError) -> Int64).self)
    let callback = try NativeSwiftClosure<(Int64) throws(SmallError) -> Int64> { (value: Int64) throws(SmallError) in
        if value < 0 { throw SmallError(0) }
        return value + 7
    }
    try check(try unsafe apply.unsafeInvoke(callback, 35) == 42, "Compiled native caller invokes the generated throwing closure")
    do {
        _ = try unsafe apply.unsafeInvoke(callback, -1)
        throw ArchitectureValidationFailure(description: "Expected typed callback failure")
    } catch let error as NativeSwiftError {
        try error.withUnderlyingError { try check(($0 as? SmallError)?.code == 0, "Zero-valued callback error uses the native error indicator") }
    }
    let large = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyLargeThrowing(_:_:_:)",
        as: ((NativeSwiftClosure<(ErrorToken, Bool) throws(LargeError) -> LargeError>, ErrorToken, Bool) throws(LargeError) -> LargeError).self)
    let largeBody = try NativeSwiftClosure<(ErrorToken, Bool) throws(LargeError) -> LargeError> {
        (token: ErrorToken, fail: Bool) throws(LargeError) in
        if fail { throw LargeError(token) }
        return LargeError(token)
    }
    let token = ErrorToken()
    let output = try unsafe large.unsafeInvoke(largeBody, token, false)
    try check(output.token === token && output.d == 4, "Throwing closure preserves indirect result ownership")
    do {
        _ = try unsafe large.unsafeInvoke(largeBody, token, true)
        throw ArchitectureValidationFailure(description: "Expected indirect callback error")
    } catch let error as NativeSwiftError {
        try error.withUnderlyingError { try check(($0 as? LargeError)?.token === token, "Throwing closure transfers an independent indirect error") }
    }
    let make = try await runtime.swiftFunction(named: "SwiftValueFixtures.returnSmallThrowing(_:)",
        as: ((ErrorToken) -> NativeSwiftClosure<(Int64) throws(SmallError) -> Int64>).self)
    weak var observed: ErrorToken?
    var returned: NativeSwiftClosure<(Int64) throws(SmallError) -> Int64>?
    do {
        let capture = ErrorToken()
        observed = capture
        returned = try unsafe make.unsafeInvoke(capture)
    }
    try check(observed != nil && (try unsafe returned?.unsafeInvoke(35)) == 42, "Returned throwing closure retains its native capture")
    let retain = try await runtime.swiftFunction(named: "SwiftValueFixtures.retainSmallThrowing(_:)",
        as: ((NativeSwiftClosure<(Int64) throws(SmallError) -> Int64>) -> ThrowingValueHolder).self)
    var stored = try unsafe retain.unsafeInvoke(returned!)
    returned = nil
    try check(try stored.value(35) == 42 && observed != nil, "Native escaping storage owns the forwarded throwing closure")
    stored = ThrowingValueHolder { (value: Int64) throws(SmallError) in value }
    try check(observed == nil, "Final native closure release destroys its capture")
    return checks
}
