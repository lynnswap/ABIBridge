import ABIBridge
import ManagedSwiftFixtures
import Testing

/// Requests whose class types differ from the native declaration's.
struct SwiftSignatureCompatibilityTests {
    private let runtime = ABIRuntime.shared

    private func expectNativeTypesRequired(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("A hook accepted converted types")
        } catch ABIResolutionError.unsupportedDeclaration(let reason) {
            #expect(reason.contains("native parameter and result types"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func resultsConvertToRequestedSuperclassesAndOptional() async throws {
        let base = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityMakeDerived()",
            as: (() -> CompatibilityBase).self,
            declaredAs: "() -> ManagedSwiftFixtures.CompatibilityDerived"
        )
        #expect(try unsafe base.unsafeInvoke().name() == "derived")
        let optional = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityMakeDerived()",
            as: (() -> CompatibilityBase?).self,
            declaredAs: "() -> ManagedSwiftFixtures.CompatibilityDerived"
        )
        #expect(try unsafe optional.unsafeInvoke()?.name() == "derived")
    }

    @Test func argumentsAcceptSubclassesAndOptionalWrapping() async throws {
        let name = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityName(_:)",
            as: ((CompatibilityDerived) -> String).self,
            declaredAs: "(ManagedSwiftFixtures.CompatibilityBase) -> Swift.String"
        )
        #expect(try unsafe name.unsafeInvoke(CompatibilityDerived()) == "derived")
        let optional = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityOptionalName(_:)",
            as: ((CompatibilityDerived) -> String).self,
            declaredAs: "(ManagedSwiftFixtures.CompatibilityBase?) -> Swift.String"
        )
        #expect(try unsafe optional.unsafeInvoke(CompatibilityDerived()) == "derived")
    }

    @Test func incompatibleRequestsReportTheDeclarationAndPosition() async throws {
        // A superclass instance cannot be passed where the native parameter
        // requires its subclass.
        do {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.compatibilityDerivedName(_:)",
                as: ((CompatibilityBase) -> String).self,
                declaredAs: "(ManagedSwiftFixtures.CompatibilityDerived) -> Swift.String"
            )
            Issue.record("A superclass argument was accepted")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.position == .argument(0))
            #expect(mismatch.declaration?.name.contains("compatibilityDerivedName") == true)
        }
        // A native Optional result cannot be requested as nonoptional.
        do {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.compatibilityMakeOptional(_:)",
                as: ((Bool) -> CompatibilityBase).self,
                declaredAs: "(Swift.Bool) -> ManagedSwiftFixtures.CompatibilityDerived?"
            )
            Issue.record("A nonoptional result was accepted for an Optional native result")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.position == .result)
        }
    }

    @Test func valuesThatCanFlowBackStayExact() async throws {
        // The callee can store a superclass instance through inout.
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.compatibilityReplace(_:)",
                as: ((NativeSwiftInout<CompatibilityDerived>) -> Void).self,
                declaredAs: "(inout ManagedSwiftFixtures.CompatibilityBase) -> ()"
            )
        }
        // A tuple field is a result, which cannot narrow to a subclass.
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.compatibilityPair()",
                as: (() -> (CompatibilityDerived, Int64)).self,
                declaredAs: "() -> (ManagedSwiftFixtures.CompatibilityBase, Swift.Int64)"
            )
        }
        // A callback receives native arguments and returns a native result.
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.compatibilityApply(_:)",
                as: ((NativeSwiftClosure<(CompatibilityDerived) -> CompatibilityBase>) -> String).self,
                declaredAs:
                    "((ManagedSwiftFixtures.CompatibilityBase) -> ManagedSwiftFixtures.CompatibilityDerived) -> Swift.String"
            )
        }
        // An adapter subclass is not passed as an object reference.
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.compatibilityName(_:)",
                as: ((IntegerAdaptedSubclass) -> String).self,
                declaredAs: "(ManagedSwiftFixtures.CompatibilityBase) -> Swift.String"
            )
        }
        // Convention wrappers keep the native type, so hooks cannot see a
        // superclass instance as the subclass.
        let type = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.CompatibilityBase")
        await #expect(throws: ABIResolutionError.self) {
            _ = try await type.resolveMethod(
                named: "describe(_:)",
                as: ((NativeSwiftBorrowing<CompatibilityDerived>) -> String).self,
                declaredAs: "(ManagedSwiftFixtures.CompatibilityBase) -> Swift.String"
            )
        }
        let describe = try await type.resolveMethod(
            named: "describe(_:)",
            as: ((CompatibilityDerived) -> String).self,
            declaredAs: "(ManagedSwiftFixtures.CompatibilityBase) -> Swift.String"
        )
        #expect(
            try unsafe describe.unsafeInvoke(on: CompatibilityBase(), CompatibilityDerived()) == "derived"
        )
        await expectNativeTypesRequired {
            _ = try await unsafe describe.hookVirtualCalls(onFailure: { _ in }) { call, value in
                try call.proceed(value)
            }
        }
    }

    @Test func labelOnlyNamesSelectCompatibleFunctions() async throws {
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityMakeDerived()",
            as: (() -> CompatibilityBase).self
        )
        #expect(try unsafe make.unsafeInvoke().name() == "derived")
        // An imported hook would return a superclass instance as the subclass.
        await expectNativeTypesRequired {
            _ = try await unsafe make.hookImportedCalls(in: .automatic, onFailure: { _ in }) { call in
                try call.proceed()
            }
        }
    }

    @Test func hooksRequireTheNativeTypes() async throws {
        let type = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.CompatibilityBase")
        let make = try await type.resolveMethod(
            named: "makeDerived()",
            as: (() -> CompatibilityBase).self,
            declaredAs: "() -> ManagedSwiftFixtures.CompatibilityDerived"
        )
        #expect(try unsafe make.unsafeInvoke(on: CompatibilityBase()).name() == "derived")
        // A hook would have to return a superclass instance as the subclass.
        await expectNativeTypesRequired {
            _ = try await unsafe make.hookVirtualCalls(onFailure: { _ in }) { call in
                try call.proceed()
            }
        }
    }
}

/// A subclass of the native parameter type that marshals as an integer.
private final class IntegerAdaptedSubclass: CompatibilityBase, ABIBridgeValue, @unchecked Sendable {
    static var abiType: NativeType { .int64 }
    override init() { super.init() }
    init(nativeValue: NativeValue) throws { super.init() }
    static func nativeValue(from value: IntegerAdaptedSubclass) throws -> NativeValue {
        try NativeValue(copying: Int64(42), as: .int64)
    }
}
