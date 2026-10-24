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
    @MainActor @Test func subscriptAccessorsPreserveIndicesAndOwnership() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeGenericIdentifiedLookup(_:)",
                    as: ((String) -> NativeSwiftValue).self
                )
            )
        )
        let makeKey = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeGenericLookupKey(_:)",
                    as: ((String) -> NativeSwiftValue).self
                )
            )
        )
        let makeReplacement = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeGenericLookupReplacement(_:_:)",
                    as: ((String, Int64) -> NativeSwiftValue).self
                )
            )
        )
        let keyText = String(repeating: "lookup key ", count: 8)
        var direct = GenericIdentifiedLookup([GenericIdentifiedRecord(id: keyText, value: 41)])
        let source = try unsafe make.unsafeInvoke(keyText)
        let key = try unsafe makeKey.unsafeInvoke(keyText)
        let replacement = try unsafe makeReplacement.unsafeInvoke(keyText, 42)
        let abis = [
            key.type: try NativeType.opaque(named: key.type.name),
            replacement.type: try NativeType.opaque(named: replacement.type.name),
        ]
        let getter = try await source.type.resolve(
            .swift(
                .getter(
                    "ManagedSwiftFixtures.GenericIdentifiedLookup.subscript.getter : (A.ID) -> A?",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    valueABIs: abis,
                    receiverABI: .opaque(named: source.type.name)
                )
            )
        )
        let original = try unsafe getter.unsafeInvoke(on: source, key)
        #expect(
            try original.take(as: GenericIdentifiedRecord?.self)?.value == direct[keyText]?.value
        )
        #expect(!key.isConsumed && !source.isConsumed)
        let missingKey = try unsafe makeKey.unsafeInvoke("missing")
        let missing = try unsafe getter.unsafeInvoke(on: source, missingKey)
        #expect(try missing.take(as: GenericIdentifiedRecord?.self) == nil)

        let setter = try await source.type.resolve(
            .swift(
                .setter(
                    "ManagedSwiftFixtures.GenericIdentifiedLookup.subscript.setter : (A.ID) -> A?",
                    as: ((NativeSwiftValue, NativeSwiftValue) -> Void).self,
                    valueABIs: abis,
                    receiverABI: .opaque(named: source.type.name),
                    receiver: .mutating
                )
            )
        )
        let setterKey = try key.copy()
        try unsafe setter.unsafeInvoke(on: source, replacement, setterKey)
        direct[keyText] = GenericIdentifiedRecord(id: keyText, value: 42)
        #expect(replacement.isConsumed && setterKey.isConsumed)
        #expect(!key.isConsumed && !source.isConsumed)
        let updated = try unsafe getter.unsafeInvoke(on: source, key)
        #expect(
            try updated.take(as: GenericIdentifiedRecord?.self)?.value == direct[keyText]?.value
        )

        let typedSetter = try await source.type.resolve(
            .swift(
                .setter(
                    "ManagedSwiftFixtures.GenericIdentifiedLookup.subscript.setter : (A.ID) -> A?",
                    as: ((GenericIdentifiedRecord?, String) -> Void).self,
                    valueABIs: abis,
                    receiverABI: .opaque(named: source.type.name),
                    receiver: .mutating
                )
            )
        )
        let typedValue = GenericIdentifiedRecord(id: keyText, value: 43)
        try unsafe typedSetter.unsafeInvoke(on: source, Optional(typedValue), keyText)
        direct[keyText] = typedValue
        let typedUpdate = try unsafe getter.unsafeInvoke(on: source, key)
        #expect(
            try typedUpdate.take(as: GenericIdentifiedRecord?.self)?.value == direct[keyText]?.value
        )
        #expect(typedValue.id == keyText)

        typealias Formatter = NativeSwiftClosure<(String) -> String>
        let setFormatter = try await source.type.resolve(
            .swift(
                .setter(
                    "formatter",
                    as: ((Formatter) -> Void).self,
                    receiverABI: .opaque(named: source.type.name)
                )
            )
        )
        let prefix = String(repeating: "formatted ", count: 4)
        try unsafe setFormatter.unsafeInvoke(on: source, Formatter { prefix + $0 })
        let getFormatter = try await source.type.resolve(
            .swift(
                .getter(
                    "formatter",
                    as: (() -> Formatter).self,
                    receiverABI: .opaque(named: source.type.name)
                )
            )
        )
        let formatter = try unsafe getFormatter.unsafeInvoke(on: source)
        #expect(try unsafe formatter.unsafeInvoke(keyText) == prefix + keyText)
    }

    @MainActor @Test func valueReceiversFulfillNestedGenericRequirements() async throws {
        let receiver = GenericValueBox(GenericSourceBox(GenericSourceValue(39)))
        let type = try await ABIRuntime.shared.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericValueBox",
                    genericArguments: [.type(GenericSourceBox<GenericSourceValue>.self)]
                )
            )
        )
        let total = try await type.resolve(
            .swift(
                .method(
                    "sourceTotal(_:)",
                    as: (([Int64]) throws -> Int64).self,
                    genericArguments: [.type(GenericSourceValue.self), .type([Int64].self)]
                )
            )
        )
        let values: [Int64] = [1, 2]
        #expect(try unsafe total.unsafeInvoke(on: receiver, values) == receiver.sourceTotal(values))
    }

    @MainActor @Test func objectConstraintsAcceptObjectiveCExistentialSpecializations() async throws {
        let runtime = ABIRuntime.shared
        let object: AnyObject = NSObject()
        let free = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.objectConstraintGeneric<A where A: AnyObject>(A) -> A",
                    as: ((AnyObject) -> AnyObject).self,
                    genericArguments: [.type(AnyObject.self)]
                )
            )
        )
        #expect(try unsafe free.unsafeInvoke(object) === object)
        let anyType = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericObjectValue",
                    genericArguments: [.type(AnyObject.self)]
                )
            )
        )
        let make = try await anyType.resolve(
            .swift(
                .initializer(
                    "init(_:)",
                    as: ((AnyObject) -> GenericObjectValue<AnyObject>).self
                )
            )
        )
        let value = try unsafe make.unsafeInvoke(object)
        let project = try await anyType.resolve(
            .swift(.method("project()", as: (() -> AnyObject).self))
        )
        #expect(try unsafe project.unsafeInvoke(on: value) === object)

        let objc: any NSObjectProtocol = NSObject()
        let objcType = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericObjectValue",
                    genericArguments: [.type((any NSObjectProtocol).self)]
                )
            )
        )
        let objcProject = try await objcType.resolve(
            .swift(
                .method(
                    "project()",
                    as: (() -> any NSObjectProtocol).self
                )
            )
        )
        #expect(try unsafe objcProject.unsafeInvoke(on: GenericObjectValue<any NSObjectProtocol>(objc)) === objc)

        let constrained: any NSCopying & NSObject = NSString(string: "class existential")
        let superType = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericSuperclassValue",
                    genericArguments: [.type((any NSCopying & NSObject).self)]
                )
            )
        )
        let superProject = try await superType.resolve(
            .swift(
                .method(
                    "project()",
                    as: (() -> any NSCopying & NSObject).self
                )
            )
        )
        #expect(try unsafe superProject.unsafeInvoke(on: GenericSuperclassValue<any NSCopying & NSObject>(constrained)) === constrained)

        let protocolValue: any GenericObjCConstraint = GenericObjCValue()
        let protocolCall = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.objcConstraintGeneric<A where A: ManagedSwiftFixtures.GenericObjCConstraint>(A) -> A",
                    as: ((any GenericObjCConstraint) -> any GenericObjCConstraint).self,
                    genericArguments: [.type((any GenericObjCConstraint).self)]
                )
            )
        )
        #expect(try unsafe protocolCall.unsafeInvoke(protocolValue) === protocolValue)
        let pair = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.objcSuperclassPairGeneric<A where A: __C.NSObject>(A, __C.NSObject) -> A",
                    as: ((NSObject, any NSObjectProtocol) -> NSObject).self,
                    genericArguments: [.type(NSObject.self)]
                )
            )
        )
        let instance = NSObject()
        #expect(try unsafe pair.unsafeInvoke(instance, objc) === instance)
    }

    @Test func memberWitnessesUseTheCanonicalRefinedSignature() async throws {
        let runtime = ABIRuntime.shared
        let associatedType = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericAssociatedOwner",
                    genericArguments: [.type(GenericAssociatedValue.self)]
                )
            )
        )
        let associated = try await associatedType.resolve(
            .swift(
                .staticMethod(
                    "associatedWitness(_:_:_:)",
                    as: ((String, GenericGetterFailure, Bool) throws(GenericGetterFailure) -> Int)
                        .self,
                    genericArguments: [.type(GenericGetterFailure.self)]
                )
            )
        )
        #expect(try unsafe associated.unsafeInvoke("associated", GenericGetterFailure(42), false) == "associated".hashValue)
        do {
            _ = try unsafe associated.unsafeInvoke("associated", GenericGetterFailure(42), true)
            Issue.record("Expected the member's typed error.")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? GenericGetterFailure)?.code == 42 })
        }
        let aliasedType = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericAssociatedAliasOwner",
                    genericArguments: [.type(GenericAssociatedValue.self), .type(String.self)]
                )
            )
        )
        let aliased = try await aliasedType.resolve(
            .swift(
                .staticMethod(
                    "aliasedWitness(_:_:_:)",
                    as: ((String, GenericGetterFailure, Bool) throws(GenericGetterFailure) -> Int)
                        .self,
                    genericArguments: [.type(GenericGetterFailure.self)]
                )
            )
        )
        #expect(try unsafe aliased.unsafeInvoke("aliased", GenericGetterFailure(43), false) == "aliased".hashValue)
        do {
            _ = try unsafe aliased.unsafeInvoke("aliased", GenericGetterFailure(43), true)
            Issue.record("Expected the aliased member's typed error.")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? GenericGetterFailure)?.code == 43 })
        }
        let refined = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericHashOwner",
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let hash = try await refined.resolve(
            .swift(.staticMethod("refinedWitness(_:)", as: ((String) -> Int).self))
        )
        #expect(
            try unsafe hash.unsafeInvoke("hash") == GenericHashOwner<String>.refinedWitness("hash")
        )
        let concrete = try await runtime.resolve(
            .swift(
                .type("ManagedSwiftFixtures.GenericHashOwner", genericArguments: [.type(Int.self)])
            )
        )
        let additional = try await concrete.resolve(
            .swift(
                .staticMethod(
                    "concreteWitness(_:)",
                    as: ((String) -> Int).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        #expect(
            try unsafe additional.unsafeInvoke("concrete")
                == GenericHashOwner<Int>.concreteWitness("concrete")
        )
        let ordered = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericWitnessOwner",
                    genericArguments: [.type(GenericWitnessValue.self)]
                )
            )
        )
        let both = try await ordered.resolve(
            .swift(.staticMethod("orderedWitnesses()", as: (() -> Int64).self))
        )
        #expect(try unsafe both.unsafeInvoke() == GenericWitnessOwner<GenericWitnessValue>.orderedWitnesses())
    }

    @MainActor @Test func qualifiedMembersSelectTheRequestedConstraint() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolve(
            .swift(
                .type("ManagedSwiftFixtures.GenericValueBox", genericArguments: [.type(Int.self)])
            )
        )
        let receiver = GenericValueBox(42)
        for (constraint, result) in [("Swift.Equatable", Int64(10)), ("Swift.Hashable", Int64(20))] {
            let prefix = constraint == "Swift.Equatable" ? "" : "(extension in ManagedSwiftFixtures):"
            let owner = prefix + "ManagedSwiftFixtures.GenericValueBox<A where A: " + constraint + ">"
            let method = try await type.resolve(
                .swift(
                    .method(
                        owner + ".selected() -> Swift.Int64",
                        as: (() -> Int64).self
                    )
                )
            )
            let getter = try await type.resolve(
                .swift(
                    .getter(
                        owner + ".selectedValue.getter : Swift.Int64",
                        as: (() -> Int64).self
                    )
                )
            )
            let staticMethod = try await type.resolve(
                .swift(
                    .staticMethod(
                        "static " + owner + ".selectedStatic() -> Swift.Int64",
                        as: (() -> Int64).self
                    )
                )
            )
            let staticGetter = try await type.resolve(
                .swift(
                    .staticGetter(
                        "static " + owner + ".selectedStaticValue.getter : Swift.Int64",
                        as: (() -> Int64).self
                    )
                )
            )
            #expect(try unsafe method.unsafeInvoke(on: receiver) == result + 1)
            #expect(try unsafe getter.unsafeInvoke(on: receiver) == result + 2)
            #expect(try unsafe staticMethod.unsafeInvoke() == result + 3)
            #expect(try unsafe staticGetter.unsafeInvoke() == result + 4)
        }
        do {
            _ = try await type.resolve(.swift(.method("selected()", as: (() -> Int64).self)))
            Issue.record("Expected the short member name to remain ambiguous")
        } catch ABIResolutionError.ambiguousDeclaration {}
        do {
            _ = try await type.resolve(
                .swift(
                    .method(
                        "ManagedSwiftFixtures.GenericValueBox<A where A: Swift.Equatable>.selectedValue.getter : Swift.Int64",
                        as: (() -> Int64).self
                    )
                )
            )
            Issue.record("A method request must not resolve the getter its name spells")
        } catch ABIResolutionError.unsupportedDeclaration {}
        do {
            _ = try await type.resolve(
                .swift(
                    .method(
                        "(extension in ManagedSwiftFixtures):ManagedSwiftFixtures.GenericValueBox<A where A: Swift.Comparable>.selected() -> Swift.Int64",
                        as: (() -> Int64).self
                    )
                )
            )
            Issue.record("An unavailable qualified declaration must not select another constraint")
        } catch ABIResolutionError.declarationNotFound {}
        do {
            _ = try await type.resolve(
                .swift(
                    .method(
                        "ManagedSwiftFixtures.GenericPhantom.read() -> Swift.Int64",
                        as: (() -> Int64).self
                    )
                )
            )
            Issue.record("A qualified member must belong to the receiver's declaring type")
        } catch ABIResolutionError.declarationNotFound {}
    }
    @MainActor @Test func genericMembersUseDeclarationOwnershipDefaults() async throws {
        let type = try await ABIRuntime.shared.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericValueBox",
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let create = try await type.resolve(
            .swift(
                .initializer(
                    "init(_:)",
                    as: ((NativeSwiftConsuming<String>) -> GenericValueBox<String>).self
                )
            )
        )
        let replace = try await type.resolve(
            .swift(
                .method(
                    "replace(_:)",
                    as: ((NativeSwiftBorrowing<String>) -> Void).self,
                    receiver: .mutating
                )
            )
        )
        let setter = try await type.resolve(
            .swift(.setter("value", as: ((NativeSwiftConsuming<String>) -> Void).self))
        )
        var value = try unsafe create.unsafeInvoke(.init("created"))
        #expect(value.value == "created")
        try unsafe replace.unsafeInvoke(on: &value, .init("replaced"))
        #expect(value.value == "replaced")
        try unsafe setter.unsafeInvoke(on: &value, .init("set"))
        #expect(value.value == "set")
    }

    @MainActor @Test func nominalConstraintsAndNestedFieldsPreserveReceiverLayouts() async throws {
        let runtime = ABIRuntime.shared
        let object = NSObject()
        let objectType = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericObjectValue",
                    genericArguments: [.type(NSObject.self)]
                )
            )
        )
        let objectProject = try await objectType.resolve(
            .swift(.method("project()", as: (() -> NSObject).self))
        )
        #expect(try unsafe objectProject.unsafeInvoke(on: GenericObjectValue(object)) === object)
        let superclassType = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericSuperclassValue",
                    genericArguments: [.type(NSObject.self)]
                )
            )
        )
        let superclassProject = try await superclassType.resolve(
            .swift(
                .method(
                    "project()",
                    as: (() -> NSObject).self
                )
            )
        )
        #expect(try unsafe superclassProject.unsafeInvoke(on: GenericSuperclassValue(object)) === object)
        let text = String(repeating: "nested field", count: 100)
        let nested = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericNestedValue",
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let project = try await nested.resolve(
            .swift(.method("project()", as: (() -> String).self))
        )
        #expect(try unsafe project.unsafeInvoke(on: GenericNestedValue(text)) == text)
        let sameType = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericSameTypeValue",
                    genericArguments: [.type([ManagedRecord].self)]
                )
            )
        )
        let number = try await sameType.resolve(.swift(.method("number()", as: (() -> Int64).self)))
        #expect(try unsafe number.unsafeInvoke(on: GenericSameTypeValue([ManagedRecord(token: LifetimeToken(), number: 79)])) == 79)
    }

    @MainActor @Test func sameTypeNominalExpressionsDetermineMetadataAndReceiverConvention()
        async throws
    {
        let type = try await ABIRuntime.shared.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericValueBox",
                    genericArguments: [.type([String].self)]
                )
            )
        )
        let first = try await type.resolve(
            .swift(
                .method(
                    "first()",
                    as: (() -> String).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let text = String(repeating: "array constraint", count: 100)
        #expect(try unsafe first.unsafeInvoke(on: GenericValueBox([text])) == text)
    }

    @MainActor @Test func valuesAndEnumsUseUnboundFieldStorageWithoutAdapters() async throws {
        let runtime = ABIRuntime.shared
        let record = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericRecord",
                    genericArguments: [.type(ResilientRecord.self)]
                )
            )
        )
        let project = try await record.resolve(
            .swift(.method("project()", as: (() -> ResilientRecord).self))
        )
        let measure = try await record.resolve(.swift(.method("measure()", as: (() -> Int64).self)))
        let input = GenericRecord(ResilientRecord(token: LifetimeToken(), number: 42))
        #expect(try unsafe project.unsafeInvoke(on: input).number == 42)
        #expect(try unsafe measure.unsafeInvoke(on: input) == 42)
        let type = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericTypeEnum",
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let payload = try await type.resolve(.swift(.method("payload()", as: (() -> String).self)))
        let text = String(repeating: "enum", count: 100)
        #expect(try unsafe payload.unsafeInvoke(on: GenericTypeEnum.value(text)) == text)
    }

    @MainActor @Test func valueMembersShareInitializationMutationAndOwnership() async throws {
        let type = try await ABIRuntime.shared.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericValueBox",
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let create = try await type.resolve(
            .swift(
                .initializer(
                    "init(_:)",
                    as: ((String) -> GenericValueBox<String>).self
                )
            )
        )
        let project = try await type.resolve(.swift(.method("project()", as: (() -> String).self)))
        let get = try await type.resolve(.swift(.getter("value", as: (() -> String).self)))
        let set = try await type.resolve(.swift(.setter("value", as: ((String) -> Void).self)))
        let replace = try await type.resolve(
            .swift(
                .method(
                    "replace(_:)",
                    as: ((String) -> Void).self,
                    receiver: .mutating
                )
            )
        )
        let take = try await type.resolve(
            .swift(.method("take()", as: (() -> String).self, receiver: .consuming))
        )
        let pair = try await type.resolve(
            .swift(
                .method(
                    "paired(_:)",
                    as: ((Int64) -> (String, Int64, Bool)).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let identity = try await type.resolve(
            .swift(.staticMethod("identity(_:)", as: ((String) -> String).self))
        )
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
        let runtime = ABIRuntime.shared
        let integer = try await runtime.resolve(
            .swift(
                .type("ManagedSwiftFixtures.GenericValueBox", genericArguments: [.type(Int.self)])
            )
        )
        let generic = try await integer.resolve(.swift(.method("project()", as: (() -> Int).self)))
        let concrete = try await integer.resolve(
            .swift(.method("concrete()", as: (() -> Int).self))
        )
        let value = GenericValueBox(42)
        #expect(try unsafe generic.unsafeInvoke(on: value) == 42)
        #expect(try unsafe concrete.unsafeInvoke(on: value) == 42)
        let object = NSObject()
        let reference = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericValueBox",
                    genericArguments: [.type(NSObject.self)]
                )
            )
        )
        let unbound = try await reference.resolve(
            .swift(.method("project()", as: (() -> NSObject).self))
        )
        let bound = try await reference.resolve(
            .swift(.method("reference()", as: (() -> NSObject).self))
        )
        let boxed = GenericValueBox(object)
        #expect(try unsafe unbound.unsafeInvoke(on: boxed) === object)
        #expect(try unsafe bound.unsafeInvoke(on: boxed) === object)
    }

    @MainActor @Test func fixedStorageRetainsExplicitMetadataAndDirectReceiver() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolve(
            .swift(
                .type("ManagedSwiftFixtures.GenericPhantom", genericArguments: [.type(String.self)])
            )
        )
        let read = try await type.resolve(.swift(.method("read()", as: (() -> Int64).self)))
        let paired = try await type.resolve(
            .swift(
                .method(
                    "paired(_:)",
                    as: ((String) -> (Int64, String)).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let value = GenericPhantom<String>(81)
        #expect(try unsafe read.unsafeInvoke(on: value) == 81)
        let result = try unsafe paired.unsafeInvoke(on: value, "member")
        #expect(result.0 == 81 && result.1 == "member")
        let function = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.phantomGeneric<A>(ManagedSwiftFixtures.GenericPhantom<A>) -> ManagedSwiftFixtures.GenericPhantom<A>",
                    as: ((GenericPhantom<String>) -> GenericPhantom<String>).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        #expect(try unsafe function.unsafeInvoke(value).number == 81)
    }

    @MainActor @Test func indirectValueReceiversComposeWithAsyncAndTypedErrors() async throws {
        let type = try await ABIRuntime.shared.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericValueBox",
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let asynchronous = try await type.resolve(
            .swift(.method("asynchronously()", as: (() async -> String).self))
        )
        let throwing = try await type.resolve(
            .swift(
                .method(
                    "checked(_:fail:)",
                    as: ((ScalarFailure, Bool) throws(ScalarFailure) -> String).self,
                    genericArguments: [.type(ScalarFailure.self)]
                )
            )
        )
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
        let runtime = ABIRuntime.shared
        let function = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.boxedGeneric<A>(ManagedSwiftFixtures.GenericValueBox<A>) -> ManagedSwiftFixtures.GenericValueBox<A>",
                    as: ((GenericValueBox<Int>) -> GenericValueBox<Int>).self,
                    genericArguments: [.type(Int.self)]
                )
            )
        )
        #expect(try unsafe function.unsafeInvoke(GenericValueBox(31)).value == 31)
        let array = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.optionalArrayGeneric<A>(Swift.Optional<Swift.Array<A>>) -> Swift.Optional<Swift.Array<A>>",
                    as: (([Int]?) -> [Int]?).self,
                    genericArguments: [.type(Int.self)]
                )
            )
        )
        #expect(try unsafe array.unsafeInvoke([1, 2, 3]) == [1, 2, 3])
        #expect(try unsafe array.unsafeInvoke(nil) == nil)
    }
}
