#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

extension ScalarFailure: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .int64 }
}
extension FloatingFailure: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .double }
}
extension ManagedFailure: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "ManagedFailure", fields: [.pointer, .int64])
    }
}
extension LargeFailure: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "LargeFailure", fields: [.pointer, .int64, .int64, .int64, .int64])
    }
}
extension ResilientFailure: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { try! .opaque(named: "ResilientFailure") }
}
extension ErrorSuccessPayload: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { LargeFailure.swiftABIType }
}

private final class NativeErrorCounter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private func nativeFailure<Value>(_ body: () throws -> Value) throws -> NativeSwiftError {
    do {
        _ = try body()
        throw ABIResolutionError.unsupportedDeclaration("Expected the native implementation to throw")
    } catch let error as NativeSwiftError {
        return error
    }
}

extension ThrowingCounter: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .int64 }
}

struct SwiftThrowingInvocationTests {
    @Test func mutationWritesBackEvenWhenNativeCodeThrows() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.ThrowingCounter",
                                                         as: ThrowingCounter.self)
        let advance = try await type.method(named: "advance(_:)",
            as: ((Bool) throws(ScalarFailure) -> Int64).self, mutating: true)
        var value = ThrowingCounter(40)
        #expect(try unsafe advance.unsafeInvoke(on: &value, false) == 41)
        let error = try nativeFailure { try unsafe advance.unsafeInvoke(on: &value, true) }
        #expect(value.count == 42)
        error.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) }
        let getter = try await type.getter(named: "rejected", as: (() throws(ScalarFailure) -> Int64).self)
        let getterError = try nativeFailure { try unsafe getter.unsafeInvoke(on: value) }
        getterError.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) }
        let staticGetter = try await type.staticGetter(named: "rejected", as: (() throws(ScalarFailure) -> Int64).self)
        let staticError = try nativeFailure { try unsafe staticGetter.unsafeInvoke() }
        staticError.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 99) }
        let staticMethod = try await type.staticMethod(named: "result(_:)",
            as: ((Bool) throws(ScalarFailure) -> Int8).self)
        #expect(try unsafe staticMethod.unsafeInvoke(false) == 7)
        let methodError = try nativeFailure { try unsafe staticMethod.unsafeInvoke(true) }
        methodError.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) }
    }

    @Test func hiddenErrorOutputSpillsAfterOrdinaryStackArguments() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.stackedErrorResult(_:_:_:_:_:_:_:_:_:_:)",
            as: ((Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, ErrorLifetimeToken, Bool)
                throws(LargeFailure) -> Int64).self
        )
        let token = ErrorLifetimeToken()
        #expect(try unsafe call.unsafeInvoke(1, 2, 3, 4, 5, 6, 7, 8, token, false) == 36)
        let error = try nativeFailure { try unsafe call.unsafeInvoke(1, 2, 3, 4, 5, 6, 7, 8, token, true) }
        error.withUnderlyingError { #expect(($0 as? LargeFailure)?.token === token) }
    }

    @Test func boundMembersUseTheSameThrowingContract() async throws {
        let owner = try ThrowingOwner(ErrorLifetimeToken(), false)
        let call = try await ABIRuntime.shared.object(owner).method(
            named: "value(_:)", as: ((Bool) throws(ManagedFailure) -> String).self)
        #expect(try unsafe call.unsafeInvoke(false) == String(repeating: "member", count: 100))
        let error = try nativeFailure { try unsafe call.unsafeInvoke(true) }
        error.withUnderlyingError { #expect(($0 as? ManagedFailure)?.token === owner.token) }
    }

    @Test func effectMismatchIsRejectedBeforeReplacementPreparation() async throws {
        let runtime = ABIRuntime.shared
        let untyped = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.untypedResult(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws -> String).self)
        let typed = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.managedErrorResult(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws(ManagedFailure) -> String).self)
        do {
            _ = try unsafe await untyped.prepareImportedReplacement(with: typed, in: .automatic)
            Issue.record("An incompatible typed error must not replace an untyped error")
        } catch ABIResolutionError.signatureMismatch {}
    }

    @Test func untypedErrorsPreserveValuesAndOwnership() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.untypedResult(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws -> String).self
        )
        let destroyed = NativeErrorCounter()
        weak var observed: ErrorLifetimeToken?
        var saved: NativeSwiftError?
        do {
            let token = ErrorLifetimeToken { destroyed.increment() }
            observed = token
            #expect(try unsafe call.unsafeInvoke(token, false) == String(repeating: "success", count: 100))
            saved = try nativeFailure { try unsafe call.unsafeInvoke(token, true) }
            try saved?.withUnderlyingError {
                let actual = try #require($0 as? ManagedFailure)
                #expect(actual.token === token && actual.code == 42)
            }
        }
        withExtendedLifetime(saved) { #expect(observed != nil && destroyed.count == 0) }
        saved = nil
        #expect(observed == nil && destroyed.count == 1)
    }

    @Test func cocoaErrorRetainsItsUserInfo() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.cocoaErrorResult(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws -> String).self
        )
        let token = ErrorLifetimeToken()
        let error = try nativeFailure { try unsafe call.unsafeInvoke(token, true) }
        error.withUnderlyingError {
            let actual = $0 as NSError
            #expect(actual.domain == "ABIFixture" && actual.code == 42)
            #expect(actual.userInfo["token"] as? ErrorLifetimeToken === token)
        }
        #expect(error.errorDescription != nil)
    }

    @Test func typedErrorsUseDirectIndirectAndReferenceOwnership() async throws {
        func check<Failure: Error>(
            _ failure: Failure.Type, name: String, inspect: (Failure, ErrorLifetimeToken) -> Bool
        ) async throws {
            let call = try await ABIRuntime.shared.swiftFunction(
                named: "ManagedSwiftFixtures." + name + "(_:_:)",
                as: ((ErrorLifetimeToken, Bool) throws(Failure) -> String).self
            )
            let destroyed = NativeErrorCounter()
            weak var observed: ErrorLifetimeToken?
            var saved: NativeSwiftError?
            do {
                let token = ErrorLifetimeToken { destroyed.increment() }
                observed = token
                #expect(try unsafe call.unsafeInvoke(token, false) == String(repeating: "success", count: 100))
                saved = try nativeFailure { try unsafe call.unsafeInvoke(token, true) }
                try saved?.withUnderlyingError {
                    let actual = try #require($0 as? Failure)
                    #expect(inspect(actual, token))
                }
            }
            withExtendedLifetime(saved) { #expect(observed != nil && destroyed.count == 0) }
            saved = nil
            #expect(observed == nil && destroyed.count == 1)
        }
        try await check(ManagedFailure.self, name: "managedErrorResult") { $0.token === $1 && $0.code == 42 }
        try await check(LargeFailure.self, name: "largeErrorResult") { $0.token === $1 && $0.a == 1 && $0.d == 4 }
        try await check(ResilientFailure.self, name: "resilientErrorResult") { $0.token === $1 && $0.code == 42 }
        try await check(ReferenceFailure.self, name: "referenceErrorResult") { $0.token === $1 && $0.code == 42 }
    }

    @Test func zeroPayloadAndMixedResultBanksDoNotHideFailure() async throws {
        let runtime = ABIRuntime.shared
        let zero = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.scalarErrorResult(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws(ScalarFailure) -> String).self
        )
        let floating = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.scalarErrorFloatingResult(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws(ScalarFailure) -> Double).self
        )
        let empty = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.scalarErrorVoidResult(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws(ScalarFailure) -> Void).self
        )
        let floatingError = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.floatingErrorResult(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws(FloatingFailure) -> String).self
        )
        let token = ErrorLifetimeToken()
        #expect(try unsafe zero.unsafeInvoke(token, false) == String(repeating: "success", count: 100))
        #expect(try unsafe floating.unsafeInvoke(token, false) == 1.5)
        try unsafe empty.unsafeInvoke(token, false)
        let zeroError = try nativeFailure { try unsafe zero.unsafeInvoke(token, true) }
        zeroError.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 0) }
        let floatingResultError = try nativeFailure { try unsafe floating.unsafeInvoke(token, true) }
        floatingResultError.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) }
        let voidError = try nativeFailure { try unsafe empty.unsafeInvoke(token, true) }
        voidError.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) }
        let indirect = try nativeFailure { try unsafe floatingError.unsafeInvoke(token, true) }
        indirect.withUnderlyingError { #expect(($0 as? FloatingFailure)?.value == 1.5) }
    }

    @Test func indirectResultAndErrorInitializeOnlyTheirSelectedStorage() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.bothIndirectResult(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws(LargeFailure) -> ErrorSuccessPayload).self
        )
        let token = ErrorLifetimeToken()
        let result = try unsafe call.unsafeInvoke(token, false)
        #expect(result.token === token && result.a == 10 && result.d == 40)
        let error = try nativeFailure { try unsafe call.unsafeInvoke(token, true) }
        try error.withUnderlyingError {
            let actual = try #require($0 as? LargeFailure)
            #expect(actual.token === token && actual.a == 1 && actual.d == 4)
        }
    }

    @Test func throwingInitializerAndMemberPreserveErrorAndArgumentOwnership() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.ThrowingOwner")
        let initialize = try await type.initializer(
            named: "init(_:_:)", as: ((ErrorLifetimeToken, Bool) throws(ManagedFailure) -> ThrowingOwner).self
        )
        let value = try await type.method(named: "value(_:)", as: ((Bool) throws(ManagedFailure) -> String).self)
        let destroyed = NativeErrorCounter()
        weak var observed: ErrorLifetimeToken?
        var saved: NativeSwiftError?
        do {
            let token = ErrorLifetimeToken { destroyed.increment() }
            observed = token
            let error = try nativeFailure { try unsafe initialize.unsafeInvoke(token, true) }
            error.withUnderlyingError { #expect(($0 as? ManagedFailure)?.code == 43) }
            let owner = try unsafe initialize.unsafeInvoke(token, false)
            #expect(owner.token === token)
            #expect(try unsafe value.unsafeInvoke(on: owner, false) == String(repeating: "member", count: 100))
            saved = try nativeFailure { try unsafe value.unsafeInvoke(on: owner, true) }
            saved?.withUnderlyingError { #expect(($0 as? ManagedFailure)?.code == 44) }
        }
        withExtendedLifetime(saved) { #expect(observed != nil && destroyed.count == 0) }
        saved = nil
        #expect(observed == nil && destroyed.count == 1)
    }
}
