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
        // An erased result is a conversion too: a hook could return any object.
        let erased = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityMakeDerived()",
            as: (() -> AnyObject).self
        )
        #expect((try unsafe erased.unsafeInvoke() as? CompatibilityDerived)?.name() == "derived")
        await expectNativeTypesRequired {
            _ = try await unsafe erased.hookImportedCalls(in: .automatic, onFailure: { _ in }) { call in
                try call.proceed()
            }
        }
    }

    @Test func labelOnlyMembersSelectCompatibleDeclarations() async throws {
        let type = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.CompatibilityBase")
        // Both properties are declared with the subclass type, in the class
        // and in an extension from another module.
        for name in ["derived", "extensionDerived"] {
            let getter = try await type.resolveGetter(named: name, as: (() -> CompatibilityBase).self)
            #expect(try unsafe getter.unsafeInvoke(on: CompatibilityBase()).name() == "derived")
        }
        let derived = try await type.resolveGetter(named: "derived", as: (() -> CompatibilityBase).self)
        await expectNativeTypesRequired {
            _ = try await unsafe derived.hookVirtualCalls(onFailure: { _ in }) { call in
                try call.proceed()
            }
        }
        // A complete declaration need not name the extension's module.
        let name = try await type.resolveMethod(
            named: "extensionAsyncName() async -> Swift.String",
            as: (@concurrent () async -> String).self
        )
        #expect(try unsafe await name.unsafeInvoke(on: CompatibilityBase()) == "async")
        // Label-only protocol members: a requirement, and an extension member
        // named without its module.
        let label = try await type.resolveMethod(
            named: "ManagedSwiftFixtures.CompatibilityNamed.compatibilityLabel()",
            as: (() -> String).self
        )
        #expect(try unsafe label.unsafeInvoke(on: CompatibilityBase()) == "base")
        let greeting = try await type.resolveMethod(
            named: "ManagedSwiftFixtures.CompatibilityNamed.compatibilityGreeting()",
            as: (() -> String).self
        )
        #expect(try unsafe greeting.unsafeInvoke(on: CompatibilityBase()) == "hello base")
    }

    @Test func protocolRequirementsPrecedeTheirDefaultImplementations() async throws {
        let type = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.CompatibilityTagged")
        let set = try await type.resolveSetter(
            named: "ManagedSwiftFixtures.CompatibilityLabeled.compatibilityTag",
            as: String.self
        )
        let tagged = CompatibilityTagged()
        try unsafe set.unsafeInvoke(on: tagged, "renamed")
        #expect(tagged.compatibilityTag == "renamed")
    }

    @Test func labelOnlyMembersAcceptTheOwnersRepresentation() async throws {
        let type = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.CompatibilityCount",
            as: HostCount.self
        )
        let make = try await type.resolveInitializer(named: "init(_:)", as: ((Int64) -> HostCount).self)
        let count = try unsafe make.unsafeInvoke(21)
        #expect(count.value == 21)
        let doubled = try await type.resolveGetter(named: "doubled", as: (() -> HostCount).self)
        #expect(try unsafe doubled.unsafeInvoke(on: count).value == 42)
    }

    @Test func completeDeclarationsKeepHostRepresentationsInTuples() async throws {
        let count = "ManagedSwiftFixtures.CompatibilityCount"
        let pair = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityCountPair((\(count), Swift.Int64)) -> (\(count), Swift.Int64)",
            as: (((HostStoredCount, Int64)) -> (HostStoredCount, Int64)).self
        )
        let result = try unsafe pair.unsafeInvoke((HostStoredCount(value: 40), 2))
        #expect(result.0.value == 42 && result.1 == 2)
    }

    @Test func valueABIsLowerClosedValuesOfHostTypes() async throws {
        let count = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.CompatibilityCount")
        let valueABIs = [count: try NativeType.structure(named: "CompatibilityCount", fields: [.int64])]
        let doubled = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityCountDoubled(_:)",
            as: ((CompatibilityCount) -> CompatibilityCount).self,
            valueABIs: valueABIs
        )
        #expect(try unsafe doubled.unsafeInvoke(CompatibilityCount(21)).value == 42)
        let pair = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityCountPair(_:)",
            as: (((CompatibilityCount, Int64)) -> (CompatibilityCount, Int64)).self,
            valueABIs: valueABIs
        )
        let result = try unsafe pair.unsafeInvoke((CompatibilityCount(40), 2))
        #expect(result.0.value == 42 && result.1 == 2)
    }

    @Test func valueABIsKeepOtherHostRepresentations() async throws {
        let count = "ManagedSwiftFixtures.CompatibilityCount"
        let int64 = try await runtime.resolveSwiftType(named: "Swift.Int64")
        let pair = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityCountPair((\(count), Swift.Int64)) -> (\(count), Swift.Int64)",
            as: (((HostStoredCount, Int64)) -> (HostStoredCount, Int64)).self,
            valueABIs: [int64: .int64]
        )
        let result = try unsafe pair.unsafeInvoke((HostStoredCount(value: 40), 2))
        #expect(result.0.value == 42 && result.1 == 2)
        // A class reference keeps its subclass conversion.
        let derived = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.CompatibilityDerived")
        let name = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityName(_:)",
            as: ((CompatibilityDerived) -> String).self,
            valueABIs: [derived: .pointer]
        )
        let value = CompatibilityDerived()
        #expect(try unsafe name.unsafeInvoke(value) == value.name())
    }

    @Test func completeDeclarationsLowerLocalTypesThroughHostRepresentations() async throws {
        let outer = "ManagedSwiftFixtures.compatibilityLocalCount(Swift.Int64) -> Swift.Int64"
        let count = "Count #1 in " + outer
        let bump = try await runtime.resolveSwiftFunction(
            named: "bump #1 (\(count)) -> \(count) in \(outer)",
            as: ((HostCount) -> HostCount).self
        )
        #expect(try unsafe bump.unsafeInvoke(HostCount(value: 41)).value == 42)
    }

    @Test func labelOnlyNamesReturnOpaqueResultsAsTheirUnderlyingType() async throws {
        let function = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.compatibilityOpaqueCount()",
            as: (() -> Int64).self
        )
        #expect(try unsafe function.unsafeInvoke() == 41)
        let type = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.CompatibilityBase")
        let method = try await type.resolveMethod(named: "opaqueCount()", as: (() -> Int64).self)
        #expect(try unsafe method.unsafeInvoke(on: CompatibilityBase()) == 42)
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

/// A host representation of `CompatibilityCount`.
private struct HostCount: ABIBridgeValue {
    let value: Int64
    static var abiType: NativeType { .int64 }
    init(value: Int64) { self.value = value }
    init(nativeValue: NativeValue) throws { value = try unsafe nativeValue.read(as: Int64.self) }
    static func nativeValue(from value: HostCount) throws -> NativeValue {
        try NativeValue(copying: value.value, as: .int64)
    }
}

/// A host value with `CompatibilityCount`'s Swift storage.
private struct HostStoredCount: ABIBridgeSwiftValue {
    let value: Int64
    static var swiftABIType: NativeType { .int64 }
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
