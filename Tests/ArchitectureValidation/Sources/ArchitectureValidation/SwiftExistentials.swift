import Foundation
import ABIBridge
import SwiftValueFixtures

@MainActor func validateSwiftExistentials() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let echo = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoAny(_:)", as: ((Any) -> Any).self)
    try check(try unsafe echo.unsafeInvoke(Int64(42)) as? Int64 == 42, "Any passes an inline payload indirectly")
    let counts = ArgumentCounts()
    weak var observed: ErrorToken?
    var saved: Any?
    do {
        let token = ErrorToken { counts.destroyed() }
        observed = token
        saved = try unsafe echo.unsafeInvoke(BoxedExistentialValue(token, 42))
    }
    try check(observed != nil && (saved as? BoxedExistentialValue)?.number == 42, "Any owns an out-of-line reference-bearing payload")
    var copy = saved
    saved = nil
    try check(observed != nil && (copy as? BoxedExistentialValue)?.number == 42, "Copying an existential retains its payload")
    copy = nil
    try check(observed == nil && counts.destructions == 1, "Final existential destruction releases the payload exactly once")

    let composed = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoComposition(_:)",
        as: ((any ExistentialValue & ExistentialLabel) -> any ExistentialValue & ExistentialLabel).self)
    let value = try unsafe composed.unsafeInvoke(InlineExistentialValue(42))
    try check(value.number == 42 && value.label == "inline:42", "Protocol composition preserves both witness tables")

    let object = ExistentialObject(ErrorToken(), 42)
    let direct = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoClassExistential(_:)",
        as: ((any ExistentialObjectValue) -> any ExistentialObjectValue).self)
    let large = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoManyClassExistential(_:)",
        as: ((ManyObjectProtocols) -> ManyObjectProtocols).self)
    try check(try unsafe direct.unsafeInvoke(object) === object, "Class-constrained existential passes object and witness pointers")
    try check(try unsafe large.unsafeInvoke(object) === object, "Large class composition uses physical indirect storage")

    typealias OpaqueCallback = NativeSwiftClosure<(any ExistentialValue) -> any ExistentialValue>
    let apply = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyExistentialClosure(_:_:)",
        as: ((OpaqueCallback, any ExistentialValue) -> any ExistentialValue).self)
    let generated = try OpaqueCallback { InlineExistentialValue($0.number + 1) }
    try check(try unsafe apply.unsafeInvoke(generated, BoxedExistentialValue(ErrorToken(), 41)).number == 42, "Opaque existential callback authenticates its formally indirect signature")
    let factory = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeExistentialClosure(_:)",
        as: ((any ExistentialValue) -> OpaqueCallback).self)
    let returned = try unsafe factory.unsafeInvoke(BoxedExistentialValue(ErrorToken(), 42))
    try check(try unsafe returned.unsafeInvoke(InlineExistentialValue(0)).number == 42, "Returned existential closure keeps its capture and authenticates its entry")

    typealias ClassCallback = NativeSwiftClosure<(ManyObjectProtocols) -> ManyObjectProtocols>
    let classApply = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyManyClassExistentialClosure(_:_:)",
        as: ((ClassCallback, ManyObjectProtocols) -> ManyObjectProtocols).self)
    try check(try unsafe classApply.unsafeInvoke(.init { $0 }, object) === object, "Class composition authentication stays class-based despite physical indirection")

    typealias OptionalClass = NativeSwiftClosure<((any ExistentialObjectValue)?) -> (any ExistentialObjectValue)?>
    let optional = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyOptionalClassClosure(_:_:)",
        as: ((OptionalClass, (any ExistentialObjectValue)?) -> (any ExistentialObjectValue)?).self)
    try check(try unsafe optional.unsafeInvoke(.init { $0 }, object) === object, "Optional class existential callback uses its optional authentication identity")
    try check(try unsafe optional.unsafeInvoke(.init { $0 }, nil) == nil, "Optional class existential preserves nil")

    typealias ErrorCallback = NativeSwiftClosure<((any Error)?) -> (any Error)?>
    let failure = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyOptionalErrorClosure(_:_:)",
        as: ((ErrorCallback, (any Error)?) -> (any Error)?).self)
    let error = try unsafe failure.unsafeInvoke(.init { $0 }, SmallError(42))
    try check((error as? SmallError)?.code == 42, "Optional error existential preserves its boxed representation and authentication")

    typealias AsyncCallback = NativeSwiftClosure<@Sendable @concurrent (any ExistentialValue) async -> any ExistentialValue>
    let asyncApply = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyAsyncExistentialClosure(_:_:)",
        as: (@concurrent (AsyncCallback, any ExistentialValue) async -> any ExistentialValue).self)
    let body: @Sendable (any ExistentialValue) async -> any ExistentialValue = { value in
        await Task.yield()
        return InlineExistentialValue(value.number + 1)
    }
    try check(try unsafe await asyncApply.unsafeInvoke(AsyncCallback(body), InlineExistentialValue(41)).number == 42, "Async callback returns an owned existential after suspension")
    for name in ["makeRuntimeExtended", "makeRuntimeExtendedObject"] {
        let protocolName = name == "makeRuntimeExtended" ? "RuntimeExtendedSource" : "RuntimeExtendedObject"
        let call = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.\(name)<A>(A) -> any SwiftValueFixtures.\(protocolName)<Self.Element == A>",
            as: ((Int) -> NativeSwiftValue).self, genericArguments: [.type(Int.self)])
        let value = try unsafe call.unsafeInvoke(42)
        try check(try value.withCopy { ($0 as? any CustomStringConvertible)?.description } == "42",
            name + " constructs missing parameterized-protocol metadata from its declaration")
    }
    typealias ExtendedCallback = NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Int>
    let applyExtended = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.applyRuntimeExtendedObject<A>((any SwiftValueFixtures.RuntimeExtendedObject<Self.Element == A>) -> Swift.Int, A) -> Swift.Int",
        as: ((ExtendedCallback, Int) -> Int).self, genericArguments: [.type(Int.self)])
    let callback = try ExtendedCallback { value in
        do { return try value.copy().withCopy { ($0 as? any CustomStringConvertible)?.description == "42" ? 42 : -1 } }
        catch { return -2 }
    }
    try check(try unsafe applyExtended.unsafeInvoke(callback, 42) == 42,
        "Runtime-only class-constrained existential callbacks preserve their authenticated convention")
    let superclassName = "any SwiftValueFixtures.RuntimeExtendedSuperclass<A> & SwiftValueFixtures.RuntimeExtendedObject<Self.Element == A>"
    let makeSuperclass = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeRuntimeExtendedSuperclass<A>(A) -> " + superclassName,
        as: ((Int) -> NativeSwiftValue).self, genericArguments: [.type(Int.self)])
    let superclassValue = try unsafe makeSuperclass.unsafeInvoke(42)
    try check(try superclassValue.withCopy { ($0 as? any CustomStringConvertible)?.description } == "42",
        "Runtime-only superclass existential retains superclass arguments and protocol witnesses")
    let applySuperclass = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.applyRuntimeExtendedSuperclass<A>((" + superclassName + ") -> Swift.Int, A) -> Swift.Int",
        as: ((ExtendedCallback, Int) -> Int).self, genericArguments: [.type(Int.self)])
    try check(try unsafe applySuperclass.unsafeInvoke(callback, 42) == 42,
        "Generic superclass callback authenticates the native class and witness container")
    let superclassClosure = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeRuntimeExtendedSuperclassClosure<A>(A) -> () -> " + superclassName,
        as: ((Int) -> NativeSwiftClosure<() -> NativeSwiftValue>).self, genericArguments: [.type(Int.self)])
    try check(try unsafe superclassClosure.unsafeInvoke(43).unsafeInvoke().withCopy { ($0 as? any CustomStringConvertible)?.description } == "43",
        "Returned generic superclass closure keeps the native existential representation")
    typealias SuperclassValue = any RuntimeExtendedSuperclass<Int> & RuntimeExtendedObject<Int>
    let typedSuperclass = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeRuntimeExtendedSuperclass<A>(A) -> " + superclassName,
        as: ((Int) -> SuperclassValue).self, genericArguments: [.type(Int.self)])
    try check(try unsafe typedSuperclass.unsafeInvoke(44).value == 44,
        "Typed generic superclass existential binds exact superclass metadata")
    let leftComposition = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeLeftConstrainedComposition() -> any SwiftValueFixtures.RuntimeExtendedLeft & SwiftValueFixtures.RuntimeExtendedRight<Self.SwiftValueFixtures.RuntimeExtendedLeft.Element == Swift.Int>",
        as: (() -> NativeSwiftValue).self)
    let rightComposition = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeRightConstrainedComposition() -> any SwiftValueFixtures.RuntimeExtendedLeft & SwiftValueFixtures.RuntimeExtendedRight<Self.SwiftValueFixtures.RuntimeExtendedRight.Element == Swift.Int>",
        as: (() -> NativeSwiftValue).self)
    let leftValue = try unsafe leftComposition.unsafeInvoke()
    let rightValue = try unsafe rightComposition.unsafeInvoke()
    try check(leftValue.type != rightValue.type,
        "Parameterized compositions retain the declaring protocol of same-named associated types")
    typealias ClassComposition = any RuntimeClassFirst<Int> & RuntimeClassSecond<Int>
    let makeComposition = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeRuntimeDistinctClassComposition(_:)",
        as: ((Int) -> ClassComposition).self, genericArguments: [.type(Int.self)])
    let classValue = try unsafe makeComposition.unsafeInvoke(42)
    let echoComposition = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoRuntimeDistinctClassComposition(_:)",
        as: ((ClassComposition) -> ClassComposition).self, genericArguments: [.type(Int.self)])
    try check(try unsafe echoComposition.unsafeInvoke(classValue) === classValue && (classValue as? RuntimeClassBoth<Int>)?.value == 42,
        "Parameterized class compositions keep both object protocol witnesses")
    let shared = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeRuntimeSharedComposition(_:)",
        as: ((Int) -> NativeSwiftValue).self, genericArguments: [.type(Int.self)])
    try check(try unsafe shared.unsafeInvoke(42).withCopy { ($0 as? any RuntimeSharedBase<Int>)?.value } == 42,
        "Shared inherited associated types resolve one declaring protocol")
    typealias Metatype = any RuntimeClassLeft<Int>.Type
    let metatypeEcho = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoRuntimeParameterizedMetatype(_:)",
        as: ((Metatype) -> Metatype).self, genericArguments: [.type(Int.self)])
    try check(ObjectIdentifier(try unsafe metatypeEcho.unsafeInvoke(RuntimeClassBoth<Int>.self)) == ObjectIdentifier(RuntimeClassBoth<Int>.self),
        "Parameterized existential metatypes preserve their type and witness")
    let metatypeFactory = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeRuntimeParameterizedMetatype(_:)",
        as: ((Int) -> NativeSwiftValue).self, genericArguments: [.type(Int.self)])
    let erasedMetatype = try unsafe metatypeFactory.unsafeInvoke(42)
    try check(try erasedMetatype.withCopy { ($0 as? Metatype).map(ObjectIdentifier.init) } == ObjectIdentifier(RuntimeClassBoth<Int>.self),
        "Runtime-only metatype results retain their extended shape")
    let metatypeApply = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyRuntimeParameterizedMetatype(_:_:)",
        as: ((NativeSwiftClosure<(Metatype) -> Metatype>, Int) -> Metatype).self, genericArguments: [.type(Int.self)])
    try check(ObjectIdentifier(try unsafe metatypeApply.unsafeInvoke(.init { $0 }, 42)) == ObjectIdentifier(RuntimeClassBoth<Int>.self),
        "Parameterized metatype callbacks authenticate their native entry")
    for (index, arguments) in [[NativeSwiftGenericArgument.pack([])], [.pack([.type(Int.self), .type(String.self)])]].enumerated() {
        let make = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeSuperclassPackExistential(_:)",
            as: ((Int64) -> NativeSwiftValue).self, genericArguments: arguments)
        let echo = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoSuperclassPackExistential(_:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: arguments)
        let value = try unsafe make.unsafeInvoke(42)
        let copied = try unsafe echo.unsafeInvoke(value)
        try check(try copied.withCopy { ($0 as? any ExistentialPackMarker)?.number } == 42,
            "Superclass existential resolves and preserves a type pack in case \(index)")
    }
    typealias PackValue = any ExistentialPackBase<Int, String> & ExistentialPackMarker
    typealias PackBody = NativeSwiftClosure<(PackValue) throws -> PackValue>
    let makePack = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeSuperclassPackExistential(_:)",
        as: ((Int64) -> PackValue).self, genericArguments: [.pack([.type(Int.self), .type(String.self)])])
    let applyPack = try await runtime.swiftFunction(named: "SwiftValueFixtures.applySuperclassPackExistential(_:_:)",
        as: ((PackValue, PackBody) throws -> PackValue).self, genericArguments: [.pack([.type(Int.self), .type(String.self)])])
    let packValue = try unsafe makePack.unsafeInvoke(43)
    try check(try unsafe applyPack.unsafeInvoke(packValue, .init { $0 }).number == 43,
        "Superclass type-pack callback preserves its class and protocol witness")
    let copying = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoNSObjectCopying(_:_:)",
        as: ((any NSObject & NSCopying, Int) -> any NSObject & NSCopying).self, genericArguments: [.type(Int.self)])
    let string = "copying" as NSString
    try check(try unsafe copying.unsafeInvoke(string, 42) === string,
        "Ordinary superclass existential resolves tagged Objective-C protocol references")
    return checks
}
