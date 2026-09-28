import ABIBridge
import Foundation
import SwiftValueFixtures
import Synchronization

extension SmallError: ABIBridgeSwiftValue { public static var swiftABIType: NativeType { .int64 } }
extension FloatingError: ABIBridgeSwiftValue { public static var swiftABIType: NativeType { .double } }
extension IndirectError: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { try! .opaque(named: "IndirectError") }
}
extension LargeError: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "LargeError", fields: [.pointer, .int64, .int64, .int64, .int64])
    }
}
extension ErrorCounter: ABIBridgeSwiftValue { public static var swiftABIType: NativeType { .int64 } }

@MainActor func validateSwiftErrors() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    func failure<Value>(_ body: () throws -> Value) throws -> NativeSwiftError {
        do {
            _ = try body()
            throw ArchitectureValidationFailure(description: "Native call unexpectedly succeeded")
        } catch let error as NativeSwiftError { return error }
    }
    let untyped = try await runtime.swiftFunction(named: "SwiftValueFixtures.untypedError(_:_:)",
        as: ((ErrorToken, Bool) throws -> String).self)
    weak var observed: ErrorToken?
    var held: NativeSwiftError?
    try autoreleasepool {
        let token = ErrorToken()
        observed = token
        try check(try unsafe untyped.unsafeInvoke(token, false) == String(repeating: "owned", count: 100),
                  "Throwing success returns an owned String")
        held = try failure { try unsafe untyped.unsafeInvoke(token, true) }
        try held?.withUnderlyingError {
            let error = $0 as NSError
            try check(error.domain == "DeviceError" && error.code == 42 &&
                error.userInfo["token"] as? ErrorToken === token, "Untyped NSError preserves native identity and userInfo")
        }
    }
    try withExtendedLifetime(held) { try check(observed != nil, "Error wrapper retains native payload") }
    held = nil
    try check(observed == nil, "Final error release destroys the payload")
    let small = try await runtime.swiftFunction(named: "SwiftValueFixtures.smallError(_:)",
        as: ((Bool) throws(SmallError) -> Double).self)
    try check(try unsafe small.unsafeInvoke(false) == 1.5, "Normal floating result uses its register bank")
    let smallFailure = try failure { try unsafe small.unsafeInvoke(true) }
    try smallFailure.withUnderlyingError {
        try check(($0 as? SmallError)?.code == 0, "Zero-valued typed error uses a separate failure indicator")
    }
    let floating = try await runtime.swiftFunction(named: "SwiftValueFixtures.floatingError(_:)",
        as: ((Bool) throws(FloatingError) -> Void).self)
    try unsafe floating.unsafeInvoke(false)
    let floatingFailure = try failure { try unsafe floating.unsafeInvoke(true) }
    try floatingFailure.withUnderlyingError {
        try check(($0 as? FloatingError)?.value == 1.5, "Floating error uses the hidden output buffer")
    }
    let indirect = try await runtime.swiftFunction(named: "SwiftValueFixtures.indirectError(_:_:)",
        as: ((ErrorToken, Bool) throws(IndirectError) -> String).self)
    let token = ErrorToken()
    try check(try unsafe indirect.unsafeInvoke(token, false) == "success", "Resilient-error signature preserves success")
    let indirectFailure = try failure { try unsafe indirect.unsafeInvoke(token, true) }
    try indirectFailure.withUnderlyingError {
        try check(($0 as? IndirectError)?.token === token, "Resilient native error is taken from indirect storage")
    }
    let large = try await runtime.swiftFunction(named: "SwiftValueFixtures.largeError(_:_:)",
        as: ((ErrorToken, Bool) throws(LargeError) -> LargeError).self)
    let result = try unsafe large.unsafeInvoke(token, false)
    try check(result.token === token && result.d == 4, "Large result has independent indirect storage")
    let largeFailure = try failure { try unsafe large.unsafeInvoke(token, true) }
    try largeFailure.withUnderlyingError {
        try check(($0 as? LargeError)?.token === token && ($0 as? LargeError)?.d == 4,
                  "Large error uses its own indirect storage")
    }
    let type = try await runtime.swiftType(named: "SwiftValueFixtures.ErrorCounter", as: ErrorCounter.self)
    let advance = try await type.method(named: "advance(_:)",
        as: ((Bool) throws(SmallError) -> Int64).self, mutating: true)
    var counter = ErrorCounter(41)
    let mutationFailure = try failure { try unsafe advance.unsafeInvoke(on: &counter, true) }
    try mutationFailure.withUnderlyingError {
        try check(counter.count == 42 && ($0 as? SmallError)?.code == 42,
                  "Mutating receiver writes back before native failure propagates")
    }
    return checks
}
