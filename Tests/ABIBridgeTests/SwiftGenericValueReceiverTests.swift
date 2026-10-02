import ABIBridge
import Foundation
import ManagedSwiftFixtures
import Testing

extension GenericObjectValue: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .pointer }
}
extension GenericSuperclassValue: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .pointer }
}

extension GenericPhantom: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .int64 }
}

extension GenericValueBox: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        if Value.self == Int.self { return .int }
        if Value.self is AnyClass || Value.self == [String].self { return .pointer }
        return try! .opaque(named: "GenericValueBox")
    }
}

@Suite(.serialized)
struct SwiftGenericValueReceiverTests {
    @Test func memberWitnessesUseTheCanonicalRefinedSignature() async throws {
        let runtime = ABIRuntime()
        let associatedType = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericAssociatedOwner",
            genericArguments: [.type(GenericAssociatedValue.self)])
        let associated = try await associatedType.staticMethod(named: "associatedWitness(_:_:_:)",
            as: ((String, GenericGetterFailure, Bool) throws(GenericGetterFailure) -> Int).self,
            genericArguments: [.type(GenericGetterFailure.self)])
        #expect(try unsafe associated.unsafeInvoke("associated", GenericGetterFailure(42), false) == "associated".hashValue)
        do {
            _ = try unsafe associated.unsafeInvoke("associated", GenericGetterFailure(42), true)
            Issue.record("Expected the member's typed error.")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? GenericGetterFailure)?.code == 42 })
        }
        let aliasedType = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericAssociatedAliasOwner",
            genericArguments: [.type(GenericAssociatedValue.self), .type(String.self)])
        let aliased = try await aliasedType.staticMethod(named: "aliasedWitness(_:_:_:)",
            as: ((String, GenericGetterFailure, Bool) throws(GenericGetterFailure) -> Int).self,
            genericArguments: [.type(GenericGetterFailure.self)])
        #expect(try unsafe aliased.unsafeInvoke("aliased", GenericGetterFailure(43), false) == "aliased".hashValue)
        do {
            _ = try unsafe aliased.unsafeInvoke("aliased", GenericGetterFailure(43), true)
            Issue.record("Expected the aliased member's typed error.")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? GenericGetterFailure)?.code == 43 })
        }
        let refined = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericHashOwner",
            genericArguments: [.type(String.self)])
        let hash = try await refined.staticMethod(named: "refinedWitness(_:)", as: ((String) -> Int).self)
        #expect(try unsafe hash.unsafeInvoke("hash") == GenericHashOwner<String>.refinedWitness("hash"))
        let concrete = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericHashOwner",
            genericArguments: [.type(Int.self)])
        let additional = try await concrete.staticMethod(named: "concreteWitness(_:)", as: ((String) -> Int).self,
            genericArguments: [.type(String.self)])
        #expect(try unsafe additional.unsafeInvoke("concrete") == GenericHashOwner<Int>.concreteWitness("concrete"))
        let ordered = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericWitnessOwner",
            genericArguments: [.type(GenericWitnessValue.self)])
        let both = try await ordered.staticMethod(named: "orderedWitnesses()", as: (() -> Int64).self)
        #expect(try unsafe both.unsafeInvoke() == GenericWitnessOwner<GenericWitnessValue>.orderedWitnesses())
    }

    @MainActor @Test func qualifiedMembersSelectTheRequestedConstraint() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericValueBox",
            genericArguments: [.type(Int.self)])
        let receiver = GenericValueBox(42)
        for (constraint, result) in [("Swift.Equatable", Int64(10)), ("Swift.Hashable", Int64(20))] {
            let prefix = constraint == "Swift.Equatable" ? "" : "(extension in ManagedSwiftFixtures):"
            let owner = prefix + "ManagedSwiftFixtures.GenericValueBox<A where A: " + constraint + ">"
            let method = try await type.method(named: owner + ".selected() -> Swift.Int64", as: (() -> Int64).self)
            let getter = try await type.getter(named: owner + ".selectedValue.getter : Swift.Int64", as: (() -> Int64).self)
            let staticMethod = try await type.staticMethod(named: "static " + owner + ".selectedStatic() -> Swift.Int64", as: (() -> Int64).self)
            let staticGetter = try await type.staticGetter(named: "static " + owner + ".selectedStaticValue.getter : Swift.Int64", as: (() -> Int64).self)
            #expect(try unsafe method.unsafeInvoke(on: receiver) == result + 1)
            #expect(try unsafe getter.unsafeInvoke(on: receiver) == result + 2)
            #expect(try unsafe staticMethod.unsafeInvoke() == result + 3)
            #expect(try unsafe staticGetter.unsafeInvoke() == result + 4)
        }
        do {
            _ = try await type.method(named: "selected()", as: (() -> Int64).self)
            Issue.record("Expected the short member name to remain ambiguous")
        } catch ABIResolutionError.ambiguousDeclaration {}
        do {
            _ = try await type.method(named: "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.GenericValueBox<A where A: Swift.Comparable>.selected() -> Swift.Int64", as: (() -> Int64).self)
            Issue.record("An unavailable qualified declaration must not select another constraint")
        } catch ABIResolutionError.declarationNotFound {}
        do {
            _ = try await type.method(named: "ManagedSwiftFixtures.GenericPhantom.read() -> Swift.Int64", as: (() -> Int64).self)
            Issue.record("A qualified member must belong to the receiver's declaring type")
        } catch ABIResolutionError.declarationNotFound {}
    }
    @MainActor @Test func genericMembersUseDeclarationOwnershipDefaults() async throws {
        let type = try await ABIRuntime().swiftType(named: "ManagedSwiftFixtures.GenericValueBox",
            genericArguments: [.type(String.self)])
        let create = try await type.initializer(named: "init(_:)",
            as: ((NativeSwiftConsuming<String>) -> GenericValueBox<String>).self)
        let replace = try await type.method(named: "replace(_:)",
            as: ((NativeSwiftBorrowing<String>) -> Void).self, mutating: true)
        let setter = try await type.setter(named: "value", as: NativeSwiftConsuming<String>.self)
        var value = try unsafe create.unsafeInvoke(.init("created"))
        #expect(value.value == "created")
        try unsafe replace.unsafeInvoke(on: &value, .init("replaced"))
        #expect(value.value == "replaced")
        try unsafe setter.unsafeInvoke(on: &value, .init("set"))
        #expect(value.value == "set")
    }

    @MainActor @Test func nominalConstraintsAndNestedFieldsPreserveReceiverLayouts() async throws {
        let runtime = ABIRuntime()
        let object = NSObject()
        let objectType = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericObjectValue",
            genericArguments: [.type(NSObject.self)])
        let objectProject = try await objectType.method(named: "project()", as: (() -> NSObject).self)
        #expect(try unsafe objectProject.unsafeInvoke(on: GenericObjectValue(object)) === object)
        let superclassType = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericSuperclassValue",
            genericArguments: [.type(NSObject.self)])
        let superclassProject = try await superclassType.method(named: "project()", as: (() -> NSObject).self)
        #expect(try unsafe superclassProject.unsafeInvoke(on: GenericSuperclassValue(object)) === object)
        let text = String(repeating: "nested field", count: 100)
        let nested = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericNestedValue",
            genericArguments: [.type(String.self)])
        let project = try await nested.method(named: "project()", as: (() -> String).self)
        #expect(try unsafe project.unsafeInvoke(on: GenericNestedValue(text)) == text)
        let sameType = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericSameTypeValue",
            genericArguments: [.type([ManagedRecord].self)])
        let number = try await sameType.method(named: "number()", as: (() -> Int64).self)
        #expect(try unsafe number.unsafeInvoke(on: GenericSameTypeValue([ManagedRecord(token: LifetimeToken(), number: 79)])) == 79)
    }

    @MainActor @Test func sameTypeNominalExpressionsDetermineMetadataAndReceiverConvention() async throws {
        let type = try await ABIRuntime().swiftType(named: "ManagedSwiftFixtures.GenericValueBox",
            genericArguments: [.type([String].self)])
        let first = try await type.method(named: "first()", as: (() -> String).self,
            genericArguments: [.type(String.self)])
        let text = String(repeating: "array constraint", count: 100)
        #expect(try unsafe first.unsafeInvoke(on: GenericValueBox([text])) == text)
    }

    @MainActor @Test func valuesAndEnumsUseUnboundFieldStorageWithoutAdapters() async throws {
        let runtime = ABIRuntime()
        let record = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericRecord",
            genericArguments: [.type(ResilientRecord.self)])
        let project = try await record.method(named: "project()", as: (() -> ResilientRecord).self)
        let measure = try await record.method(named: "measure()", as: (() -> Int64).self)
        let input = GenericRecord(ResilientRecord(token: LifetimeToken(), number: 42))
        #expect(try unsafe project.unsafeInvoke(on: input).number == 42)
        #expect(try unsafe measure.unsafeInvoke(on: input) == 42)
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericTypeEnum",
            genericArguments: [.type(String.self)])
        let payload = try await type.method(named: "payload()", as: (() -> String).self)
        let text = String(repeating: "enum", count: 100)
        #expect(try unsafe payload.unsafeInvoke(on: GenericTypeEnum.value(text)) == text)
    }

    @MainActor @Test func valueMembersShareInitializationMutationAndOwnership() async throws {
        let type = try await ABIRuntime().swiftType(named: "ManagedSwiftFixtures.GenericValueBox",
            genericArguments: [.type(String.self)])
        let create = try await type.initializer(named: "init(_:)", as: ((String) -> GenericValueBox<String>).self)
        let project = try await type.method(named: "project()", as: (() -> String).self)
        let get = try await type.getter(named: "value", as: (() -> String).self)
        let set = try await type.setter(named: "value", as: String.self)
        let replace = try await type.method(named: "replace(_:)", as: ((String) -> Void).self, mutating: true)
        let take = try await type.method(named: "take()", as: (() -> String).self, consuming: true)
        let pair = try await type.method(named: "paired(_:)", as: ((Int64) -> (String, Int64, Bool)).self,
            genericArguments: [.type(Int64.self)])
        let identity = try await type.staticMethod(named: "identity(_:)", as: ((String) -> String).self)
        let original = String(repeating: "original", count: 100)
        var value = try unsafe create.unsafeInvoke(original)
        #expect(try unsafe project.unsafeInvoke(on: value) == original)
        #expect(try unsafe identity.unsafeInvoke(original) == original)
        let result = try unsafe pair.unsafeInvoke(on: value, Int64(73))
        #expect(result.0 == original && result.1 == 73 && result.2)
        try unsafe set.unsafeInvoke(on: &value, "set")
        #expect(value.value == "set")
        try unsafe replace.unsafeInvoke(on: &value, original)
        #expect(try unsafe get.unsafeInvoke(on: value) == original)
        #expect(try unsafe take.unsafeInvoke(on: value) == original)
        #expect(value.value == original)
    }

    @MainActor @Test func constrainedMembersUseTheirOwnReceiverConvention() async throws {
        let runtime = ABIRuntime()
        let integer = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericValueBox",
            genericArguments: [.type(Int.self)])
        let generic = try await integer.method(named: "project()", as: (() -> Int).self)
        let concrete = try await integer.method(named: "concrete()", as: (() -> Int).self)
        let value = GenericValueBox(42)
        #expect(try unsafe generic.unsafeInvoke(on: value) == 42)
        #expect(try unsafe concrete.unsafeInvoke(on: value) == 42)
        let object = NSObject()
        let reference = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericValueBox",
            genericArguments: [.type(NSObject.self)])
        let unbound = try await reference.method(named: "project()", as: (() -> NSObject).self)
        let bound = try await reference.method(named: "reference()", as: (() -> NSObject).self)
        let boxed = GenericValueBox(object)
        #expect(try unsafe unbound.unsafeInvoke(on: boxed) === object)
        #expect(try unsafe bound.unsafeInvoke(on: boxed) === object)
    }

    @MainActor @Test func fixedStorageRetainsExplicitMetadataAndDirectReceiver() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericPhantom",
            genericArguments: [.type(String.self)])
        let read = try await type.method(named: "read()", as: (() -> Int64).self)
        let paired = try await type.method(named: "paired(_:)", as: ((String) -> (Int64, String)).self,
            genericArguments: [.type(String.self)])
        let value = GenericPhantom<String>(81)
        #expect(try unsafe read.unsafeInvoke(on: value) == 81)
        let result = try unsafe paired.unsafeInvoke(on: value, "member")
        #expect(result.0 == 81 && result.1 == "member")
        let function = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.phantomGeneric<A>(ManagedSwiftFixtures.GenericPhantom<A>) -> ManagedSwiftFixtures.GenericPhantom<A>",
            as: ((GenericPhantom<String>) -> GenericPhantom<String>).self, genericArguments: [.type(String.self)])
        #expect(try unsafe function.unsafeInvoke(value).number == 81)
    }

    @MainActor @Test func indirectValueReceiversComposeWithAsyncAndTypedErrors() async throws {
        let type = try await ABIRuntime().swiftType(named: "ManagedSwiftFixtures.GenericValueBox",
            genericArguments: [.type(String.self)])
        let asynchronous = try await type.method(named: "asynchronously()", as: (() async -> String).self)
        let throwing = try await type.method(named: "checked(_:fail:)",
            as: ((ScalarFailure, Bool) throws(ScalarFailure) -> String).self,
            genericArguments: [.type(ScalarFailure.self)])
        let value = GenericValueBox(String(repeating: "effects", count: 100))
        #expect(try unsafe await asynchronous.unsafeInvoke(on: value) == value.value)
        #expect(try unsafe throwing.unsafeInvoke(on: value, ScalarFailure(17), false) == value.value)
        do {
            _ = try unsafe throwing.unsafeInvoke(on: value, ScalarFailure(17), true)
            Issue.record("Expected the native typed error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? ScalarFailure)?.code } == 17)
        }
    }

    @Test func nominalArgumentsAndOptionalArraysUseFormalLayouts() async throws {
        let runtime = ABIRuntime()
        let function = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.boxedGeneric<A>(ManagedSwiftFixtures.GenericValueBox<A>) -> ManagedSwiftFixtures.GenericValueBox<A>",
            as: ((GenericValueBox<Int>) -> GenericValueBox<Int>).self, genericArguments: [.type(Int.self)])
        #expect(try unsafe function.unsafeInvoke(GenericValueBox(31)).value == 31)
        let array = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.optionalArrayGeneric<A>(Swift.Optional<Swift.Array<A>>) -> Swift.Optional<Swift.Array<A>>",
            as: (([Int]?) -> [Int]?).self, genericArguments: [.type(Int.self)])
        #expect(try unsafe array.unsafeInvoke([1, 2, 3]) == [1, 2, 3])
        #expect(try unsafe array.unsafeInvoke(nil) == nil)
    }
}
