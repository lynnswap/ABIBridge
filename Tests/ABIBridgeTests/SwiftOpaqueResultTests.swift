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
    @Test func genericOpaqueResultsBindCapturedTypesAndConformances() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeGenericOpaque<A>(A) -> some",
            as: ((String) -> NativeSwiftValue).self, genericArguments: [.type(String.self)])
        let value = try unsafe make.unsafeInvoke("captured")
        let reference = makeGenericOpaque("reference")
        try value.withCopy { #expect(ObjectIdentifier(Swift.type(of: $0)) == ObjectIdentifier(Swift.type(of: reference))) }
        let constrained = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeConstrainedOpaque<A where A: ManagedSwiftFixtures.ExistentialValue>(A) -> some",
            as: ((InlineExistentialValue) -> NativeSwiftValue).self,
            genericArguments: [.type(InlineExistentialValue.self)])
        let constrainedValue = try unsafe constrained.unsafeInvoke(InlineExistentialValue(43))
        try constrainedValue.withCopy { #expect(($0 as? any ExistentialValue)?.number == 43) }
        let object = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeGenericOpaqueObject<A where A: ManagedSwiftFixtures.ExistentialObjectValue>(A) -> some",
            as: ((ExistentialObject) -> NativeSwiftValue).self,
            genericArguments: [.type(ExistentialObject.self)])
        let original = ExistentialObject(ErrorLifetimeToken(), 44)
        let objectValue = try unsafe object.unsafeInvoke(original)
        try objectValue.withCopy { #expect(($0 as? ExistentialObject) === original) }
    }

    @Test func genericOpaqueMembersCombineEnclosingAndMethodBindings() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericOpaqueOwner",
            genericArguments: [.type(String.self)])
        let initialize = try await type.initializer(named: "init(_:)", as: ((String) -> AnyObject).self)
        let owner = try unsafe initialize.unsafeInvoke("outer")
        let getter = try await runtime.object(owner).getter(named: "opaque", as: (() -> NativeSwiftValue).self)
        let method = try await runtime.object(owner).method(named: "make(_:)",
            as: ((Int64) -> NativeSwiftValue).self, genericArguments: [.type(Int64.self)])
        let first = try unsafe getter.unsafeInvoke()
        let second = try unsafe method.unsafeInvoke(42)
        let reference = GenericOpaqueOwner("outer")
        try first.withCopy { #expect(ObjectIdentifier(Swift.type(of: $0)) == ObjectIdentifier(Swift.type(of: reference.opaque))) }
        try second.withCopy { #expect(ObjectIdentifier(Swift.type(of: $0)) == ObjectIdentifier(Swift.type(of: reference.make(Int64(42))))) }
    }

    @Test func returnedClosuresResolveNestedOpaqueMetadata() async throws {
        let factory = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeNestedOpaque()",
            as: (() -> NativeSwiftClosure<() -> NativeSwiftValue>).self)
        let closure = try unsafe factory.unsafeInvoke()
        let result = try unsafe closure.unsafeInvoke()
        #expect(try result.take(as: Int64.self) == 42)
    }

    @Test func opaqueResultsSharePreparationWithClosureArguments() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueUsingCallback(_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>) -> NativeSwiftValue).self)
        let value = try unsafe call.unsafeInvoke(NativeSwiftClosure { $0 + 1 })
        #expect(try value.take(as: Int64.self) == 42)
        let typed = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeOpaqueUsingCallback((Swift.Int64) -> Swift.Int64) -> some",
            as: ((NativeSwiftClosure<(Int64) -> Int64>) -> Int64).self)
        #expect(try unsafe typed.unsafeInvoke(NativeSwiftClosure { $0 + 1 }) == 42)
    }

    @Test func declaredClassConstraintsSelectDirectResultsAndRetainObjects() async throws {
        let runtime = ABIRuntime.shared
        for (name, expected) in [("makeOpaqueClassAny", 41), ("makeOpaqueClassProtocol", 42),
                                 ("makeOpaqueSuperclass", 43), ("makeOpaqueUnconstrainedClass", 44)] {
            let call = try await runtime.swiftFunction(named: "ManagedSwiftFixtures." + name + "(_:)",
                as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
            let counts = ArgumentCounts()
            weak var observed: ErrorLifetimeToken?
            var value: NativeSwiftValue?
            do {
                let token = ErrorLifetimeToken { counts.destroyed() }
                observed = token
                value = try unsafe call.unsafeInvoke(token)
            }
            try value?.withCopy { #expect(($0 as? OpaqueBase)?.number == Int64(expected)) }
            #expect(observed != nil)
            value = nil
            #expect(observed == nil && counts.destructions == 1)
        }
    }

    @Test func objcProtocolOpaqueConstraintReturnsOneObject() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueObjC(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let result = try unsafe call.unsafeInvoke(ErrorLifetimeToken())
        try result.withCopy { #expect($0 is NSObject) }
    }

    @Test func directOpaqueResultsIntegrateWithErrorsAndAsyncCompletion() async throws {
        let runtime = ABIRuntime.shared
        let call = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueClassThrowing(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws(ScalarFailure) -> NativeSwiftValue).self)
        let token = ErrorLifetimeToken()
        try unsafe call.unsafeInvoke(token, false).withCopy { #expect(($0 as? any ExistentialObjectValue)?.number == 45) }
        do { _ = try unsafe call.unsafeInvoke(token, true); Issue.record("Expected direct opaque failure") }
        catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) } }
        let async = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueClassAsync(_:_:)",
            as: (@concurrent (AsyncGate, ErrorLifetimeToken) async -> NativeSwiftValue).self)
        let gate = AsyncGate()
        let task = Task {
            let value = try unsafe await async.unsafeInvoke(gate, token)
            return try value.withCopy { ($0 as? any ExistentialObjectValue)?.number }
        }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await task.value == 46)
    }

    @Test func extensionMembersUseTheirMatchedOpaqueOrigin() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.OpaqueOwner")
        let owner = OpaqueOwner(ErrorLifetimeToken())
        let method = try await type.method(named: "extensionOpaque(_:)", as: ((Int64) -> NativeSwiftValue).self)
        let getter = try await type.getter(named: "extensionSummary", as: (() -> NativeSwiftValue).self)
        let object = try await type.method(named: "extensionClassOpaque()", as: (() -> NativeSwiftValue).self)
        try unsafe method.unsafeInvoke(on: owner, 47).withCopy { #expect(($0 as? any ExistentialValue)?.number == 47) }
        try unsafe getter.unsafeInvoke(on: owner).withCopy { #expect(($0 as? any ExistentialValue)?.number == 48) }
        try unsafe object.unsafeInvoke(on: owner).withCopy { #expect(($0 as? any ExistentialObjectValue)?.number == 49) }
    }

    @Test func hiddenManagedValueCanBeErasedAndOpenedWithoutItsConcreteType() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaque(_:_:)",
            as: ((ErrorLifetimeToken, Int64) -> NativeSwiftValue).self)
        let token = ErrorLifetimeToken()
        let value = try unsafe call.unsafeInvoke(token, 42)
        let reference = eraseOpaqueReference(token, 42)
        let copies = copyOpaqueReference(token, 42)
        #expect((copies.0 as? any ExistentialValue)?.number == 42 && (copies.1 as? any ExistentialValue)?.number == 42)
        try value.withCopy {
            #expect(($0 as? any ExistentialValue)?.number == 42)
            #expect(($0 as? any ExistentialLabel)?.label == String(repeating: "opaque", count: 100))
            #expect(ObjectIdentifier(Swift.type(of: $0)) == ObjectIdentifier(Swift.type(of: reference)))
        }
    }

    @Test func copyingTheHandleKeepsTheHiddenPayloadUntilFinalRelease() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaque(_:_:)",
            as: ((ErrorLifetimeToken, Int64) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        weak var observed: ErrorLifetimeToken?
        var value: NativeSwiftValue?
        do {
            let token = ErrorLifetimeToken { counts.destroyed() }
            observed = token
            value = try unsafe call.unsafeInvoke(token, 42)
        }
        var copy = value
        value = nil
        #expect(observed != nil)
        try copy?.withCopy { #expect(($0 as? any ExistentialValue)?.number == 42) }
        copy = nil
        #expect(observed == nil && counts.destructions == 1)
    }

    @Test func scalarAndEmptyUnderlyingValuesStillUseOpaqueIndirectResults() async throws {
        let runtime = ABIRuntime.shared
        let integer = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
            as: ((Int64) -> NativeSwiftValue).self)
        let empty = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueEmpty()",
            as: (() -> NativeSwiftValue).self)
        let value = try unsafe integer.unsafeInvoke(42)
        #expect(value.type.name == "Swift.Int64")
        try value.withCopy { #expect($0 as? Int64 == 42) }
        let nothing = try unsafe empty.unsafeInvoke()
        #expect(nothing.type.name == "()")
        try nothing.withCopy { #expect($0 is Void) }
    }

    @Test func throwingCompletionDoesNotDestroyAnUninitializedResult() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueThrowing(_:_:)",
            as: ((ErrorLifetimeToken, Bool) throws(ScalarFailure) -> NativeSwiftValue).self)
        for fail in [false, true] {
            let counts = ArgumentCounts()
            weak var observed: ErrorLifetimeToken?
            do {
                let token = ErrorLifetimeToken { counts.destroyed() }
                observed = token
                do {
                    let value = try unsafe call.unsafeInvoke(token, fail)
                    #expect(!fail)
                    try value.withCopy { #expect(($0 as? any ExistentialValue)?.number == 42) }
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
            as: (@concurrent (AsyncGate, ErrorLifetimeToken, Bool) async throws(ScalarFailure) -> NativeSwiftValue).self)
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
                    return try result.withCopy { ($0 as? any ExistentialValue)?.number ?? -100 }
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
        let method = try await type.method(named: "make(_:)", as: ((Int64) -> NativeSwiftValue).self)
        let getter = try await type.getter(named: "summary", as: (() -> NativeSwiftValue).self)
        let staticMethod = try await type.staticMethod(named: "makeStatic(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        try unsafe method.unsafeInvoke(on: owner, 41).withCopy { #expect(($0 as? any ExistentialValue)?.number == 41) }
        try unsafe getter.unsafeInvoke(on: owner).withCopy { #expect(($0 as? any ExistentialValue)?.number == 42) }
        try unsafe staticMethod.unsafeInvoke(token).withCopy { #expect(($0 as? any ExistentialValue)?.number == 43) }
        let async = try await type.method(named: "makeAsync(_:)",
            as: (@concurrent (AsyncGate) async -> NativeSwiftValue).self)
        let gate = AsyncGate()
        let task = Task {
            let result = try unsafe await async.unsafeInvoke(on: owner, gate)
            return try result.withCopy { ($0 as? any ExistentialValue)?.number }
        }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await task.value == 44)
    }

    @Test func nestedAndGenericOpaqueContractsRequireDeclarationPlanning() async throws {
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeNestedOpaque() -> () -> some",
                as: (() -> NativeSwiftValue).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeGenericOpaque<A>(A) -> some",
                as: ((Int64) -> NativeSwiftValue).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.echoAny(Any) -> Any",
                as: ((Any) -> NativeSwiftValue).self)
        }
    }
}
