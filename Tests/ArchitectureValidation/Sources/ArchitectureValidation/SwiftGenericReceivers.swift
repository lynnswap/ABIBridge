import ABIBridge
import Foundation
import Synchronization
import SwiftValueFixtures
import SwiftOpaqueExtensions

private struct BindingConstraintValue: BindingNotAnyObject, ABIBridgeSwiftValue, Equatable {
    let text: String
    static var swiftABIType: NativeType { try! .opaque(named: "BindingConstraintValue") }
}

private struct BindingBoolAdapter: ABIBridgeValue {
    let value: Bool
    init(_ value: Bool) { self.value = value }
    static let abiType: NativeType = .bool
    init(nativeValue: NativeValue) throws { value = try unsafe nativeValue.read(as: Bool.self) }
    static func nativeValue(from value: Self) throws -> NativeValue { try NativeValue(copying: value.value, as: .bool) }
}

@MainActor func validateSwiftGenericReceivers() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    weak var observed: GenericMemberReceiver<GenericReceiverText>?
    var retained: NativeBoundSwiftMethod<(String) -> String>?
    do {
        let receiver = GenericMemberReceiver(GenericReceiverText(String(repeating: "owned", count: 100)))
        observed = receiver
        let object = runtime.object(receiver)
        retained = try await object.method(named: "concrete(_:)", as: ((String) -> String).self)
        let complete = try await object.method(named: "concrete(Swift.String) -> Swift.String", as: ((String) -> String).self)
        let getter = try await object.getter(named: "valueText", as: (() -> String).self)
        try check(unsafe retained!.unsafeInvoke("prefix:") == receiver.concrete("prefix:"),
                  "Generic Swift receiver uses its metadata and witness context")
        try check(unsafe complete.unsafeInvoke("") == receiver.concrete(""),
                  "Generic Swift complete concrete declaration")
        try check(unsafe getter.unsafeInvoke() == receiver.valueText, "Generic Swift concrete getter")
    }
    let inherited = InheritedGenericMemberReceiver(GenericReceiverNumber(42))
    let method = try await runtime.object(inherited).method(named: "concrete(_:)", as: ((String) -> String).self)
    try check(unsafe method.unsafeInvoke("") == inherited.concrete(""),
              "Generic Swift superclass implementation")
    let constrained = try await runtime.object(inherited).method(named: "specialized(_:)", as: ((String) -> String).self)
    let constrainedGetter = try await runtime.object(inherited).getter(named: "specializedText", as: (() -> String).self)
    try check(unsafe constrained.unsafeInvoke("prefix:") == inherited.specialized("prefix:"),
              "Swift same-type constrained superclass member")
    try check(unsafe constrainedGetter.unsafeInvoke() == inherited.specializedText,
              "Swift same-type constrained getter")
    let witness = try await runtime.object(inherited).method(named: "witnessText()", as: (() -> String).self)
    try check(unsafe witness.unsafeInvoke() == inherited.witnessText(),
              "Constrained superclass member receives its additional protocol witness")
    await runtime.removeCachedResults()
    try check(observed != nil, "Generic Swift receiver retained after cache removal")
    try check(unsafe retained!.unsafeInvoke("") == String(repeating: "owned", count: 100),
              "Generic Swift specialized metadata stays distinct")
    retained = nil
    try check(observed == nil, "Generic Swift receiver final release")
    return checks
}

@MainActor func validateSwiftGenericBindings() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    for (name, importsConformance) in [
        ("SwiftValueFixtures.BindingDeclaredUnknown", false), ("SwiftOpaqueExtensions.BindingDeclaredKnown", true)
    ] {
        let owner = try await runtime.swiftType(named: name, genericArguments: [.type(BindingDeclaredBase.self)])
        let witness = importsConformance ? "" : ", A: SwiftValueFixtures.BindingDeclaredScore"
        let entry = try await owner.staticMethod(named: "entry(_:_:)", as: ((SmallError, Bool) throws(SmallError) -> Int64).self,
            genericArguments: [.type(SmallError.self)],
            declaredAs: "<A, A1 where A: SwiftValueFixtures.BindingDeclaredBase" + witness
                + ", A1: Swift.Error> (A1, Swift.Bool) throws(A1) -> Swift.Int64")
        try check(unsafe entry.unsafeInvoke(SmallError(45), false) == 42,
            "Declared generic witnesses preserve provider import visibility: \(importsConformance)")
        do {
            _ = try unsafe entry.unsafeInvoke(SmallError(45), true)
            throw ArchitectureValidationFailure(description: "Expected the declared generic typed error")
        } catch let error as NativeSwiftError {
            try check(error.withUnderlyingError { ($0 as? SmallError)?.code == 45 },
                "Declared generic witnesses preserve typed-error output: \(importsConformance)")
        }
    }
    let candidates = runtime.object(BindingCandidateBox<Bool>())
    let namedTuple = try await runtime.object(BindingCandidateBox<(first: Int64, second: String)>()).method(
        named: "tupleIdentity()", as: (() -> Int64).self)
    try check(unsafe namedTuple.unsafeInvoke() == 42, "Tuple labels remain part of same-type requirements")
    do {
        _ = try await runtime.object(BindingCandidateBox<(different: Int64, labels: String)>()).method(
            named: "tupleIdentity()", as: (() -> Int64).self)
        throw ArchitectureValidationFailure(description: "Different tuple labels matched a same-type requirement")
    } catch ABIResolutionError.declarationNotFound {
        try check(true, "Different tuple labels do not satisfy a same-type requirement")
    }
    let concreteClass = try await runtime.object(BindingCandidateBox<NSObject>()).method(
        named: "classIdentity()", as: (() -> Int64).self)
    try check(unsafe concreteClass.unsafeInvoke() == 42, "Concrete Objective-C classes satisfy their same-type requirements")
    do {
        _ = try await runtime.object(BindingCandidateBox<any NSObjectProtocol>()).method(
            named: "classIdentity()", as: (() -> Int64).self)
        throw ArchitectureValidationFailure(description: "An Objective-C protocol matched its same-named class")
    } catch ABIResolutionError.declarationNotFound {
        try check(true, "Objective-C protocol existentials do not satisfy same-named class identities")
    }
    let applicable = try await candidates.method(named: "constraintChoice()", as: (() -> Int64).self)
    try check(unsafe applicable.unsafeInvoke() == 42,
        "An inapplicable associated-type requirement does not hide another overload")
    let inherited = try await candidates.method(named: "inheritedChoice()", as: (() -> Int64).self)
    try check(unsafe inherited.unsafeInvoke() == 42,
        "An inapplicable associated-type requirement does not hide a superclass member")
    let callbacks = runtime.object(BindingCallbackConventions<Int64>())
    let selectedCallback = try await callbacks.method(named: "callback(_:)", as: ((NativeSwiftClosure<(Int64) -> Int64>) -> Int64).self)
    try check(unsafe selectedCallback.unsafeInvoke(NativeSwiftClosure<(Int64) -> Int64> { $0 + 2 }) == 42,
        "Swift callback arguments select their own convention beside C and block overloads")
    let returnedCallback = try await callbacks.method(named: "returnedCallback()", as: (() -> NativeSwiftClosure<(Int64) -> Int64>).self)
    let returnedBody = try unsafe returnedCallback.unsafeInvoke()
    try check(unsafe returnedBody.unsafeInvoke(40) == 42,
        "Swift callback results select their own convention beside C and block overloads")
    for name in ["foreignC(_:)", "foreignBlock(_:)"] {
        do {
            _ = try await callbacks.method(named: name, as: ((NativeSwiftClosure<(Int64) -> Int64>) -> Int64).self)
            throw ArchitectureValidationFailure(description: "A Swift closure matched a foreign convention")
        } catch ABIResolutionError.declarationNotFound {
            try check(true, "Swift closures do not match foreign callback declarations: \(name)")
        }
    }
    let cBody: @convention(c) (Int64) -> Int64 = { $0 + 2 }
    let cCallback = try await callbacks.method(
        named: "foreignC(@convention(c) (Swift.Int64) -> Swift.Int64) -> Swift.Int64",
        as: ((UnsafeRawPointer) -> Int64).self)
    try check(unsafe cCallback.unsafeInvoke(unsafeBitCast(cBody, to: UnsafeRawPointer.self)) == 42,
        "A complete C callback declaration preserves its explicit pointer representation")
    let block: @convention(block) (Int64) -> Int64 = { $0 + 2 }
    let blockCallback = try await callbacks.method(
        named: "foreignBlock(@convention(block) (Swift.Int64) -> Swift.Int64) -> Swift.Int64",
        as: ((AnyObject) -> Int64).self)
    try check(unsafe blockCallback.unsafeInvoke(unsafeBitCast(block, to: AnyObject.self)) == 42,
        "A complete block callback declaration preserves its explicit object representation")
    let similarConstraint = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingSimilarConstraint<A where A: SwiftValueFixtures.BindingNotAnyObject>(A) -> A",
        as: ((BindingConstraintValue) -> BindingConstraintValue).self, genericArguments: [.type(BindingConstraintValue.self)])
    let indirectValue = BindingConstraintValue(text: String(repeating: "indirect", count: 100))
    try check(unsafe similarConstraint.unsafeInvoke(indirectValue) == bindingSimilarConstraint(indirectValue),
        "Protocol names ending in AnyObject preserve indirect generic value conventions")
    let overloadReceiver = InheritedGenericMemberReceiver(GenericReceiverNumber(42))
    let overloadObject = runtime.object(overloadReceiver)
    let overloadRead = try await overloadObject.method(named: "read(_:)", as: ((Int64) -> Int64).self)
    try check(unsafe overloadRead.unsafeInvoke(41) == overloadReceiver.read(Int64(41)),
        "Unsupported opaque overloads do not hide supported superclass members")
    let extensionRead = try await overloadObject.method(named: "read(_:)", as: ((Double) -> Double).self)
    try check(unsafe extensionRead.unsafeInvoke(40) == overloadReceiver.read(Double(40)),
        "Unsupported opaque overloads do not hide constrained extension members")
    let object: AnyObject = NSObject()
    let objectType = try await runtime.swiftType(named: "SwiftValueFixtures.BindingObjectBox", genericArguments: [.type(AnyObject.self)])
    let objectInit = try await objectType.initializer(named: "init(_:)", as: ((AnyObject) -> AnyObject).self)
    let boxedObject = try unsafe objectInit.unsafeInvoke(object)
    let objectProject = try await runtime.object(boxedObject).method(named: "project()", as: (() -> AnyObject).self)
    try check(unsafe objectProject.unsafeInvoke() === object, "AnyObject satisfies nominal generic class constraints")
    let objectIdentity = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingObjectIdentity<A where A: AnyObject>(A) -> A",
        as: ((AnyObject) -> AnyObject).self, genericArguments: [.type(AnyObject.self)])
    try check(unsafe objectIdentity.unsafeInvoke(object) === object, "AnyObject satisfies free-function generic class constraints")
    let protocolObject: any NSObjectProtocol = NSObject()
    let protocolIdentity = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingProtocolIdentity<A where A: __C.NSObject>(A) -> A",
        as: ((any NSObjectProtocol) -> any NSObjectProtocol).self, genericArguments: [.type((any NSObjectProtocol).self)])
    try check(unsafe protocolIdentity.unsafeInvoke(protocolObject) === protocolObject,
        "Objective-C existential generic arguments satisfy their protocol constraints")
    let superclassObject: any NSCopying & NSObject = NSString(string: "superclass existential")
    let superclassIdentity = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingSuperclassIdentity<A where A: __C.NSObject>(A, __C.NSObject) -> A",
        as: ((any NSCopying & NSObject, any NSObjectProtocol) -> any NSCopying & NSObject).self,
        genericArguments: [.type((any NSCopying & NSObject).self)])
    try check(unsafe superclassIdentity.unsafeInvoke(superclassObject, protocolObject) === superclassObject,
        "Objective-C compositions preserve superclass constraints and shared class/protocol names")
    let adapterType = try await runtime.swiftType(named: "SwiftValueFixtures.BindingGetter",
        genericArguments: [.type(String.self), .type(SmallError.self)])
    let adapterInit = try await adapterType.initializer(
        named: "init(A, B, Swift.Bool) -> SwiftValueFixtures.BindingGetter<A, B>",
        as: ((String, SmallError, BindingBoolAdapter) -> BindingGetter<String, SmallError>).self)
    let adapterReceiver = try unsafe adapterInit.unsafeInvoke("adapter", SmallError(1), BindingBoolAdapter(false))
    let adapterObject = runtime.object(adapterReceiver)
    let adapterGet = try await adapterObject.getter(named: "shouldThrow.getter : Swift.Bool", as: (() -> BindingBoolAdapter).self)
    try check(unsafe !adapterGet.unsafeInvoke().value && adapterReceiver.value == "adapter",
        "Complete generic initializer and getter declarations preserve concrete adapters")
    let adapterMethod = try await adapterObject.method(named: "compareFlag(Swift.Bool) -> Swift.Bool",
        as: ((BindingBoolAdapter) -> BindingBoolAdapter).self)
    try check(unsafe adapterMethod.unsafeInvoke(BindingBoolAdapter(false)).value,
        "Complete generic member declarations preserve concrete argument and result adapters")
    let adapterSet = try await adapterObject.setter(named: "shouldThrow.setter : Swift.Bool", as: BindingBoolAdapter.self)
    try unsafe adapterSet.unsafeInvoke(BindingBoolAdapter(true))
    try check(unsafe adapterGet.unsafeInvoke().value && adapterReceiver.shouldThrow,
        "Complete generic setter declarations preserve concrete adapters")
    let concreteMember = try await runtime.object(GenericMemberReceiver(GenericReceiverNumber(42))).method(
        named: "concrete(_:)", as: ((NativeSwiftBorrowing<String>) -> String).self)
    try check(unsafe concreteMember.unsafeInvoke(.init("borrowed:")) == "borrowed:42",
        "Generic members accept borrowing markers on concrete arguments")
    let closureType = try await runtime.swiftType(named: "SwiftValueFixtures.BindingClosureOwner", genericArguments: [.type(String.self)])
    let makeClosureOwner = try await closureType.initializer(named: "init(_:)",
        as: ((NativeSwiftClosure<() -> String>) -> BindingClosureOwner<String>).self)
    let setClosure = try await closureType.setter(named: "body", as: NativeSwiftClosure<() -> String>.self)
    let deaths = Mutex([0, 0])
    var closureOwner: BindingClosureOwner<String>?
    do {
        let token = ErrorToken { deaths.withLock { $0[0] += 1 } }
        closureOwner = try unsafe makeClosureOwner.unsafeInvoke(NativeSwiftClosure<() -> String> {
            withExtendedLifetime(token) { "initialized" }
        })
    }
    try check(closureOwner!.run() == "initialized" && deaths.withLock { $0[0] } == 0,
        "Generic initializer transfers the adapted closure capture")
    do {
        let token = ErrorToken { deaths.withLock { $0[1] += 1 } }
        try unsafe setClosure.unsafeInvoke(on: closureOwner!, NativeSwiftClosure<() -> String> {
            withExtendedLifetime(token) { "replaced" }
        })
    }
    try check(closureOwner!.run() == "replaced" && deaths.withLock { $0 } == [1, 0],
        "Generic closure setter transfers its new capture and releases its previous capture")
    closureOwner = nil
    try check(deaths.withLock { $0 } == [1, 1], "Stored generic closure captures are released exactly once")
    let consumeClosure = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingConsumeClosure<A, B where B: Swift.Error>(__owned () -> A, B, Swift.Bool) throws(B) -> A",
        as: ((NativeSwiftConsuming<NativeSwiftClosure<() -> String>>, SmallError, Bool) throws(SmallError) -> String).self,
        genericArguments: [.type(String.self), .type(SmallError.self)])
    let consumedBody = try NativeSwiftClosure<() -> String> { "consumed" }
    try check(unsafe consumeClosure.unsafeInvoke(.init(consumedBody), SmallError(46), false) == "consumed",
        "Consuming generic closure markers preserve native callback encoding")
    do {
        _ = try unsafe consumeClosure.unsafeInvoke(.init(consumedBody), SmallError(46), true)
        throw ArchitectureValidationFailure(description: "Missing consuming generic closure error")
    } catch let error as NativeSwiftError {
        try check(error.withUnderlyingError { ($0 as? SmallError)?.code == 46 },
            "Consumed generic closure copies preserve the native typed-error path")
    }
    let refined = try await runtime.swiftType(named: "SwiftValueFixtures.BindingHashOwner", genericArguments: [.type(String.self)])
    let hash = try await refined.staticMethod(named: "refinedWitness(_:)", as: ((String) -> Int).self)
    try check(unsafe hash.unsafeInvoke("hash") == BindingHashOwner<String>.refinedWitness("hash"),
        "Refined member constraints replace their nominal base witnesses")
    let concrete = try await runtime.swiftType(named: "SwiftValueFixtures.BindingHashOwner", genericArguments: [.type(Int.self)])
    let other = try await concrete.staticMethod(named: "concreteWitness(_:)", as: ((String) -> Int).self,
        genericArguments: [.type(String.self)])
    try check(unsafe other.unsafeInvoke("concrete") == BindingHashOwner<Int>.concreteWitness("concrete"),
        "Concrete enclosing constraints do not add witnesses before member arguments")
    let ordered = try await runtime.swiftType(named: "SwiftValueFixtures.BindingWitnessOwner", genericArguments: [.type(BindingWitnessValue.self)])
    let both = try await ordered.staticMethod(named: "orderedWitnesses()", as: (() -> Int64).self)
    try check(unsafe both.unsafeInvoke() == 42, "Independent nominal and member witnesses follow canonical order")
    let argument = try await runtime.swiftType(named: "SwiftValueFixtures.GenericReceiverNumber")
    let borrowedType = try await runtime.swiftType(named: "SwiftValueFixtures.BindingBorrowedRecord", genericArguments: [.type(argument)])
    let measure = try await borrowedType.borrowedMethod(named: "measure()", as: (() -> Int64).self)
    let measured = try await borrowedType.borrowedGetter(named: "measured", as: Int64.self)
    let callbackFailure = Mutex<(any Error)?>(nil)
    let callback = try NativeSwiftBorrowingClosure<(Int64, Int64)>(borrowing: borrowedType) { value in
        do { return try unsafe (measure.unsafeInvoke(on: value), measured.unsafeInvoke(on: value)) }
        catch { callbackFailure.withLock { $0 = error }; return (-1, -1) }
    }
    let visit = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitBindingBorrowedRecord(Swift.Int64, (SwiftValueFixtures.BindingBorrowedRecord<SwiftValueFixtures.GenericReceiverNumber>) -> (Swift.Int64, Swift.Int64)) -> (Swift.Int64, Swift.Int64)",
        as: ((Int64, NativeSwiftBorrowingClosure<(Int64, Int64)>) -> (Int64, Int64)).self)
    let borrowedResult = try unsafe visit.unsafeInvoke(42, callback)
    if let error = callbackFailure.withLock({ $0 }) { throw error }
    try check(borrowedResult == (2, 2),
        "Borrowed generic methods and getters receive metadata and tuple callbacks authenticate")
    let string = try await runtime.swiftType(named: "Swift.String")
    let boxType = try await runtime.swiftType(named: "SwiftValueFixtures.BindingBox",
        genericArguments: [.type(string)])
    let initialize = try await boxType.initializer(named: "init(_:)", as: ((String) -> AnyObject).self)
    let box = try unsafe initialize.unsafeInvoke("initial")
    let set = try await runtime.object(box).setter(named: "value", as: String.self)
    let get = try await boxType.getter(named: "value", as: (() -> String).self)
    try unsafe set.unsafeInvoke("updated")
    try check(unsafe get.unsafeInvoke(on: box) == "updated", "Generic class construction, AnyObject result, setter, and getter")
    let compare = try await runtime.object(box).method(named: "compare(_:)",
        as: ((Int64) -> (String, Int64, Bool)).self, genericArguments: [.type(Int64.self)])
    try check(unsafe compare.unsafeInvoke(42) == ("updated", 42, true), "Member parameters combine with retained enclosing types and witnesses")

    let valueType = try await runtime.swiftType(named: "SwiftValueFixtures.BindingValue",
        genericArguments: [.type(String.self)])
    let createValue = try await valueType.initializer(named: "init(_:)", as: ((String) -> BindingValue<String>).self)
    var value = try unsafe createValue.unsafeInvoke("value")
    let replace = try await valueType.method(named: "replace(_:)", as: ((String) -> Void).self, mutating: true)
    try unsafe replace.unsafeInvoke(on: &value, "replaced")
    let take = try await valueType.method(named: "take()", as: (() -> String).self, consuming: true)
    try check(unsafe take.unsafeInvoke(on: value) == "replaced" && value.value == "replaced",
        "Generic value initialization, mutation, and consuming receiver preserve ownership")

    let select = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingSelect<A, B where A == B.Element, B: Swift.Collection>(A, B) -> A",
        as: ((String, [String]) -> String).self, genericArguments: [.type(String.self), .type([String].self)])
    try check(unsafe select.unsafeInvoke("fallback", ["selected"]) == bindingSelect("fallback", ["selected"]),
        "Associated types and same-type constraints match the compiler call")
    let pack = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingPack<each A where A: Swift.Equatable>(repeat A) -> (repeat A)",
        as: ((Int64, String) -> (Int64, String)).self,
        genericArguments: [.pack([.type(Int64.self), .type(String.self)])])
    try check(unsafe pack.unsafeInvoke(41, "pack") == bindingPack(Int64(41), "pack"), "Pack metadata and witnesses preserve mixed results")
    let empty = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingPack<each A where A: Swift.Equatable>(repeat A) -> (repeat A)",
        as: (() -> Void).self, genericArguments: [.pack([])])
    try unsafe empty.unsafeInvoke()
    checks.append("Empty constrained pack preserves its shape")
    let packCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingPackCallback<each A>((repeat A) -> (repeat A), repeat A) -> (repeat A)",
        as: ((NativeSwiftClosure<(Int64, String) -> (Int64, String)>, Int64, String) -> (Int64, String)).self,
        genericArguments: [.pack([.type(Int64.self), .type(String.self)])])
    let packBody = try NativeSwiftClosure<(Int64, String) -> (Int64, String)> { ($0 + 1, $1 + "!") }
    try check(unsafe packCallback.unsafeInvoke(packBody, 41, "pack") == (42, "pack!"),
        "Pack callback authenticates its generic entry and reabstracts both directions")
    let packSource = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingPackSource<each A where A: Swift.Equatable>(SwiftValueFixtures.BindingPackSource<Pack{repeat A}>, repeat A) -> Swift.Int64",
        as: ((BindingPackSource<Int64, String>, Int64, String) -> Int64).self,
        genericArguments: [.pack([.type(Int64.self), .type(String.self)])])
    try check(unsafe packSource.unsafeInvoke(BindingPackSource(), 41, "pack") == 2,
        "Generic class arguments fulfill pack metadata and conformance requirements")

    let transform = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingTransform<A, B>([A], (A) throws -> B) throws -> [B]",
        as: (([Int64], NativeSwiftClosure<(Int64) throws -> String>) throws -> [String]).self,
        genericArguments: [.type(Int64.self), .type(String.self)])
    let body = try NativeSwiftClosure<(Int64) throws -> String> { "value: \($0)" }
    try check(unsafe transform.unsafeInvoke([1, 2], body) == ["value: 1", "value: 2"],
        "Generic collection callback preserves rethrows and managed results")
    let borrowedTransform = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingTransform<A, B>([A], (A) throws -> B) throws -> [B]",
        as: (([Int64], NativeSwiftBorrowing<NativeSwiftClosure<(Int64) throws -> String>>) throws -> [String]).self,
        genericArguments: [.type(Int64.self), .type(String.self)])
    try check(unsafe borrowedTransform.unsafeInvoke([3], .init(body)) == ["value: 3"],
        "Borrowing markers preserve generic closure argument and result reabstraction")
    let make = try await runtime.swiftFunction(named: "SwiftValueFixtures.bindingClosure<A>(A) -> (A) -> A",
        as: ((String) -> NativeSwiftClosure<(String) -> String>).self, genericArguments: [.type(String.self)])
    let closure = try unsafe make.unsafeInvoke(String(repeating: "retained", count: 100))
    await runtime.removeCachedResults()
    try check(unsafe closure.unsafeInvoke("ignored") == String(repeating: "retained", count: 100),
        "Returned generic closure retains its capture and authenticates after cache removal")

    let never = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingError<A where A: Swift.Error>(A.Type) throws(A) -> Swift.Int64",
        as: ((Never.Type) -> Int64).self, genericArguments: [.type(Never.self)])
    try check(unsafe never.unsafeInvoke(Never.self) == 44, "Never substitution preserves the generic throwing convention")
    let erased = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingError<A where A: Swift.Error>(A.Type) throws(A) -> Swift.Int64",
        as: (((any Error).Type) throws -> Int64).self, genericArguments: [.type((any Error).self)])
    try check(unsafe erased.unsafeInvoke((any Error).self) == 44, "Error existential binding supplies its self-conformance witness")
    let neverCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingErrorCallback<A where A: Swift.Error>(() throws(A) -> Swift.Int64) throws(A) -> Swift.Int64",
        as: ((NativeSwiftClosure<() -> Int64>) -> Int64).self, genericArguments: [.type(Never.self)])
    try check(unsafe neverCallback.unsafeInvoke(NativeSwiftClosure<() -> Int64> { 45 }) == 45,
        "Never-bound callback authenticates with the formal error convention")
    let erasedCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingErrorCallback<A where A: Swift.Error>(() throws(A) -> Swift.Int64) throws(A) -> Swift.Int64",
        as: ((NativeSwiftClosure<() throws -> Int64>) throws -> Int64).self, genericArguments: [.type((any Error).self)])
    do {
        _ = try unsafe erasedCallback.unsafeInvoke(NativeSwiftClosure<() throws -> Int64> { throw SmallError(46) })
        throw ArchitectureValidationFailure(description: "Missing existential-bound callback error")
    } catch let error as NativeSwiftError {
        try check(error.withUnderlyingError { ($0 as? SmallError)?.code == 46 }, "Existential-bound callback transfers the original error")
    }

    let asyncValue = try await runtime.swiftFunction(named: "SwiftValueFixtures.bindingAsync<A>(A) async -> A",
        as: (nonisolated(nonsending) (String) async -> String).self, genericArguments: [.type(String.self)])
    try check(unsafe await asyncValue.unsafeInvoke("async") == "async", "Generic async result preserves caller isolation")
    let asyncCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingAsyncCallback<A, B where B: Swift.Error>(A, nonisolated(nonsending) (A) async throws(B) -> A) async throws(B) -> A",
        as: (nonisolated(nonsending) (String, NativeSwiftClosure<nonisolated(nonsending) (String) async throws(SmallError) -> String>) async throws(SmallError) -> String).self,
        genericArguments: [.type(String.self), .type(SmallError.self)])
    let borrowedAsyncCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingAsyncCallback<A, B where B: Swift.Error>(A, nonisolated(nonsending) (A) async throws(B) -> A) async throws(B) -> A",
        as: (nonisolated(nonsending) (String, NativeSwiftBorrowing<NativeSwiftClosure<nonisolated(nonsending) (String) async throws(SmallError) -> String>>) async throws(SmallError) -> String).self,
        genericArguments: [.type(String.self), .type(SmallError.self)])
    for shouldThrow in [false, true] {
        let operation: (nonisolated(nonsending) @Sendable (String) async throws(SmallError) -> String) = {
            value async throws(SmallError) in
            await Task.yield()
            if shouldThrow { throw SmallError(47) }
            return value + "!"
        }
        let callback = try NativeSwiftClosure<nonisolated(nonsending) (String) async throws(SmallError) -> String>(operation)
        do {
            let result = try unsafe await asyncCallback.unsafeInvoke("callback", callback)
            try check(!shouldThrow && result == "callback!", "Generic async callback authenticates across suspension")
        } catch let error as NativeSwiftError {
            try check(shouldThrow && error.withUnderlyingError { ($0 as? SmallError)?.code == 47 },
                "Generic async callback preserves its typed failure")
        }
        do {
            let result = try unsafe await borrowedAsyncCallback.unsafeInvoke("borrowed", .init(callback))
            try check(!shouldThrow && result == "borrowed!", "Borrowed generic async callback authenticates across suspension")
        } catch let error as NativeSwiftError {
            try check(shouldThrow && error.withUnderlyingError { ($0 as? SmallError)?.code == 47 },
                "Borrowed generic async callback preserves its typed failure")
        }
    }
    let makeAsync = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingAsyncClosure<A where A: Swift.Sendable>(A) -> nonisolated(nonsending) @Sendable (A) async -> A",
        as: ((String) -> NativeSwiftClosure<nonisolated(nonsending) @Sendable (String) async -> String>).self,
        genericArguments: [.type(String.self)])
    let asyncClosure = try unsafe makeAsync.unsafeInvoke("captured")
    try check(unsafe await asyncClosure.unsafeInvoke("ignored") == "captured", "Returned async generic closure authenticates and retains its context")

    let mutate = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingMutate<A, B where B: Swift.Error>(inout A, __owned A, B, Swift.Bool) throws(B) -> ()",
        as: ((NativeSwiftInout<String>, NativeSwiftConsuming<String>, SmallError, Bool) throws(SmallError) -> Void).self,
        genericArguments: [.type(String.self), .type(SmallError.self)])
    let storage = NativeSwiftInout("before")
    do {
        try unsafe mutate.unsafeInvoke(storage, NativeSwiftConsuming("after"), SmallError(48), true)
        throw ArchitectureValidationFailure(description: "Missing generic mutation error")
    } catch let error as NativeSwiftError {
        try check(storage.value == "after" && error.withUnderlyingError { ($0 as? SmallError)?.code == 48 },
            "Generic consuming input and inout writeback survive typed errors")
    }
    let getter = BindingGetter("delayed", SmallError(49), false)
    let checked = try await runtime.object(getter).getter(named: "checkedNumber",
        as: (() throws(SmallError) -> Int64).self, declaredAs: "() throws(B) -> Swift.Int64")
    let fixed = try await runtime.object(getter).getter(named: "fixedNumber",
        as: (() throws(SmallError) -> Int64).self, declaredAs: "() throws(SwiftValueFixtures.SmallError) -> Swift.Int64")
    try check(unsafe checked.unsafeInvoke() == 42 && fixed.unsafeInvoke() == 43,
        "Generic and fixed getter errors keep distinct conventions with equal concrete types")
    let delayed = try await runtime.object(getter).getter(named: "delayed",
        as: (nonisolated(nonsending) () async throws(SmallError) -> String).self, declaredAs: "() async throws(B) -> A")
    try check(unsafe await delayed.unsafeInvoke() == "delayed", "Generic async getter returns its dependent value")
    getter.shouldThrow = true
    do {
        _ = try unsafe checked.unsafeInvoke()
        throw ArchitectureValidationFailure(description: "Missing generic getter error")
    } catch let error as NativeSwiftError {
        try check(error.withUnderlyingError { ($0 as? SmallError)?.code == 49 }, "Generic getter transfers typed error storage")
    }
    do {
        _ = try unsafe fixed.unsafeInvoke()
        throw ArchitectureValidationFailure(description: "Missing fixed getter error")
    } catch let error as NativeSwiftError {
        try check(error.withUnderlyingError { ($0 as? SmallError)?.code == 43 }, "Fixed getter preserves its direct error convention")
    }

    let metatypes = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingMetatypes<A>(A.Type, Swift.Int64.Type?, A) -> (A.Type, Swift.Int64.Type?, A)",
        as: ((String.Type, Int64.Type?, String) -> (String.Type, Int64.Type?, String)).self,
        genericArguments: [.type(String.self)])
    let nonnil = try unsafe metatypes.unsafeInvoke(String.self, nil, "metadata")
    let nilResult = try unsafe metatypes.unsafeInvoke(String.self, Int64.self, "metadata")
    try check(nonnil.0 == String.self && nonnil.1 == Int64.self && nonnil.2 == "metadata"
        && nilResult.1 == nil, "Generic thick and optional thin metatypes preserve physical result components")
    let metatypeCallback = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingMetatypeCallback<A>(A.Type, (A.Type) -> A.Type) -> A.Type",
        as: ((String.Type, NativeSwiftClosure<(String.Type) -> String.Type>) -> String.Type).self,
        genericArguments: [.type(String.self)])
    try check(unsafe metatypeCallback.unsafeInvoke(String.self, NativeSwiftClosure<(String.Type) -> String.Type> { $0 }) == String.self,
        "Thin concrete metatype callback restores the generic metadata word")
    let existential = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingExistentialMetatype<A>(Swift.CustomStringConvertible.Type, Swift.CustomStringConvertible.Protocol, A) -> (Swift.CustomStringConvertible.Type, Swift.CustomStringConvertible.Protocol, A)",
        as: ((any CustomStringConvertible.Type, (any CustomStringConvertible).Type, String)
            -> (any CustomStringConvertible.Type, (any CustomStringConvertible).Type, String)).self,
        genericArguments: [.type(String.self)])
    let types = try unsafe existential.unsafeInvoke(Int64.self, (any CustomStringConvertible).self, "existential")
    try check(ObjectIdentifier(types.0) == ObjectIdentifier(Int64.self)
        && types.1 == (any CustomStringConvertible).self && types.2 == "existential",
        "Existential and protocol metatypes preserve witnesses and singleton identity")
    return checks
}
