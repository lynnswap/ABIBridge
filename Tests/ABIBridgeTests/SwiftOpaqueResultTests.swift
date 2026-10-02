#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ManagedSwiftFixtures
import ManagedSwiftAdapters
import Testing
import Foundation

struct SwiftOpaqueResultTests {
    @Test func declaredClassConstraintsSelectDirectResultsAndRetainObjects() async throws {
        let runtime = ABIRuntime.shared
        for (name, expected) in [("makeOpaqueClassAny", 41), ("makeOpaqueClassProtocol", 42),
                                 ("makeOpaqueSuperclass", 43), ("makeOpaqueUnconstrainedClass", 44)] {
            let call = try await runtime.swiftFunction(named: "ManagedSwiftFixtures." + name + "(_:)",
                as: ((ErrorLifetimeToken) -> NativeSwiftOpaqueValue).self)
            let counts = ArgumentCounts()
            weak var observed: ErrorLifetimeToken?
            var value: NativeSwiftOpaqueValue?
            do {
                let token = ErrorLifetimeToken { counts.destroyed() }
                observed = token
                value = try unsafe call.unsafeInvoke(token)
            }
            value?.withValue { #expect(($0 as? OpaqueBase)?.number == Int64(expected)) }
            #expect(observed != nil)
            value = nil
            #expect(observed == nil && counts.destructions == 1)
        }
    }

    @Test func objcProtocolOpaqueConstraintReturnsOneObject() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueObjC(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftOpaqueValue).self)
        let result = try unsafe call.unsafeInvoke(ErrorLifetimeToken())
        result.withValue { #expect($0 is NSObject) }
    }

    @Test func directOpaqueResultsIntegrateWithErrorsAndAsyncCompletion() async throws {
        let runtime = ABIRuntime.shared
        let call = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueClassThrowing(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws(ScalarFailure) -> NativeSwiftOpaqueValue).self)
        let token = ErrorLifetimeToken()
        try unsafe call.unsafeInvoke(token, false).withValue { #expect(($0 as? any ExistentialObjectValue)?.number == 45) }
        do { _ = try unsafe call.unsafeInvoke(token, true); Issue.record("Expected direct opaque failure") }
        catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) } }
        let async = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueClassAsync(_:_:)",
            as: (@concurrent (AsyncGate, ErrorLifetimeToken) async -> NativeSwiftOpaqueValue).self)
        let gate = AsyncGate()
        let task = Task {
            let value = try unsafe await async.unsafeInvoke(gate, token)
            return value.withValue { ($0 as? any ExistentialObjectValue)?.number }
        }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await task.value == 46)
    }

    @Test func extensionMembersUseTheirMatchedOpaqueOrigin() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.OpaqueOwner")
        let owner = OpaqueOwner(ErrorLifetimeToken())
        let method = try await type.method(named: "extensionOpaque(_:)", as: ((Int64) -> NativeSwiftOpaqueValue).self)
        let getter = try await type.getter(named: "extensionSummary", as: (() -> NativeSwiftOpaqueValue).self)
        let object = try await type.method(named: "extensionClassOpaque()", as: (() -> NativeSwiftOpaqueValue).self)
        try unsafe method.unsafeInvoke(on: owner, 47).withValue { #expect(($0 as? any ExistentialValue)?.number == 47) }
        try unsafe getter.unsafeInvoke(on: owner).withValue { #expect(($0 as? any ExistentialValue)?.number == 48) }
        try unsafe object.unsafeInvoke(on: owner).withValue { #expect(($0 as? any ExistentialObjectValue)?.number == 49) }
    }

    @Test func hiddenManagedValueCanBeErasedAndOpenedWithoutItsConcreteType() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaque(_:_:)",
            as: ((ErrorLifetimeToken, Int64) -> NativeSwiftOpaqueValue).self)
        let token = ErrorLifetimeToken()
        let value = try unsafe call.unsafeInvoke(token, 42)
        let reference = eraseOpaqueReference(token, 42)
        let copies = copyOpaqueReference(token, 42)
        #expect(ObjectIdentifier(Swift.type(of: reference)) == ObjectIdentifier(value.valueType))
        #expect((copies.0 as? any ExistentialValue)?.number == 42 && (copies.1 as? any ExistentialValue)?.number == 42)
        value.withValue {
            #expect(($0 as? any ExistentialValue)?.number == 42)
            #expect(($0 as? any ExistentialLabel)?.label == String(repeating: "opaque", count: 100))
            #expect(ObjectIdentifier(Swift.type(of: $0)) == ObjectIdentifier(value.valueType))
        }
    }

    @Test func copyingTheHandleKeepsTheHiddenPayloadUntilFinalRelease() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaque(_:_:)",
            as: ((ErrorLifetimeToken, Int64) -> NativeSwiftOpaqueValue).self)
        let counts = ArgumentCounts()
        weak var observed: ErrorLifetimeToken?
        var value: NativeSwiftOpaqueValue?
        do {
            let token = ErrorLifetimeToken { counts.destroyed() }
            observed = token
            value = try unsafe call.unsafeInvoke(token, 42)
        }
        var copy = value
        value = nil
        #expect(observed != nil)
        copy?.withValue { #expect(($0 as? any ExistentialValue)?.number == 42) }
        copy = nil
        #expect(observed == nil && counts.destructions == 1)
    }

    @Test func scalarAndEmptyUnderlyingValuesStillUseOpaqueIndirectResults() async throws {
        let runtime = ABIRuntime.shared
        let integer = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
            as: ((Int64) -> NativeSwiftOpaqueValue).self)
        let empty = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueEmpty()",
            as: (() -> NativeSwiftOpaqueValue).self)
        let value = try unsafe integer.unsafeInvoke(42)
        #expect(ObjectIdentifier(value.valueType) == ObjectIdentifier(Int64.self))
        value.withValue { #expect($0 as? Int64 == 42) }
        let nothing = try unsafe empty.unsafeInvoke()
        #expect(ObjectIdentifier(nothing.valueType) == ObjectIdentifier(Void.self))
        nothing.withValue { #expect($0 is Void) }
    }

    @Test func throwingCompletionDoesNotDestroyAnUninitializedResult() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueThrowing(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws(ScalarFailure) -> NativeSwiftOpaqueValue).self)
        for fail in [false, true] {
            let counts = ArgumentCounts()
            weak var observed: ErrorLifetimeToken?
            do {
                let token = ErrorLifetimeToken { counts.destroyed() }
                observed = token
                do {
                    let value = try unsafe call.unsafeInvoke(token, fail)
                    #expect(!fail)
                    value.withValue { #expect(($0 as? any ExistentialValue)?.number == 42) }
                } catch let error as NativeSwiftError {
                    error.withUnderlyingError { #expect(fail && ($0 as? ScalarFailure)?.code == 42) }
                }
                #expect(observed === token)
            }
            #expect(observed == nil && counts.destructions == 1)
        }
    }

    @Test func asyncOpaqueValuesKeepTaskStateAndOwnedResults() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueAsync(_:_:_:)",
            as: (@concurrent (AsyncGate, ErrorLifetimeToken, Bool) async throws(ScalarFailure) -> NativeSwiftOpaqueValue).self)
        for cancel in [false, true] {
            let gate = AsyncGate()
            let counts = ArgumentCounts()
            weak var observed: ErrorLifetimeToken?
            let task: Task<Int64, any Error>
            do {
                let token = ErrorLifetimeToken { counts.destroyed() }
                observed = token
                task = Task {
                    let result = try unsafe await call.unsafeInvoke(gate, token, false)
                    return result.withValue { ($0 as? any ExistentialValue)?.number ?? -100 }
                }
            }
            await gate.waitUntilSuspended()
            #expect(observed != nil)
            if cancel { task.cancel() }
            await gate.open()
            do { #expect(try await task.value == 42 && !cancel) }
            catch let error as NativeSwiftError {
                error.withUnderlyingError { #expect(cancel && ($0 as? ScalarFailure)?.code == -1) }
            }
            #expect(observed == nil && counts.destructions == 1)
        }
    }

    @Test func methodsPropertiesAndStaticFunctionsFindTheirOpaqueDescriptors() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.OpaqueOwner")
        let token = ErrorLifetimeToken(), owner = OpaqueOwner(token)
        let method = try await type.method(named: "make(_:)", as: ((Int64) -> NativeSwiftOpaqueValue).self)
        let getter = try await type.getter(named: "summary", as: (() -> NativeSwiftOpaqueValue).self)
        let staticMethod = try await type.staticMethod(named: "makeStatic(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftOpaqueValue).self)
        try unsafe method.unsafeInvoke(on: owner, 41).withValue { #expect(($0 as? any ExistentialValue)?.number == 41) }
        try unsafe getter.unsafeInvoke(on: owner).withValue { #expect(($0 as? any ExistentialValue)?.number == 42) }
        try unsafe staticMethod.unsafeInvoke(token).withValue { #expect(($0 as? any ExistentialValue)?.number == 43) }
        let async = try await type.method(named: "makeAsync(_:)",
            as: (@concurrent (AsyncGate) async -> NativeSwiftOpaqueValue).self)
        let gate = AsyncGate()
        let task = Task {
            let result = try unsafe await async.unsafeInvoke(on: owner, gate)
            return result.withValue { ($0 as? any ExistentialValue)?.number }
        }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await task.value == 44)
    }

    @Test func noncopyableAndGenericOpaqueContractsRequireAnAdapter() async throws {
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeNestedOpaque() -> () -> some",
                as: (() -> NativeSwiftOpaqueValue).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeNoncopyableOpaque()",
                as: (() -> NativeSwiftOpaqueValue).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeGenericOpaque<A>(A) -> some",
                as: ((Int64) -> NativeSwiftOpaqueValue).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.echoAny(Any) -> Any",
                as: ((Any) -> NativeSwiftOpaqueValue).self)
        }
    }
}
