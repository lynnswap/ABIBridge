import ABIBridge
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

private final class ErrorCounter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private func invokeErrorAdapter<Value, Failure: Error, Owner: AnyObject>(
    _ name: String, owner: Owner, failing: Bool,
    result: Value.Type, failure: Failure.Type
) async throws -> Result<Value, Failure> {
    let call = try await ABIRuntime.shared.cFunction(
        named: name,
        as: ((UnsafeRawPointer, Bool, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Bool).self
    )
    let success = UnsafeMutablePointer<Value>.allocate(capacity: 1)
    let failure = UnsafeMutablePointer<Failure>.allocate(capacity: 1)
    defer { success.deallocate(); failure.deallocate() }
    return try withExtendedLifetime(owner) {
        let succeeded = try unsafe call.unsafeInvoke(Unmanaged.passUnretained(owner).toOpaque(), failing,
                                                     UnsafeMutableRawPointer(success), UnsafeMutableRawPointer(failure))
        if succeeded { return .success(success.move()) }
        return .failure(failure.move())
    }
}

struct SwiftErrorABITests {
    @Test func untypedErrorBoxOwnsItsManagedPayload() async throws {
        let destroyed = ErrorCounter()
        weak var observed: ErrorLifetimeToken?
        var result: Result<String, any Error>?
        do {
            let token = ErrorLifetimeToken { destroyed.increment() }
            observed = token
            result = try await invokeErrorAdapter("ABIUntypedErrorCall", owner: token, failing: true,
                                                  result: String.self, failure: (any Error).self)
            if case .failure(let error) = result {
                let actual = try #require(error as? ManagedFailure)
                #expect(actual.token === token && actual.code == 42)
            } else { Issue.record("Expected native failure") }
        }
        withExtendedLifetime(result) { #expect(observed != nil && destroyed.count == 0) }
        result = nil
        #expect(observed == nil && destroyed.count == 1)
    }

    @Test func cocoaErrorsKeepTheirSwiftErrorOwnership() async throws {
        let token = ErrorLifetimeToken()
        let result = try await invokeErrorAdapter("ABICocoaErrorCall", owner: token, failing: true,
                                                  result: String.self, failure: (any Error).self)
        if case .failure(let error) = result {
            let cocoa = error as NSError
            #expect(cocoa.domain == "ABIFixture" && cocoa.code == 42)
            #expect(cocoa.userInfo["token"] as? ErrorLifetimeToken === token)
        } else { Issue.record("Expected Cocoa error value") }
    }

    @Test func separateIndirectResultAndErrorBuffersSelectOneOwnedValue() async throws {
        let token = ErrorLifetimeToken()
        let success = try await invokeErrorAdapter("ABIBothIndirectErrorCall", owner: token, failing: false,
                                                   result: ErrorSuccessPayload.self, failure: LargeFailure.self)
        if case .success(let value) = success { #expect(value.token === token && value.a == 10 && value.d == 40) }
        else { Issue.record("Expected indirect success") }
        let failure = try await invokeErrorAdapter("ABIBothIndirectErrorCall", owner: token, failing: true,
                                                   result: ErrorSuccessPayload.self, failure: LargeFailure.self)
        if case .failure(let value) = failure { #expect(value.token === token && value.a == 1 && value.d == 4) }
        else { Issue.record("Expected indirect failure") }
    }

    @Test func zeroValuedTypedErrorIsStillAFailure() async throws {
        let result = try await invokeErrorAdapter("ABIScalarErrorCall", owner: ErrorLifetimeToken(), failing: true,
                                                  result: String.self, failure: ScalarFailure.self)
        if case .failure(let error) = result { #expect(error.code == 0) }
        else { Issue.record("A zero payload must not be mistaken for success") }
    }

    @Test func typedErrorsSelectStorageAndRegisterBanksIndependently() async throws {
        let token = ErrorLifetimeToken()
        let floating = try await invokeErrorAdapter("ABIFloatingErrorCall", owner: token, failing: true,
                                                     result: String.self, failure: FloatingFailure.self)
        if case .failure(let error) = floating { #expect(error.value == 1.5) }
        else { Issue.record("Expected indirect floating error") }
        for failing in [false, true] {
            let result = try await invokeErrorAdapter("ABIScalarErrorFloatingCall", owner: token, failing: failing,
                                                      result: Double.self, failure: ScalarFailure.self)
            switch result {
            case .success(let value): #expect(!failing && value == 1.5)
            case .failure(let error): #expect(failing && error.code == 42)
            }
            let empty = try await invokeErrorAdapter("ABIScalarErrorVoidCall", owner: token, failing: failing,
                                                     result: Void.self, failure: ScalarFailure.self)
            switch empty {
            case .success: #expect(!failing)
            case .failure(let error): #expect(failing && error.code == 42)
            }
        }
    }

    @Test func typedErrorRepresentationsRetainAndReleaseTheirValues() async throws {
        func check<Failure: Error>(
            _ type: Failure.Type, named name: String, inspect: (Failure, ErrorLifetimeToken) -> Bool
        ) async throws {
            let destroyed = ErrorCounter()
            weak var observed: ErrorLifetimeToken?
            var result: Result<String, Failure>?
            do {
                let token = ErrorLifetimeToken { destroyed.increment() }
                observed = token
                result = try await invokeErrorAdapter(name, owner: token, failing: true,
                                                      result: String.self, failure: type)
                if case .failure(let error) = result { #expect(inspect(error, token)) }
                else { Issue.record("Expected typed native failure") }
            }
            withExtendedLifetime(result) { #expect(observed != nil && destroyed.count == 0) }
            result = nil
            #expect(observed == nil && destroyed.count == 1)
        }
        try await check(ManagedFailure.self, named: "ABIManagedErrorCall") { $0.token === $1 && $0.code == 42 }
        try await check(LargeFailure.self, named: "ABILargeErrorCall") { $0.token === $1 && $0.a == 1 && $0.d == 4 }
        try await check(ResilientFailure.self, named: "ABIResilientErrorCall") { $0.token === $1 && $0.code == 42 }
        try await check(ReferenceFailure.self, named: "ABIReferenceErrorCall") { $0.token === $1 && $0.code == 42 }
    }

    @Test func successInitializesOnlyTheOrdinaryResult() async throws {
        func check<Failure: Error>(_ type: Failure.Type, named name: String) async throws {
            let result = try await invokeErrorAdapter(name, owner: ErrorLifetimeToken(), failing: false,
                                                      result: String.self, failure: type)
            if case .success(let value) = result { #expect(value == String(repeating: "success", count: 100)) }
            else { Issue.record("Expected native success") }
        }
        try await check((any Error).self, named: "ABIUntypedErrorCall")
        try await check(ScalarFailure.self, named: "ABIScalarErrorCall")
        try await check(ManagedFailure.self, named: "ABIManagedErrorCall")
        try await check(LargeFailure.self, named: "ABILargeErrorCall")
        try await check(ResilientFailure.self, named: "ABIResilientErrorCall")
        try await check(ReferenceFailure.self, named: "ABIReferenceErrorCall")
    }

    @Test func throwingInitializerAndMemberPreserveOwnedErrors() async throws {
        let token = ErrorLifetimeToken()
        let rejected = try await invokeErrorAdapter("ABIThrowingInitializer", owner: token, failing: true,
                                                    result: ThrowingOwner.self, failure: ManagedFailure.self)
        if case .failure(let error) = rejected { #expect(error.code == 43 && error.token === token) }
        else { Issue.record("Expected initializer failure") }
        let created = try await invokeErrorAdapter("ABIThrowingInitializer", owner: token, failing: false,
                                                   result: ThrowingOwner.self, failure: ManagedFailure.self)
        let owner = try created.get()
        #expect(owner.token === token)
        let failed = try await invokeErrorAdapter("ABIThrowingMember", owner: owner, failing: true,
                                                  result: String.self, failure: ManagedFailure.self)
        if case .failure(let error) = failed { #expect(error.code == 44 && error.token === token) }
        else { Issue.record("Expected member failure") }
        let succeeded = try await invokeErrorAdapter("ABIThrowingMember", owner: owner, failing: false,
                                                     result: String.self, failure: ManagedFailure.self)
        #expect(try succeeded.get() == String(repeating: "member", count: 100))
    }

    @Test func errorDoesNotInitializeTheNormalResultBuffer() async throws {
        let call = try await ABIRuntime.shared.cFunction(
            named: "ABIManagedErrorCall",
            as: ((UnsafeRawPointer, Bool, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Bool).self
        )
        let output = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<String>.stride,
                                                      alignment: MemoryLayout<String>.alignment)
        output.initializeMemory(as: UInt8.self, repeating: 0xA5, count: MemoryLayout<String>.stride)
        let error = UnsafeMutablePointer<ManagedFailure>.allocate(capacity: 1)
        defer { output.deallocate(); error.deallocate() }
        let token = ErrorLifetimeToken()
        let succeeded = try withExtendedLifetime(token) {
            try unsafe call.unsafeInvoke(Unmanaged.passUnretained(token).toOpaque(), true, output,
                                          UnsafeMutableRawPointer(error))
        }
        #expect(!succeeded)
        if !succeeded {
            let failure = error.move()
            #expect(failure.token === token && failure.code == 42)
            #expect(UnsafeRawBufferPointer(start: output, count: MemoryLayout<String>.stride).allSatisfy { $0 == 0xA5 })
        } else {
            // A regressed adapter could still have initialized a String.
            output.assumingMemoryBound(to: String.self).deinitialize(count: 1)
        }
    }
}
