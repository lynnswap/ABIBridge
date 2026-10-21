import ABIBridge
import ManagedSwiftFixtures
import Testing

/// Requests whose class types differ from the native declaration's.
struct SwiftSignatureCompatibilityTests {
    private let runtime = ABIRuntime.shared

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

    @Test func hooksRequireTheNativeTypes() async throws {
        let type = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.CompatibilityBase")
        let make = try await type.resolveMethod(
            named: "makeDerived()",
            as: (() -> CompatibilityBase).self,
            declaredAs: "() -> ManagedSwiftFixtures.CompatibilityDerived"
        )
        #expect(try unsafe make.unsafeInvoke(on: CompatibilityBase()).name() == "derived")
        // A hook would have to return a superclass instance as the subclass.
        await #expect(throws: ABIResolutionError.self) {
            _ = try await unsafe make.hookVirtualCalls(onFailure: { _ in }) { call in
                try call.proceed()
            }
        }
    }
}
