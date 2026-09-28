#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ObjectiveCFixtures
import ManagedSwiftFixtures
import Testing

private final class ThrowingCapture: Sendable {
    let token = ErrorLifetimeToken()
}
private func closureFailure<Value>(_ body: () throws -> Value) throws -> NativeSwiftError {
    do { _ = try body(); throw ABIResolutionError.unsupportedDeclaration("Expected native failure") }
    catch let error as NativeSwiftError { return error }
}

struct SwiftThrowingClosureTests {
#if DEBUG
    @Test func nonthrowingCallbacksPreserveTheCallersErrorRegister() throws {
        let normal = try NativeSwiftClosure<Int64, Int64> { $0 + 7 }
        #expect(ABIProbeSwiftErrorRegister(normal.closureStorage.implementation.function,
                                           normal.closureStorage.value.context) == 1)
        let never = try NativeSwiftThrowingClosure<Int64, Never, Int64> { $0 + 7 }
        #expect(ABIProbeSwiftErrorRegister(never.closureStorage.implementation.function,
                                           never.closureStorage.value.context) == 1)
    }
#endif

    @Test func nativeCallerReceivesOriginalTypedErrors() async throws {
        let token = ErrorLifetimeToken()
        let body = try NativeSwiftThrowingClosure<String, ManagedFailure, Bool> { (fail: Bool) throws(ManagedFailure) in
            if fail { throw ManagedFailure(token, 42) }
            return String(repeating: "callback", count: 100)
        }
        let apply = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.applyTypedThrowing(_:_:)",
            as: ((NativeSwiftThrowingClosure<String, ManagedFailure, Bool>, Bool) throws(ManagedFailure) -> String).self)
        #expect(try unsafe apply.unsafeInvoke(body, false) == String(repeating: "callback", count: 100))
        let failure = try closureFailure { try unsafe apply.unsafeInvoke(body, true) }
        failure.withUnderlyingError { #expect(($0 as? ManagedFailure)?.token === token) }
        let catchInside = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.catchTypedThrowing(_:)",
            as: ((NativeSwiftThrowingClosure<String, ManagedFailure, Bool>) -> Int64).self)
        #expect(try unsafe catchInside.unsafeInvoke(body) == 42)
    }

    @Test func untypedAndNeverClosuresUseTheirDeclaredEffects() async throws {
        let token = ErrorLifetimeToken()
        let body = try NativeSwiftThrowingClosure<String, any Error, Bool> { fail in
            if fail { throw ManagedFailure(token, 43) }
            return "success"
        }
        let apply = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.applyUntypedThrowing(_:_:)",
            as: ((NativeSwiftThrowingClosure<String, any Error, Bool>, Bool) throws -> String).self)
        #expect(try unsafe apply.unsafeInvoke(body, false) == "success")
        let failure = try closureFailure { try unsafe apply.unsafeInvoke(body, true) }
        failure.withUnderlyingError { #expect(($0 as? ManagedFailure)?.code == 43) }
        let never = try NativeSwiftThrowingClosure<Int64, Never, Int64> { $0 + 7 }
        #expect(try unsafe never.unsafeInvoke(35) == 42)
    }

    @Test func indirectResultsAndErrorsSelectIndependentOwnedValues() async throws {
        let token = ErrorLifetimeToken()
        let body = try NativeSwiftThrowingClosure<ErrorSuccessPayload, LargeFailure, ErrorLifetimeToken, Bool> {
            (token: ErrorLifetimeToken, fail: Bool) throws(LargeFailure) in
            if fail { throw LargeFailure(token) }
            return ErrorSuccessPayload(token)
        }
        let apply = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.applyLargeThrowing(_:_:_:)",
            as: ((NativeSwiftThrowingClosure<ErrorSuccessPayload, LargeFailure, ErrorLifetimeToken, Bool>,
                  ErrorLifetimeToken, Bool) throws(LargeFailure) -> ErrorSuccessPayload).self)
        let value = try unsafe apply.unsafeInvoke(body, token, false)
        #expect(value.token === token && value.d == 40)
        let failure = try closureFailure { try unsafe apply.unsafeInvoke(body, token, true) }
        failure.withUnderlyingError { #expect(($0 as? LargeFailure)?.token === token && ($0 as? LargeFailure)?.d == 4) }
        let floating = try NativeSwiftThrowingClosure<Double, FloatingFailure, Bool> { (fail: Bool) throws(FloatingFailure) in
            if fail { throw FloatingFailure(1.5) }
            return 2.5
        }
        let floatApply = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.applyFloatingThrowing(_:_:)",
            as: ((NativeSwiftThrowingClosure<Double, FloatingFailure, Bool>, Bool) throws(FloatingFailure) -> Double).self)
        #expect(try unsafe floatApply.unsafeInvoke(floating, false) == 2.5)
        let floatError = try closureFailure { try unsafe floatApply.unsafeInvoke(floating, true) }
        floatError.withUnderlyingError { #expect(($0 as? FloatingFailure)?.value == 1.5) }
    }

    @Test func returnedClosuresKeepCapturesUntilTheirFinalRelease() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeTypedThrowing(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftThrowingClosure<String, ManagedFailure, Bool>).self)
        weak var observed: ErrorLifetimeToken?
        var closure: NativeSwiftThrowingClosure<String, ManagedFailure, Bool>?
        do {
            let token = ErrorLifetimeToken()
            observed = token
            closure = try unsafe make.unsafeInvoke(token)
        }
        #expect(observed != nil)
        #expect(try unsafe closure?.unsafeInvoke(false) == String(repeating: "returned", count: 100))
        do {
            let failure = try closureFailure { try unsafe closure?.unsafeInvoke(true) }
            failure.withUnderlyingError { #expect(($0 as? ManagedFailure)?.code == 42) }
        }
        closure = nil
        #expect(observed == nil)
    }

    @Test func untypedReturnedClosuresAndFullDeclarationsPreserveEffects() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeUntypedThrowing(ManagedSwiftFixtures.ErrorLifetimeToken) -> (Swift.Bool) throws -> Swift.String",
            as: ((ErrorLifetimeToken) -> NativeSwiftThrowingClosure<String, any Error, Bool>).self)
        let token = ErrorLifetimeToken()
        let body = try unsafe make.unsafeInvoke(token)
        #expect(try unsafe body.unsafeInvoke(false) == String(repeating: "returned", count: 100))
        let error = try closureFailure { try unsafe body.unsafeInvoke(true) }
        error.withUnderlyingError { #expect(($0 as? ManagedFailure)?.token === token) }
    }

    @Test func nativeEscapingStorageOwnsTheCallbackContext() async throws {
        let retain = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.retainTypedThrowing(_:)",
            as: ((NativeSwiftThrowingClosure<String, ManagedFailure, Bool>) -> StoredThrowingClosure).self)
        weak var observed: ThrowingCapture?
        var stored: StoredThrowingClosure?
        do {
            let capture = ThrowingCapture()
            observed = capture
            let body = try NativeSwiftThrowingClosure<String, ManagedFailure, Bool> { (fail: Bool) throws(ManagedFailure) in
                if fail { throw ManagedFailure(capture.token, 42) }
                return withExtendedLifetime(capture) { "stored" }
            }
            stored = try unsafe retain.unsafeInvoke(body)
        }
        let value = try stored?.value(false)
        #expect(observed != nil && value == "stored")
        do { _ = try stored?.value(true); Issue.record("Expected original native typed error") }
        catch let error as ManagedFailure { #expect(error.code == 42) }
        stored = nil
        #expect(observed == nil)
    }

    @Test func escapedErrorsDoNotRetainUnrelatedCallbackCaptures() async throws {
        let identity = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.handoffScalarThrowing(_:)",
            as: ((NativeSwiftThrowingClosure<Int64, ScalarFailure>) -> NativeSwiftThrowingClosure<Int64, ScalarFailure>).self)
        for handoffs in [0, 1, 5] {
            weak var observed: ThrowingCapture?
            var error: NativeSwiftError?
            do {
                let capture = ThrowingCapture()
                observed = capture
                var body = try NativeSwiftThrowingClosure<Int64, ScalarFailure> { () throws(ScalarFailure) in
                    withExtendedLifetime(capture) { () }
                    throw ScalarFailure(42)
                }
                for _ in 0..<handoffs { body = try unsafe identity.unsafeInvoke(body) }
                error = try closureFailure { try unsafe body.unsafeInvoke() }
            }
            withExtendedLifetime(error) { #expect(observed == nil) }
            error?.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) }
        }
    }
}
