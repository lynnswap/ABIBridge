#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ManagedSwiftFixtures
import ManagedSwiftAdapters
import Testing
import Foundation

private struct ScopedBodyOutput: ~Copyable { let number: Int64 }
private enum ScopedWritebackFailure: Error { case rejected }
private struct RejectingScopedCounter: ABIBridgeValue {
    static let abiType = NativeType.int64
    var number: Int64
    init(_ number: Int64) { self.number = number }
    init(nativeValue: NativeValue) throws { throw ScopedWritebackFailure.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value.number, as: abiType) }
}

struct SwiftOpaqueResultTests {
    @MainActor @Test func scopedNonescapableResultsExpireAndDestroyAfterTheBody() async throws {
        let runtime = ABIRuntime.shared
        let counts = ArgumentCounts()
        let owner = RuntimeScopedOwner(42, counts)
        let resultType = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.RuntimeScopedResult")
        let read = try await resultType.resolve(
            .swift(
                .method(
                    "read()",
                    as: (() -> Int64).self,
                    receiverABI: .opaque(named: resultType.name)
                )
            )
        )
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeScoped(_:_:)",
                    as: ((RuntimeScopedOwner, Bool) throws -> NativeSwiftBorrowedValue).self
                )
            )
        )
        var saved: NativeSwiftBorrowedValue?
        let value = try unsafe make.unsafeInvoke(owner, false, withResult: { result in
            saved = result
            #expect(counts.destructions == 0)
            #expect(throws: ABIResolutionError.self) { _ = try result.copy() }
            return try unsafe read.unsafeInvoke(on: result)
        })
        #expect(value == 42)
        #expect(counts.destructions == 1)
        let escaped = try #require(saved)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { _ = try unsafe read.unsafeInvoke(on: escaped) }
        #expect(throws: ABIResolutionError.self) { _ = try unsafe make.unsafeInvoke(owner, false) }
        #expect(counts.destructions == 1)
        #expect(throws: RuntimeTicketFailure.self) {
            try unsafe make.unsafeInvoke(owner, false, withResult: { _ -> Int in throw RuntimeTicketFailure.rejected })
        }
        #expect(counts.destructions == 2)
        #expect(throws: NativeSwiftError.self) {
            try unsafe make.unsafeInvoke(owner, true, withResult: { _ in Issue.record("Native failure must not call body"); return 0 })
        }
        #expect(counts.destructions == 2)
    }

    @MainActor @Test func scopedResultsComposeWithMembersAndAsyncBodies() async throws {
        let counts = ArgumentCounts()
        let owner = RuntimeScopedOwner(42, counts)
        let runtime = ABIRuntime.shared
        let resultType = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.RuntimeScopedResult")
        let read = try await resultType.resolve(
            .swift(
                .method(
                    "read()",
                    as: (() -> Int64).self,
                    receiverABI: .opaque(named: resultType.name)
                )
            )
        )
        let type = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.RuntimeScopedOwner")
        let method = try await type.resolve(
            .swift(.method("scoped()", as: (() -> NativeSwiftBorrowedValue).self))
        )
        let bound = try method.bind(to: owner)
        #expect(try unsafe bound.unsafeInvoke(withResult: { result in
            return try unsafe read.unsafeInvoke(on: result)
        }) == 42)
        #expect(counts.destructions == 1)
        let async = try await type.resolve(
            .swift(
                .method(
                    "scopedAsync()",
                    as: (() async -> NativeSwiftBorrowedValue).self
                )
            )
        )
        var saved: NativeSwiftBorrowedValue?
        let number = try unsafe await async.unsafeInvoke(on: owner, withResult: { result in
            saved = result
            await Task.yield()
            return try unsafe read.unsafeInvoke(on: result)
        })
        #expect(number == 42)
        #expect(counts.destructions == 2)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { _ = try saved?.copy() }
    }

    @MainActor @Test func scopedBodiesReturnNoncopyableValuesAndPreserveWritebackFailures() async throws {
        let runtime = ABIRuntime.shared
        let counts = ArgumentCounts()
        let owner = RuntimeScopedOwner(42, counts)
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeScoped(_:_:)",
                    as: ((RuntimeScopedOwner, Bool) throws -> NativeSwiftBorrowedValue).self
                )
            )
        )
        let output = try unsafe make.unsafeInvoke(owner, false, withResult: { _ in ScopedBodyOutput(number: 42) })
        #expect(output.number == 42)
        #expect(counts.destructions == 1)
        let type = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.RuntimeScopedCounter",
            as: RejectingScopedCounter.self
        )
        let sync = try await type.resolve(
            .swift(
                .method(
                    "scoped(_:_:)",
                    as: ((RuntimeScopedOwner, Bool) throws -> NativeSwiftBorrowedValue).self,
                    receiver: .mutating
                )
            )
        )
        var receiver = RejectingScopedCounter(41)
        do {
            _ = try unsafe sync.unsafeInvoke(on: &receiver, owner, false, withResult: { _ -> Int in throw RuntimeTicketFailure.rejected })
            Issue.record("Expected body and receiver writeback failures")
        } catch let error as NativeSwiftWritebackError {
            #expect(error.invocationError is RuntimeTicketFailure)
            #expect(error.writebackError is ScopedWritebackFailure)
        }
        #expect(counts.destructions == 2)
        let async = try await type.resolve(
            .swift(
                .method(
                    "scopedAsync(_:_:)",
                    as: ((RuntimeScopedOwner, Bool) async throws -> NativeSwiftBorrowedValue).self,
                    receiver: .mutating
                )
            )
        )
        do {
            _ = try unsafe await async.unsafeInvoke(on: &receiver, owner, false, withResult: { _ -> Int in
                await Task.yield()
                throw RuntimeTicketFailure.rejected
            })
            Issue.record("Expected async body and receiver writeback failures")
        } catch let error as NativeSwiftWritebackError {
            #expect(error.invocationError is RuntimeTicketFailure)
            #expect(error.writebackError is ScopedWritebackFailure)
        }
        #expect(counts.destructions == 3)
    }

    @MainActor @Test func asyncScopedFunctionsKeepInputsAndCleanUpFailurePaths() async throws {
        let runtime = ABIRuntime.shared
        let counts = ArgumentCounts()
        var owner: RuntimeScopedOwner? = RuntimeScopedOwner(42, counts)
        weak var observed = owner
        let resultType = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.RuntimeScopedResult")
        let read = try await resultType.resolve(
            .swift(
                .method(
                    "read()",
                    as: (() -> Int64).self,
                    receiverABI: .opaque(named: resultType.name)
                )
            )
        )
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeScopedAsync(_:_:)",
                    as: ((RuntimeScopedOwner, Bool) async throws -> NativeSwiftBorrowedValue).self
                )
            )
        )
        let output = try unsafe await make.unsafeInvoke(owner!, false, withResult: { value in
            owner = nil
            await Task.yield()
            #expect(observed != nil && counts.destructions == 0)
            return ScopedBodyOutput(number: try unsafe read.unsafeInvoke(on: value))
        })
        #expect(output.number == 42)
        #expect(counts.destructions == 1)
        #expect(observed == nil)
        let second = RuntimeScopedOwner(43, counts)
        await #expect(throws: RuntimeTicketFailure.self) {
            try unsafe await make.unsafeInvoke(second, false, withResult: { _ -> Int in
                await Task.yield()
                throw RuntimeTicketFailure.rejected
            })
        }
        #expect(counts.destructions == 2)
        await #expect(throws: NativeSwiftError.self) {
            try unsafe await make.unsafeInvoke(second, true, withResult: { _ in Issue.record("Native failure called body"); return 0 })
        }
        #expect(counts.destructions == 2)
    }

    @Test func genericOpaqueResultsBindCapturedTypesAndConformances() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeGenericOpaque<A>(A) -> some",
                    as: ((String) -> NativeSwiftValue).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let value = try unsafe make.unsafeInvoke("captured")
        let reference = makeGenericOpaque("reference")
        try value.withCopy { #expect(ObjectIdentifier(Swift.type(of: $0)) == ObjectIdentifier(Swift.type(of: reference))) }
        let constrained = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeConstrainedOpaque<A where A: ManagedSwiftFixtures.ExistentialValue>(A) -> some",
                    as: ((InlineExistentialValue) -> NativeSwiftValue).self,
                    genericArguments: [.type(InlineExistentialValue.self)]
                )
            )
        )
        let constrainedValue = try unsafe constrained.unsafeInvoke(InlineExistentialValue(43))
        try constrainedValue.withCopy { #expect(($0 as? any ExistentialValue)?.number == 43) }
        let object = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeGenericOpaqueObject<A where A: ManagedSwiftFixtures.ExistentialObjectValue>(A) -> some",
                    as: ((ExistentialObject) -> NativeSwiftValue).self,
                    genericArguments: [.type(ExistentialObject.self)]
                )
            )
        )
        let original = ExistentialObject(ErrorLifetimeToken(), 44)
        let objectValue = try unsafe object.unsafeInvoke(original)
        try objectValue.withCopy { #expect(($0 as? ExistentialObject) === original) }
    }

    @Test func protocolExtensionMembersBindTheWholeConcreteSelf() async throws {
        let runtime = ABIRuntime.shared
        func check<Value: ExistentialValue>(_ original: Value) async throws {
            let copy = try await runtime.resolve(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                        as: ((Value) -> NativeSwiftValue).self,
                        genericArguments: [.type(Value.self)]
                    )
                )
            )
            let owner = try unsafe copy.unsafeInvoke(original)
            let getter = try await owner.type.resolve(
                .swift(
                    .getter(
                        "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue.protocolExtensionValue.getter : A",
                        as: (() -> NativeSwiftValue).self
                    )
                )
            )
            try unsafe getter.unsafeInvoke(on: owner).withCopy {
                #expect(($0 as? Value)?.number == original.number)
            }
            let staticMethod = try await owner.type.resolve(
                .swift(
                    .staticMethod(
                        "static (extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue.protocolExtensionStatic(A) -> Swift.Int64",
                        as: ((Value) -> Int64).self
                    )
                )
            )
            #expect(try unsafe staticMethod.unsafeInvoke(original) == original.number)
            let opaque = try await owner.type.resolve(
                .swift(
                    .method(
                        "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue.protocolExtensionOpaque() -> some",
                        as: (() -> NativeSwiftValue).self
                    )
                )
            )
            let result = try unsafe opaque.unsafeInvoke(on: owner)
            let reference = original.protocolExtensionOpaque()
            try result.withCopy {
                #expect(($0 as? any ExistentialValue)?.number == original.number)
                #expect(
                    ObjectIdentifier(Swift.type(of: $0))
                        == ObjectIdentifier(Swift.type(of: reference))
                )
            }
            let pair = try await owner.type.resolve(
                .swift(
                    .method(
                        "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue.protocolExtensionPair<A>(A1) -> (A, A1)",
                        as: ((String) -> NativeSwiftValue).self,
                        genericArguments: [.type(String.self)]
                    )
                )
            )
            let paired = try unsafe pair.unsafeInvoke(on: owner, "method argument")
            try paired.withCopy {
                let value = try #require($0 as? (Value, String))
                #expect(value.0.number == original.number && value.1 == "method argument")
            }
            #expect(!owner.isConsumed)
            #expect(try owner.take(as: Value.self).number == original.number)
        }
        try await check(InlineExistentialValue(41))
        try await check(ProtocolExtensionValue("generic receiver", 42))
        let concrete = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.InlineExistentialValue"
        )
        let number = try await concrete.resolve(
            .swift(
                .method(
                    "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue< where A == ManagedSwiftFixtures.InlineExistentialValue>.protocolExtensionConcreteNumber() -> Swift.Int64",
                    as: (() -> Int64).self,
                    valueABIs: [concrete: .int64]
                )
            )
        )
        #expect(try unsafe number.unsafeInvoke(on: InlineExistentialValue(44)) == 44)
    }

    @Test func protocolExtensionClassReceiversFollowTheFormalSelfConvention() async throws {
        let runtime = ABIRuntime.shared
        let copy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((ProtocolExtensionObject) -> NativeSwiftValue).self,
                    genericArguments: [.type(ProtocolExtensionObject.self)]
                )
            )
        )
        let counts = ArgumentCounts()
        weak var observed: ErrorLifetimeToken?
        var result: NativeSwiftValue?
        do {
            let token = ErrorLifetimeToken { counts.destroyed() }
            observed = token
            let original = ProtocolExtensionObject(token, 43)
            let owner = try unsafe copy.unsafeInvoke(original)
            let staticMethod = try await owner.type.resolve(
                .swift(
                    .staticMethod(
                        "static (extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue.protocolExtensionStatic(A) -> Swift.Int64",
                        as: ((ProtocolExtensionObject) -> Int64).self
                    )
                )
            )
            #expect(try unsafe staticMethod.unsafeInvoke(original) == 43)
            let opaque = try await owner.type.resolve(
                .swift(
                    .method(
                        "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue.protocolExtensionOpaque() -> some",
                        as: (() -> NativeSwiftValue).self
                    )
                )
            )
            result = try unsafe opaque.unsafeInvoke(on: owner)
            for declaration in [
                "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialObjectValue.protocolExtensionNumber() -> Swift.Int64",
                "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue< where A: AnyObject>.protocolExtensionClassNumber() -> Swift.Int64",
            ] {
                let method = try await owner.type.resolve(
                    .swift(
                        .method(
                            declaration,
                            as: (() -> Int64).self
                        )
                    )
                )
                #expect(try unsafe method.unsafeInvoke(on: owner) == 43)
            }
            #expect(!owner.isConsumed)
            let represented = try await runtime.resolveSwiftType(
                named: "ManagedSwiftFixtures.ProtocolExtensionObject",
                as: AnyObject.self
            )
            let method = try await represented.resolve(
                .swift(
                    .method(
                        "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue.protocolExtensionOpaque() -> some",
                        as: (() -> NativeSwiftValue).self
                    )
                )
            )
            let bound = try method.bind(to: ProtocolExtensionObject(token, 45))
            try unsafe bound.unsafeInvoke().withCopy {
                #expect(($0 as? any ExistentialValue)?.number == 45)
            }
            let incompatible = try method.bind(to: NSObject())
            #expect(throws: ABIInvocationError.self) { _ = try unsafe incompatible.unsafeInvoke() }
        }
        #expect(observed != nil && counts.destructions == 0)
        try result?.withCopy { #expect(($0 as? any ExistentialValue)?.number == 43) }
        result = nil
        #expect(observed == nil && counts.destructions == 1)
        let textObject = RuntimeKeyPathReferenceRoot("original")
        for declaration in [
            "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ProtocolExtensionTextObject.protocolExtensionText.setter : Swift.String",
            "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ProtocolExtensionTextValue< where A: AnyObject>.protocolExtensionConstrainedText.setter : Swift.String",
        ] {
            let setter = try await runtime.object(textObject).resolve(
                .swift(
                    .setter(
                        declaration,
                        as: ((String) -> Void).self
                    )
                )
            )
            let updated = textObject.text + ":updated"
            try unsafe setter.unsafeInvoke(updated)
            #expect(textObject.text == updated)
        }
    }

    @Test func protocolExtensionMembersRequireTheConcreteSelfConformance() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(named: "Swift.String")
        do {
            _ = try await type.resolve(
                .swift(
                    .method(
                        "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue.protocolExtensionOpaque() -> some",
                        as: (() -> NativeSwiftValue).self
                    )
                )
            )
            Issue.record("A nonconforming receiver was accepted")
        } catch ABIResolutionError.signatureMismatch {}
    }

    @Test func mutatingProtocolExtensionSelfPreservesTheOwnedStorageType() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.ProtocolExtensionObject"
        )
        let replace = try await type.resolve(
            .swift(
                .method(
                    "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue.protocolExtensionReplace(A) -> ()",
                    as: ((ProtocolExtensionObject) -> Void).self,
                    receiver: .mutating
                )
            )
        )
        let copy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((ProtocolExtensionObject) -> NativeSwiftValue).self,
                    genericArguments: [.type(ProtocolExtensionObject.self)]
                )
            )
        )
        let owner = try unsafe copy.unsafeInvoke(ProtocolExtensionObject(ErrorLifetimeToken(), 41))
        let replacement = ProtocolExtensionObject(ErrorLifetimeToken(), 42)
        try unsafe replace.unsafeInvoke(on: owner, replacement)
        try owner.withCopy { #expect(($0 as? ProtocolExtensionObject) === replacement) }
        #expect(!owner.isConsumed)
        let setter = try await type.resolve(
            .swift(
                .setter(
                    "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue.protocolExtensionValue.setter : A",
                    as: ((ProtocolExtensionObject) -> Void).self
                )
            )
        )
        let reset = ProtocolExtensionObject(ErrorLifetimeToken(), 44)
        try unsafe setter.unsafeInvoke(on: owner, reset)
        try owner.withCopy { #expect(($0 as? ProtocolExtensionObject) === reset) }
        let copyDerived = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((ProtocolExtensionDerivedObject) -> NativeSwiftValue).self,
                    genericArguments: [.type(ProtocolExtensionDerivedObject.self)]
                )
            )
        )
        let derived = try unsafe copyDerived.unsafeInvoke(
            ProtocolExtensionDerivedObject(ErrorLifetimeToken(), 43)
        )
        #expect(throws: ABIInvocationError.self) {
            try unsafe replace.unsafeInvoke(on: derived, replacement)
        }
        try derived.withCopy { #expect(($0 as? ProtocolExtensionDerivedObject)?.number == 43) }
        let classReplace = try await type.resolve(
            .swift(
                .method(
                    "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue< where A: AnyObject>.protocolExtensionClassReplace(A) -> ()",
                    as: ((ProtocolExtensionObject) -> Void).self,
                    receiver: .mutating
                )
            )
        )
        try #require(throws: ABIResolutionError.self) { _ = try classReplace.bind(to: replacement) }
        try unsafe classReplace.unsafeInvoke(on: owner, replacement)
        try owner.withCopy { #expect(($0 as? ProtocolExtensionObject) === replacement) }
        var typed = reset
        try unsafe classReplace.unsafeInvoke(on: &typed, replacement)
        #expect(typed === replacement)
        let classSetter = try await type.resolve(
            .swift(
                .setter(
                    "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue< where A: AnyObject>.protocolExtensionClassValue.setter : A",
                    as: ((ProtocolExtensionObject) -> Void).self,
                    receiver: .mutating
                )
            )
        )
        try #require(throws: ABIResolutionError.self) { _ = try classSetter.bind(to: reset) }
        try unsafe classSetter.unsafeInvoke(on: owner, reset)
        try owner.withCopy { #expect(($0 as? ProtocolExtensionObject) === reset) }
        let equalSetter = try await type.resolve(
            .swift(
                .setter(
                    "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.ExistentialValue< where A == ManagedSwiftFixtures.ProtocolExtensionObject>.protocolExtensionEqualClassValue.setter : ManagedSwiftFixtures.ProtocolExtensionObject",
                    as: ((ProtocolExtensionObject) -> Void).self
                )
            )
        )
        try #require(throws: ABIResolutionError.self) { _ = try equalSetter.bind(to: replacement) }
        try unsafe equalSetter.unsafeInvoke(on: owner, replacement)
        try owner.withCopy { #expect(($0 as? ProtocolExtensionObject) === replacement) }
    }

    @Test func protocolExtensionSuperclassConstraintsPreserveRequiredWitnesses() async throws {
        let runtime = ABIRuntime.shared
        let cases: [(AnyObject, String, String)] = [
            (
                ProtocolExtensionObject(ErrorLifetimeToken(), 41), "ProtocolExtensionObject",
                "protocolExtensionSuperclassWitness"
            ),
            (
                ProtocolExtensionWitnessSubclass(ErrorLifetimeToken(), 42), "OpaqueBase",
                "protocolExtensionSubclassWitness"
            ),
        ]
        for (receiver, superclass, member) in cases {
            let method = try await runtime.object(receiver).resolve(
                .swift(
                    .method(
                        "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.GenericWitnessA< where A: ManagedSwiftFixtures.\(superclass)>.\(member)<A where A1: ManagedSwiftFixtures.GenericWitnessZ>(A1) -> Swift.Int64",
                        as: ((GenericWitnessValue) -> Int64).self,
                        genericArguments: [.type(GenericWitnessValue.self)],
                        declaredAs: superclass == "ProtocolExtensionObject"
                            ? "<A, A1 where A: ManagedSwiftFixtures.ProtocolExtensionObject, A1: ManagedSwiftFixtures.GenericWitnessZ> (A1) -> Swift.Int64"
                            : nil
                    )
                )
            )
            let value = try unsafe method.unsafeInvoke(GenericWitnessValue())
            #expect(value == 42)
        }
    }

    @Test func protocolExtensionReceiversFulfillGenericRequirements() async throws {
        let runtime = ABIRuntime.shared
        let original = GenericSourceNested(GenericWitnessValue())
        let copy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((GenericSourceNested<GenericWitnessValue>) -> NativeSwiftValue).self,
                    genericArguments: [.type(GenericSourceNested<GenericWitnessValue>.self)]
                )
            )
        )
        let owner = try unsafe copy.unsafeInvoke(original)
        for (name, mutating) in [
            ("protocolExtensionSuperclassSource", false),
            ("protocolExtensionMutatingSuperclassSource", true),
        ] {
            let method = try await owner.type.resolve(
                .swift(
                    .method(
                        "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.GenericWitnessA.\(name)<A where A: ManagedSwiftFixtures.GenericSourceNested<A1>, A1: ManagedSwiftFixtures.GenericWitnessZ>() -> Swift.Int64",
                        as: (() -> Int64).self,
                        genericArguments: [.type(GenericWitnessValue.self)],
                        declaredAs:
                            "<A, A1 where A: ManagedSwiftFixtures.GenericSourceNested<A1>, A1: ManagedSwiftFixtures.GenericWitnessZ> () -> Swift.Int64",
                        receiver: mutating ? .mutating : nil
                    )
                )
            )
            #expect(try unsafe method.unsafeInvoke(on: owner) == 2)
        }
        let replace = try await owner.type.resolve(
            .swift(
                .method(
                    "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.GenericWitnessA.protocolExtensionEqualClassSource<A where A == ManagedSwiftFixtures.GenericSourceNested<A1>, A1: ManagedSwiftFixtures.GenericSourceChild>(ManagedSwiftFixtures.GenericSourceBox<A1>) -> Swift.Int64",
                    as: ((GenericSourceBox<GenericWitnessValue>) -> Int64).self,
                    genericArguments: [.type(GenericWitnessValue.self)],
                    receiver: .mutating
                )
            )
        )
        #expect(
            try unsafe replace.unsafeInvoke(on: owner, GenericSourceBox(GenericWitnessValue())) == 2
        )
        try owner.withCopy {
            let replacement = try #require($0 as? GenericSourceNested<GenericWitnessValue>)
            #expect(replacement !== original)
        }
        #expect(!owner.isConsumed)
    }

    @Test func protocolExtensionValueReceiversPreserveNominalMetadata() async throws {
        let runtime = ABIRuntime.shared
        func own<Value>(_ value: Value) async throws -> NativeSwiftValue {
            let copy = try await runtime.resolve(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                        as: ((Value) -> NativeSwiftValue).self,
                        genericArguments: [.type(Value.self)]
                    )
                )
            )
            return try unsafe copy.unsafeInvoke(value)
        }
        let indirect = try await own(GenericValueBox(GenericWitnessValue()))
        let indirectMethod = try await indirect.type.resolve(
            .swift(
                .method(
                    "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.GenericWitnessA.protocolExtensionIndirectSource<A where A == ManagedSwiftFixtures.GenericValueBox<A1>, A1: ManagedSwiftFixtures.GenericWitnessZ>() -> Swift.Int64",
                    as: (() -> Int64).self,
                    genericArguments: [.type(GenericWitnessValue.self)]
                )
            )
        )
        #expect(try unsafe indirectMethod.unsafeInvoke(on: indirect) == 2)
        let direct = try await own(GenericPhantom<GenericWitnessValue>(40))
        let directMethod = try await direct.type.resolve(
            .swift(
                .method(
                    "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.GenericWitnessA.protocolExtensionDirectSource<A where A == ManagedSwiftFixtures.GenericPhantom<A1>, A1: ManagedSwiftFixtures.GenericWitnessZ>() -> Swift.Int64",
                    as: (() -> Int64).self,
                    genericArguments: [.type(GenericWitnessValue.self)],
                    receiverABI: .int64
                )
            )
        )
        #expect(try unsafe directMethod.unsafeInvoke(on: direct) == 42)
        let staticMethod = try await direct.type.resolve(
            .swift(
                .staticMethod(
                    "static (extension in ManagedSwiftFixtures):ManagedSwiftFixtures.GenericWitnessA.protocolExtensionThinStaticSource<A where A == ManagedSwiftFixtures.GenericPhantom<A1>, A1: ManagedSwiftFixtures.GenericWitnessZ>() -> Swift.Int64",
                    as: (() -> Int64).self,
                    genericArguments: [.type(GenericWitnessValue.self)]
                )
            )
        )
        #expect(try unsafe staticMethod.unsafeInvoke() == 2)
    }

    @Test func genericOpaqueMembersCombineEnclosingAndMethodBindings() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.GenericOpaqueOwner",
            genericArguments: [.type(String.self)])
        let initialize = try await type.resolve(
            .swift(.initializer("init(_:)", as: ((String) -> AnyObject).self))
        )
        let owner = try unsafe initialize.unsafeInvoke("outer")
        let getter = try await runtime.object(owner).resolve(
            .swift(
                .getter(
                    "opaque",
                    as: (() -> NativeSwiftValue).self
                )
            )
        )
        let method = try await runtime.object(owner).resolve(
            .swift(
                .method(
                    "make(_:)",
                    as: ((Int64) -> NativeSwiftValue).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let first = try unsafe getter.unsafeInvoke()
        let second = try unsafe method.unsafeInvoke(42)
        let reference = GenericOpaqueOwner("outer")
        try first.withCopy { #expect(ObjectIdentifier(Swift.type(of: $0)) == ObjectIdentifier(Swift.type(of: reference.opaque))) }
        try second.withCopy { #expect(ObjectIdentifier(Swift.type(of: $0)) == ObjectIdentifier(Swift.type(of: reference.make(Int64(42))))) }
    }

    @Test func returnedClosuresResolveNestedOpaqueMetadata() async throws {
        let factory = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeNestedOpaque()",
                    as: (() -> NativeSwiftClosure<() -> NativeSwiftValue>).self
                )
            )
        )
        let closure = try unsafe factory.unsafeInvoke()
        let result = try unsafe closure.unsafeInvoke()
        #expect(try result.take(as: Int64.self) == 42)
    }

    @Test func opaqueResultsSharePreparationWithClosureArguments() async throws {
        let call = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueUsingCallback(_:)",
                    as: ((NativeSwiftClosure<(Int64) -> Int64>) -> NativeSwiftValue).self
                )
            )
        )
        let value = try unsafe call.unsafeInvoke(NativeSwiftClosure { $0 + 1 })
        #expect(try value.take(as: Int64.self) == 42)
        let typed = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueUsingCallback((Swift.Int64) -> Swift.Int64) -> some",
                    as: ((NativeSwiftClosure<(Int64) -> Int64>) -> Int64).self
                )
            )
        )
        #expect(try unsafe typed.unsafeInvoke(NativeSwiftClosure { $0 + 1 }) == 42)
    }

    @Test func declaredClassConstraintsSelectDirectResultsAndRetainObjects() async throws {
        let runtime = ABIRuntime.shared
        for (name, expected) in [("makeOpaqueClassAny", 41), ("makeOpaqueClassProtocol", 42),
                                 ("makeOpaqueSuperclass", 43), ("makeOpaqueUnconstrainedClass", 44)] {
            let call = try await runtime.resolve(
                .swift(
                    .function(
                        "ManagedSwiftFixtures." + name + "(_:)",
                        as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                    )
                )
            )
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
        let call = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueObjC(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let result = try unsafe call.unsafeInvoke(ErrorLifetimeToken())
        try result.withCopy { #expect($0 is NSObject) }
    }

    @Test func directOpaqueResultsIntegrateWithErrorsAndAsyncCompletion() async throws {
        let runtime = ABIRuntime.shared
        let call = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueClassThrowing(_:_:)",
                    as: ((ErrorLifetimeToken, Bool) throws(ScalarFailure) -> NativeSwiftValue).self
                )
            )
        )
        let token = ErrorLifetimeToken()
        try unsafe call.unsafeInvoke(token, false).withCopy { #expect(($0 as? any ExistentialObjectValue)?.number == 45) }
        do { _ = try unsafe call.unsafeInvoke(token, true); Issue.record("Expected direct opaque failure") }
        catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) } }
        let async = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueClassAsync(_:_:)",
                    as: (@concurrent (AsyncGate, ErrorLifetimeToken) async -> NativeSwiftValue).self
                )
            )
        )
        let gate = AsyncGate()
        let task = Task {
            let value = try unsafe await async.unsafeInvoke(gate, token)
            return try value.withCopy { ($0 as? any ExistentialObjectValue)?.number }
        }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await task.value == 46)
    }

    @Test func extensionMembersUseTheirMatchedOpaqueOrigin() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(named: "ManagedSwiftFixtures.OpaqueOwner")
        let owner = OpaqueOwner(ErrorLifetimeToken())
        let method = try await type.resolve(
            .swift(
                .method(
                    "extensionOpaque(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let getter = try await type.resolve(
            .swift(.getter("extensionSummary", as: (() -> NativeSwiftValue).self))
        )
        let object = try await type.resolve(
            .swift(
                .method(
                    "extensionClassOpaque()",
                    as: (() -> NativeSwiftValue).self
                )
            )
        )
        try unsafe method.unsafeInvoke(on: owner, 47).withCopy { #expect(($0 as? any ExistentialValue)?.number == 47) }
        try unsafe getter.unsafeInvoke(on: owner).withCopy { #expect(($0 as? any ExistentialValue)?.number == 48) }
        try unsafe object.unsafeInvoke(on: owner).withCopy { #expect(($0 as? any ExistentialObjectValue)?.number == 49) }
    }

    @Test func hiddenManagedValueCanBeErasedAndOpenedWithoutItsConcreteType() async throws {
        let call = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaque(_:_:)",
                    as: ((ErrorLifetimeToken, Int64) -> NativeSwiftValue).self
                )
            )
        )
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
        let call = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaque(_:_:)",
                    as: ((ErrorLifetimeToken, Int64) -> NativeSwiftValue).self
                )
            )
        )
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
        let integer = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let empty = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueEmpty()",
                    as: (() -> NativeSwiftValue).self
                )
            )
        )
        let value = try unsafe integer.unsafeInvoke(42)
        #expect(value.type.name == "Swift.Int64")
        try value.withCopy { #expect($0 as? Int64 == 42) }
        let nothing = try unsafe empty.unsafeInvoke()
        #expect(nothing.type.name == "()")
        try nothing.withCopy { #expect($0 is Void) }
    }

    @Test func throwingCompletionDoesNotDestroyAnUninitializedResult() async throws {
        let call = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueThrowing(_:_:)",
                    as: ((ErrorLifetimeToken, Bool) throws(ScalarFailure) -> NativeSwiftValue).self
                )
            )
        )
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
        let call = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueAsync(_:_:_:)",
                    as: (@concurrent (AsyncGate, ErrorLifetimeToken, Bool)
                        async throws(ScalarFailure)
                        -> NativeSwiftValue).self
                )
            )
        )
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
        let type = try await ABIRuntime.shared.resolveSwiftType(named: "ManagedSwiftFixtures.OpaqueOwner")
        let token = ErrorLifetimeToken(), owner = OpaqueOwner(token)
        let method = try await type.resolve(
            .swift(.method("make(_:)", as: ((Int64) -> NativeSwiftValue).self))
        )
        let getter = try await type.resolve(
            .swift(.getter("summary", as: (() -> NativeSwiftValue).self))
        )
        let staticMethod = try await type.resolve(
            .swift(
                .staticMethod(
                    "makeStatic(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        try unsafe method.unsafeInvoke(on: owner, 41).withCopy { #expect(($0 as? any ExistentialValue)?.number == 41) }
        try unsafe getter.unsafeInvoke(on: owner).withCopy { #expect(($0 as? any ExistentialValue)?.number == 42) }
        try unsafe staticMethod.unsafeInvoke(token).withCopy { #expect(($0 as? any ExistentialValue)?.number == 43) }
        let async = try await type.resolve(
            .swift(
                .method(
                    "makeAsync(_:)",
                    as: (@concurrent (AsyncGate) async -> NativeSwiftValue).self
                )
            )
        )
        let gate = AsyncGate()
        let task = Task {
            let result = try unsafe await async.unsafeInvoke(on: owner, gate)
            return try result.withCopy { ($0 as? any ExistentialValue)?.number }
        }
        await gate.waitUntilSuspended(); await gate.open()
        #expect(try await task.value == 44)
    }

    @Test func opaqueContainersPreserveFormalIndirectionAndClosureAuthentication() async throws {
        let runtime = ABIRuntime.shared
        for name in ["makeOptionalOpaqueObject", "makeOptionalClassOpaqueObject"] {
            let call = try await runtime.resolve(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.\(name)(ManagedSwiftFixtures.ErrorLifetimeToken, Swift.Bool) -> some?",
                        as: ((ErrorLifetimeToken, Bool) -> NativeSwiftValue).self
                    )
                )
            )
            for present in [false, true] {
                let result = try unsafe call.unsafeInvoke(ErrorLifetimeToken(), present)
                #expect(try result.withCopy { ($0 as? any ExistentialValue)?.number } == (present ? 42 : nil))
            }
        }
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOptionalOpaqueClosure(ManagedSwiftFixtures.ErrorLifetimeToken) -> (Swift.Bool) -> some?",
                    as: ((ErrorLifetimeToken) -> NativeSwiftClosure<(Bool) -> NativeSwiftValue>)
                        .self
                )
            )
        )
        let body = try unsafe factory.unsafeInvoke(ErrorLifetimeToken())
        for present in [false, true] {
            let result = try unsafe body.unsafeInvoke(present)
            #expect(try result.withCopy { ($0 as? any ExistentialValue)?.number } == (present ? 42 : nil))
        }
        let throwingFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOptionalOpaqueThrowingClosure(ManagedSwiftFixtures.ErrorLifetimeToken) -> (Swift.Bool) throws(ManagedSwiftFixtures.ScalarFailure) -> some?",
                    as: ((ErrorLifetimeToken) -> NativeSwiftClosure<
                        (Bool) throws(ScalarFailure) -> NativeSwiftValue
                    >).self
                )
            )
        )
        let throwing = try unsafe throwingFactory.unsafeInvoke(ErrorLifetimeToken())
        do { _ = try unsafe throwing.unsafeInvoke(false); Issue.record("Expected native failure") }
        catch let error as NativeSwiftError { #expect(error.withUnderlyingError { ($0 as? ScalarFailure)?.code } == 42) }
        #expect(try unsafe throwing.unsafeInvoke(true).withCopy { ($0 as? any ExistentialValue)?.number } == 42)
        let asyncFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOptionalOpaqueAsyncClosure(ManagedSwiftFixtures.ErrorLifetimeToken) -> @Sendable (Swift.Bool) async -> some?",
                    as: ((ErrorLifetimeToken) -> NativeSwiftClosure<
                        @Sendable @concurrent (Bool) async -> NativeSwiftValue
                    >).self
                )
            )
        )
        let async = try unsafe asyncFactory.unsafeInvoke(ErrorLifetimeToken())
        for present in [false, true] {
            let result = try unsafe await async.unsafeInvoke(present)
            #expect(try result.withCopy { ($0 as? any ExistentialValue)?.number } == (present ? 42 : nil))
        }
        let box = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeInlineOpaqueBox(ManagedSwiftFixtures.ErrorLifetimeToken) -> ManagedSwiftFixtures.InlineOpaqueBox<some>",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let result = try unsafe box.unsafeInvoke(ErrorLifetimeToken())
        #expect(try result.withCopy { ($0 as? any CustomStringConvertible)?.description } == "42")
    }

    @Test func opaqueReturnedClosuresMaterializeManagedTupleArguments() async throws {
        let runtime = ABIRuntime.shared
        let declaration = "ManagedSwiftFixtures.makeOpaqueTupleClosure() -> ((Swift.Int64, Swift.String, ManagedSwiftFixtures.ErrorLifetimeToken)) -> some"
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    declaration,
                    as: (() -> NativeSwiftClosure<
                        ((Int64, String, ErrorLifetimeToken)) -> NativeSwiftValue
                    >).self
                )
            )
        )
        let body = try unsafe factory.unsafeInvoke()
        let erasedFactory = try await runtime.resolve(
            .swift(
                .function(
                    declaration,
                    as: (() -> NativeSwiftValue).self
                )
            )
        )
        let erased = try unsafe erasedFactory.unsafeInvoke()
        let native = try erased.take(as: (((Int64, String, ErrorLifetimeToken)) -> String).self)
        let consume = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueConsumingTupleClosure() -> (__owned (Swift.Int64, Swift.String, ManagedSwiftFixtures.ErrorLifetimeToken)) -> some",
                    as: (() -> NativeSwiftClosure<
                        (NativeSwiftConsuming<(Int64, String, ErrorLifetimeToken)>) ->
                            NativeSwiftValue
                    >).self
                )
            )
        )
        let consuming = try unsafe consume.unsafeInvoke()
        let counts = ArgumentCounts()
        weak var observed: ErrorLifetimeToken?
        do {
            let token = ErrorLifetimeToken { counts.destroyed() }
            observed = token
            let value = try unsafe body.unsafeInvoke((Int64(42), "borrowed", token))
            #expect(try value.withCopy { $0 as? String } == "42:borrowed")
            #expect(native((43, "erased", token)) == "43:erased")
            let consumed = try unsafe consuming.unsafeInvoke(NativeSwiftConsuming((Int64(44), "consumed", token)))
            #expect(try consumed.withCopy { $0 as? String } == "44:consumed")
        }
        #expect(observed == nil && counts.destructions == 1)
    }

    @Test func genericOpaqueTupleResultsResolveEveryUnderlyingIndex() async throws {
        let call = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeGenericOpaquePair<A, B>(A, B) -> (some, some)",
                    as: ((String, Int) -> (NativeSwiftValue, NativeSwiftValue)).self,
                    genericArguments: [.type(String.self), .type(Int.self)]
                )
            )
        )
        let result = try unsafe call.unsafeInvoke("tuple", 42)
        #expect(try result.0.withCopy { $0 as? String } == "tuple")
        #expect(try result.1.withCopy { $0 as? Int } == 42)
    }

    @Test func nestedAndGenericOpaqueContractsRequireDeclarationPlanning() async throws {
        let nested = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeNestedOpaque() -> () -> some",
                    as: (() -> NativeSwiftValue).self
                )
            )
        )
        let nestedResult = try unsafe nested.unsafeInvoke()
        #expect(try nestedResult.withCopy { ($0 as? () -> Int64)?() } == 42)
        #expect(throws: ABIResolutionError.self) {
            _ = try ABIRuntime.shared.resolveAndWait(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.makeGenericOpaque<A>(A) -> some",
                        as: ((Int64) -> NativeSwiftValue).self
                    )
                )
            )
        }
    }

    @Test func runtimeValueResultsPreserveNativeExistentials() async throws {
        let echo = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.echoAny(Any) -> Any",
                    as: ((Any) -> NativeSwiftValue).self
                )
            )
        )
        let value = try unsafe echo.unsafeInvoke("runtime existential" as Any)
        let result = try value.take(as: Any.self)
        #expect(result as? String == "runtime existential")

    }
}
