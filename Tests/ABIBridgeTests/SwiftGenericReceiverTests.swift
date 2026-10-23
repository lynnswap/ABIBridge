import ABIBridge
import Foundation
import ManagedSwiftFixtures
import Testing

extension GenericGetterFailure: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .int64 }
}

private protocol ReceiverMetric { var text: String { get } }
private struct ReceiverNumber: ReceiverMetric {
    let number: Int
    var text: String { String(number) }
}
private struct ReceiverText: ReceiverMetric, ABIBridgeSwiftValue {
    let text: String
    // This fixture's dependent Value boundary is formally indirect, even though
    // its String payload would fit the ordinary concrete-value registers.
    static var swiftABIType: NativeType { try! .opaque(named: "ReceiverText") }
}

private struct ReceiverBoolAdapter: ABIBridgeValue {
    let value: Bool
    init(_ value: Bool) { self.value = value }
    static let abiType: NativeType = .bool
    init(nativeValue: NativeValue) throws { value = try unsafe nativeValue.read(as: Bool.self) }
    static func nativeValue(from value: Self) throws -> NativeValue { try NativeValue(copying: value.value, as: .bool) }
}

// Keep the private generic entry points in optimized tests. Without this,
// specialization removes their unspecialized symbols or changes ownership.
private class GenericReceiver<Value: ReceiverMetric>: NSObject {
    let value: Value
    var suffix = ""
    init(_ value: Value) { self.value = value }
    @inline(never) @_optimize(none) func title(_ prefix: String) -> String { prefix + value.text + suffix }
    @inline(never) @_optimize(none) func read(_ value: Int64) -> Int64 { value + 1 }
    @inline(never) @_optimize(none) func read(_ value: String) -> some Any { value }
    @inline(never) @_optimize(none) func unsupportedRead(_ value: String) -> some Any { value }
    var text: String {
        @inline(never) @_optimize(none) get { value.text + suffix }
        @inline(never) @_optimize(none) set { suffix = newValue }
    }
    @inline(never) @_optimize(none) consuming func consumeTitle() -> String { value.text + suffix }
    @inline(never) @_optimize(none) func projected() -> Value { value }
    @inline(never) @_optimize(none) func echo(_ value: Value) -> Value { value }
    var payload: Value { @inline(never) @_optimize(none) get { value } }
    @inline(never) @_optimize(none) func independent<Other>(_ value: Other) -> Other { value }
    @inline(never) @_optimize(none) func throwingTitle(_ fail: Bool) throws -> String {
        if fail { throw ReceiverFailure.rejected }
        return value.text
    }
    @inline(never) @_optimize(none) func asyncTitle(_ prefix: String) async -> String { prefix + value.text }
}
extension GenericReceiver where Value == ReceiverNumber {
    @inline(never) @_optimize(none) func read(_ value: Double) -> Double { value + 2 }
}
private final class InheritedGenericReceiver: GenericReceiver<ReceiverNumber> {}
private enum ReceiverFailure: Error { case rejected }

struct SwiftGenericReceiverTests {
    @MainActor @Test func classReceiversFulfillNestedGenericRequirements() async throws {
        let receiver = GenericSourceNested(GenericSourceBox(GenericSourceValue(39)))
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ManagedSwiftFixtures.GenericSourceNested",
            genericArguments: [.type(GenericSourceBox<GenericSourceValue>.self)]
        )
        let total = try await type.resolve(
            .method(
                "sourceTotal(_:)",
                as: (([Int64]) throws -> Int64).self,
                genericArguments: [.type(GenericSourceValue.self), .type([Int64].self)]
            )
        )
        let values: [Int64] = [1, 2]
        #expect(try unsafe total.unsafeInvoke(on: receiver, values) == receiver.sourceTotal(values))
    }

    @Test func genericOperatorsPreserveAliasesAndExplicitFixity() async throws {
        typealias Box = GenericOperatorBox<Int64>
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ManagedSwiftFixtures.GenericOperatorBox",
            genericArguments: [.type(Int64.self)])
        let lhs = Box(42), rhs = Box(1)
        for (name, expected) in [(">", lhs > rhs), ("<", lhs < rhs), ("<<", lhs << rhs), ("<>", lhs <> rhs),
                                 ("<≪", lhs <≪ rhs), ("≪<", lhs ≪< rhs), (".<>", lhs .<> rhs)] {
            let method = try await type.resolve(
                .staticMethod(
                    name + "(_:_:)",
                    as: ((Box, Box) -> Bool).self
                )
            )
            #expect(try unsafe method.unsafeInvoke(lhs, rhs) == expected)
            let complete = try await type.resolve(
                .staticMethod(
                    name
                        + "(ManagedSwiftFixtures.GenericOperatorBox<A>, ManagedSwiftFixtures.GenericOperatorBox<A>) -> Swift.Bool",
                    as: ((Box, Box) -> ReceiverBoolAdapter).self
                )
            )
            #expect(try unsafe complete.unsafeInvoke(lhs, rhs).value == expected)
        }
        do {
            _ = try await type.resolve(.staticMethod("^^^(_:)", as: ((Box) -> Int64).self))
            Issue.record("Prefix and postfix implementations must remain ambiguous without fixity")
        } catch ABIResolutionError.ambiguousDeclaration(_, let candidates) {
            #expect(candidates.count == 2)
        }
        let prefix = try await type.resolve(
            .staticMethod("^^^ prefix(_:)", as: ((Box) -> Int64).self)
        )
        let postfix = try await type.resolve(
            .staticMethod("^^^ postfix(_:)", as: ((Box) -> Int64).self)
        )
        #expect(try unsafe prefix.unsafeInvoke(lhs) == ^^^lhs)
        #expect(try unsafe postfix.unsafeInvoke(lhs) == lhs^^^)
        let generic = try await type.resolve(
            .staticMethod(
                "+(_:_:)",
                as: ((Box, String) -> String).self,
                genericArguments: [.type(String.self)]
            )
        )
        #expect(try unsafe generic.unsafeInvoke(lhs, "member") == lhs + "member")
        let qualifiedAlias = generic.symbol.declaration.name.replacingOccurrences(of: " infix", with: "")
        let qualified = try await type.resolve(
            .staticMethod(
                qualifiedAlias,
                as: ((Box, String) -> String).self,
                genericArguments: [.type(String.self)]
            )
        )
        #expect(try unsafe qualified.unsafeInvoke(lhs, "qualified") == "qualified")
    }

    @Test func callbackConventionsStayDistinctDuringMemberLookup() async throws {
        let object = ABIRuntime.shared.object(GenericCallbackConventions<Int64>())
        let call = try await object.resolve(
            .method(
                "callback(_:)",
                as: ((NativeSwiftClosure<(Int64) -> Int64>) -> Int64).self
            )
        )
        let body = try NativeSwiftClosure<(Int64) -> Int64> { $0 + 2 }
        #expect(try unsafe call.unsafeInvoke(body) == 42)
        let returned = try await object.resolve(
            .method(
                "returnedCallback()",
                as: (() -> NativeSwiftClosure<(Int64) -> Int64>).self
            )
        )
        let returnedBody = try unsafe returned.unsafeInvoke()
        #expect(try unsafe returnedBody.unsafeInvoke(40) == 42)
        for name in ["foreignC(_:)", "foreignBlock(_:)"] {
            do {
                _ = try await object.resolve(
                    .method(
                        name,
                        as: ((NativeSwiftClosure<(Int64) -> Int64>) -> Int64).self
                    )
                )
                Issue.record("A Swift closure must not match a foreign function convention")
            } catch let ABIResolutionError.signatureMismatch(mismatch) {
                #expect(mismatch.position == .argument(0))
            }
        }
        let cBody: @convention(c) (Int64) -> Int64 = { $0 + 2 }
        let cCall = try await object.resolve(
            .method(
                "foreignC(@convention(c) (Swift.Int64) -> Swift.Int64) -> Swift.Int64",
                as: ((UnsafeRawPointer) -> Int64).self
            )
        )
        #expect(try unsafe cCall.unsafeInvoke(unsafeBitCast(cBody, to: UnsafeRawPointer.self)) == 42)
        let block: @convention(block) (Int64) -> Int64 = { $0 + 2 }
        let blockCall = try await object.resolve(
            .method(
                "foreignBlock(@convention(block) (Swift.Int64) -> Swift.Int64) -> Swift.Int64",
                as: ((AnyObject) -> Int64).self
            )
        )
        #expect(try unsafe blockCall.unsafeInvoke(unsafeBitCast(block, to: AnyObject.self)) == 42)
    }

    @MainActor @Test func inapplicableOverloadsDoNotHideUsableMembers() async throws {
        let runtime = ABIRuntime.shared
        for receiver in [GenericReceiver(ReceiverNumber(number: 42)),
                         InheritedGenericReceiver(ReceiverNumber(number: 43))] {
            let object = runtime.object(receiver)
            let read = try await object.resolve(.method("read(_:)", as: ((Int64) -> Int64).self))
            #expect(try unsafe read.unsafeInvoke(41) == receiver.read(Int64(41)))
            let extensionRead = try await object.resolve(
                .method("read(_:)", as: ((Double) -> Double).self)
            )
            #expect(try unsafe extensionRead.unsafeInvoke(40) == receiver.read(Double(40)))
            #expect(throws: ABIResolutionError.self) {
                _ = try object.resolveAndWait(
                    .method("unsupportedRead(_:)", as: ((String) -> Int64).self)
                )
            }
        }
    }

    @MainActor @Test func completeMemberDeclarationsPreserveConcreteAdapters() async throws {
        let runtime = ABIRuntime.shared
        let receiver = GenericReceiver(ReceiverNumber(number: 42))
        let object = runtime.object(receiver)
        let name = "throwingTitle(Swift.Bool) throws -> Swift.String"
        let method = try await object.resolve(
            .method(
                name,
                as: ((ReceiverBoolAdapter) throws -> String).self
            )
        )
        #expect(try unsafe method.unsafeInvoke(ReceiverBoolAdapter(false)) == "42")
        do {
            _ = try unsafe method.unsafeInvoke(ReceiverBoolAdapter(true))
            Issue.record("Expected the concrete native error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is ReceiverFailure })
        }
        let qualified = try await object.resolve(
            .method(
                method.method.symbol.declaration.name,
                as: ((ReceiverBoolAdapter) throws -> String).self
            )
        )
        #expect(try unsafe qualified.unsafeInvoke(ReceiverBoolAdapter(false)) == "42")
        let borrowed = try await object.resolve(
            .method(
                name,
                as: ((NativeSwiftBorrowing<ReceiverBoolAdapter>) throws -> String).self
            )
        )
        #expect(try unsafe borrowed.unsafeInvoke(.init(ReceiverBoolAdapter(false))) == "42")
        // The native declaration takes a Bool, not the adapter's String.
        do {
            _ = try await object.resolve(
                .method(
                    "throwingTitle(_:)",
                    as: ((ReceiverBoolAdapter) throws -> String).self
                )
            )
            Issue.record("An adapter must use the selected native declaration's concrete type")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.position == .argument(0))
        }
        do {
            _ = try await object.resolve(
                .method(
                    "throwingTitle(Swift.String) throws -> Swift.String",
                    as: ((ReceiverBoolAdapter) throws -> String).self
                )
            )
            Issue.record("An adapter must use the selected native declaration's concrete type")
        } catch ABIResolutionError.declarationNotFound {}
        do {
            _ = try await object.resolve(
                .method(
                    "echo(A) -> A",
                    as: ((ReceiverBoolAdapter) -> ReceiverBoolAdapter).self
                )
            )
            Issue.record("A dependent argument must still use its bound Swift type")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.declaration?.name.contains("echo(A) -> A") == true)
        }
    }

    @Test func completeInitializersAndAccessorsPreserveConcreteAdapters() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.GenericEffectfulGetter",
            genericArguments: [.type(String.self), .type(GenericGetterFailure.self)])
        let initialize = try await type.resolve(
            .initializer(
                "init(A, B, Swift.Bool) -> ManagedSwiftFixtures.GenericEffectfulGetter<A, B>",
                as: ((String, GenericGetterFailure, ReceiverBoolAdapter) -> GenericEffectfulGetter<
                    String, GenericGetterFailure
                >).self
            )
        )
        let receiver = try unsafe initialize.unsafeInvoke("adapter", GenericGetterFailure(1), ReceiverBoolAdapter(false))
        let object = runtime.object(receiver)
        let getter = try await object.resolve(
            .getter(
                "shouldThrow.getter : Swift.Bool",
                as: (() -> ReceiverBoolAdapter).self
            )
        )
        let setter = try await object.resolve(
            .setter(
                "shouldThrow.setter : Swift.Bool",
                as: ((ReceiverBoolAdapter) -> Void).self
            )
        )
        #expect(try unsafe getter.unsafeInvoke().value == false)
        try unsafe setter.unsafeInvoke(ReceiverBoolAdapter(true))
        let updated = try unsafe getter.unsafeInvoke()
        #expect(receiver.shouldThrow && updated.value)
    }

    @MainActor @Test func concreteMemberArgumentsKeepTheirBorrowingMarkers() async throws {
        let receiver = GenericReceiver(ReceiverNumber(number: 42))
        let method = try await ABIRuntime.shared.object(receiver).resolve(
            .method(
                "title(_:)",
                as: ((NativeSwiftBorrowing<String>) -> String).self
            )
        )
        #expect(try unsafe method.unsafeInvoke(.init("borrowed:")) == receiver.title("borrowed:"))
    }

    @MainActor @Test func effectfulGenericGettersUseTheDeclaredErrorConvention() async throws {
        let runtime = ABIRuntime.shared
        let owner = GenericEffectfulGetter("getter", GenericGetterFailure(42), false)
        let object = runtime.object(owner)
        let type = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.GenericEffectfulGetter",
            genericArguments: [.type(String.self), .type(GenericGetterFailure.self)])
        let checked = try await object.resolve(
            .getter(
                "checked",
                as: (() throws(GenericGetterFailure) -> String).self,
                declaredAs: "() throws(B) -> A"
            )
        )
        let fixed = try await type.resolve(
            .getter(
                "fixedFailure",
                as: (() throws(GenericGetterFailure) -> String).self,
                declaredAs: "() throws(ManagedSwiftFixtures.GenericGetterFailure) -> A"
            )
        )
        let delayed = try await object.resolve(.getter("delayed", as: (() async -> String).self))
        let delayedChecked = try await object.resolve(
            .getter(
                "delayedChecked",
                as: (() async throws(GenericGetterFailure) -> String).self,
                declaredAs: "() async throws(B) -> A"
            )
        )
        let number = try await object.resolve(
            .getter(
                "checkedNumber",
                as: (() throws(GenericGetterFailure) -> Int64).self,
                declaredAs: "() throws(B) -> Swift.Int64"
            )
        )
        let fixedNumber = try await object.resolve(
            .getter(
                "fixedNumber",
                as: (() throws(GenericGetterFailure) -> Int64).self,
                declaredAs: "() throws(ManagedSwiftFixtures.GenericGetterFailure) -> Swift.Int64"
            )
        )
        let delayedNumber = try await object.resolve(
            .getter(
                "delayedNumber",
                as: (() async throws(GenericGetterFailure) -> Int64).self,
                declaredAs: "() async throws(B) -> Swift.Int64"
            )
        )
        let delayedFixedNumber = try await object.resolve(
            .getter(
                "delayedFixedNumber",
                as: (() async throws(GenericGetterFailure) -> Int64).self,
                declaredAs:
                    "() async throws(ManagedSwiftFixtures.GenericGetterFailure) -> Swift.Int64"
            )
        )
        #expect(try unsafe checked.unsafeInvoke() == "getter")
        #expect(try unsafe fixed.unsafeInvoke(on: owner) == "getter")
        #expect(try unsafe await delayed.unsafeInvoke() == "getter")
        #expect(try unsafe await delayedChecked.unsafeInvoke() == "getter")
        #expect(try unsafe number.unsafeInvoke() == 41)
        #expect(try unsafe fixedNumber.unsafeInvoke() == 42)
        #expect(try unsafe await delayedNumber.unsafeInvoke() == 43)
        #expect(try unsafe await delayedFixedNumber.unsafeInvoke() == 44)
        owner.shouldThrow = true
        for (call, code) in [({ try unsafe checked.unsafeInvoke() }, Int64(42)),
                             ({ try unsafe fixed.unsafeInvoke(on: owner) }, Int64(71))] {
            do { _ = try call(); Issue.record("Expected a native getter error") }
            catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? GenericGetterFailure)?.code == code) } }
        }
        do { _ = try unsafe await delayedChecked.unsafeInvoke(); Issue.record("Expected an async getter error") }
        catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? GenericGetterFailure)?.code == 42) } }
        for (call, code) in [({ try unsafe number.unsafeInvoke() }, Int64(42)),
                             ({ try unsafe fixedNumber.unsafeInvoke() }, Int64(72))] {
            do { _ = try call(); Issue.record("Expected a scalar getter error") }
            catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? GenericGetterFailure)?.code == code) } }
        }
        do { _ = try unsafe await delayedNumber.unsafeInvoke(); Issue.record("Expected an async generic getter error") }
        catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? GenericGetterFailure)?.code == 42) } }
        do { _ = try unsafe await delayedFixedNumber.unsafeInvoke(); Issue.record("Expected an async fixed getter error") }
        catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as? GenericGetterFailure)?.code == 73) } }
        let staticGetter = try await type.resolve(
            .staticGetter(
                "checkedType",
                as: (() throws(GenericGetterFailure) -> String.Type).self,
                declaredAs: "() throws(B) -> A.Type"
            )
        )
        let asyncStaticGetter = try await type.resolve(
            .staticGetter(
                "delayedType",
                as: (() async throws(GenericGetterFailure) -> String.Type).self,
                declaredAs: "() async throws(B) -> A.Type"
            )
        )
        #expect(try unsafe staticGetter.unsafeInvoke() == String.self)
        #expect(try unsafe await asyncStaticGetter.unsafeInvoke() == String.self)
        do {
            _ = try await object.resolve(
                .getter(
                    "checked",
                    as: (() throws(GenericGetterFailure) -> String).self
                )
            )
            Issue.record("The formal error cannot be inferred from the bound error type")
        } catch ABIResolutionError.unsupportedDeclaration {}
    }
    @MainActor @Test(arguments: [false, true])
    func dependentMembersAndIndependentParametersUseRawSwiftValues(_ inherited: Bool) async throws {
        let receiver: GenericReceiver<ReceiverNumber> = inherited
            ? InheritedGenericReceiver(.init(number: 42)) : GenericReceiver(.init(number: 42))
        let object = ABIRuntime.shared.object(receiver)
        let projected = try await object.resolve(
            .method("projected()", as: (() -> ReceiverNumber).self)
        )
        let echo = try await object.resolve(
            .method(
                "echo(_:)",
                as: ((ReceiverNumber) -> ReceiverNumber).self
            )
        )
        let getter = try await object.resolve(.getter("payload", as: (() -> ReceiverNumber).self))
        let independent = try await object.resolve(
            .method(
                "independent(_:)",
                as: ((String) -> String).self,
                genericArguments: [.type(String.self)]
            )
        )
        #expect(try unsafe projected.unsafeInvoke().number == 42)
        #expect(try unsafe echo.unsafeInvoke(ReceiverNumber(number: 7)).number == 7)
        #expect(try unsafe getter.unsafeInvoke().number == 42)
        #expect(try unsafe independent.unsafeInvoke("member") == "member")
    }

    @MainActor @Test func extractedGenericMethodsKeepContextWithoutRetainingTheOriginalObject() async throws {
        let runtime = ABIRuntime()
        weak var observed: GenericReceiver<ReceiverNumber>?
        let consuming: NativeSwiftMethod<() -> String>
        let asynchronous: NativeSwiftMethod<nonisolated(nonsending) (String) async -> String>
        do {
            let original = GenericReceiver(ReceiverNumber(number: 1))
            observed = original
            consuming = try await runtime.object(original).resolve(
                .method(
                    "consumeTitle()",
                    as: (() -> String).self,
                    receiver: .consuming
                )
            ).method
            asynchronous = try await runtime.object(original).resolve(
                .method(
                    "asyncTitle(_:)",
                    as: ((String) async -> String).self
                )
            ).method
        }
        runtime.removeCachedResults()
        #expect(observed == nil)
        var second: GenericReceiver<ReceiverNumber>? = GenericReceiver(.init(number: 42))
        weak let observedSecond = second
        var bound: NativeBoundSwiftMethod<nonisolated(nonsending) (String) async -> String>? = try asynchronous.bind(to: second!)
        #expect(try unsafe consuming.unsafeInvoke(on: second!) == "42")
        #expect(try unsafe await asynchronous.unsafeInvoke(on: second!, "value:") == "value:42")
        second = nil
        #expect(try unsafe await bound!.unsafeInvoke("bound:") == "bound:42")
        bound = nil
        withExtendedLifetime((consuming, asynchronous)) { #expect(observedSecond == nil) }
        let incompatible = try asynchronous.bind(to: GenericReceiver(ReceiverText(text: "different")))
        await #expect(throws: ABIInvocationError.self) { try unsafe await incompatible.unsafeInvoke("") }
    }

    @MainActor @Test(arguments: [false, true])
    func concreteMembersUseLiveGenericContext(_ inherited: Bool) async throws {
        let receiver: GenericReceiver<ReceiverNumber> = inherited
            ? InheritedGenericReceiver(.init(number: 42)) : GenericReceiver(.init(number: 42))
        let runtime = ABIRuntime()
        let object = runtime.object(receiver)
        let method = try await object.resolve(.method("title(_:)", as: ((String) -> String).self))
        let complete = try await object.resolve(
            .method(
                "title(Swift.String) -> Swift.String",
                as: ((String) -> String).self
            )
        )
        let get = try await object.resolve(.getter("text", as: (() -> String).self))
        let fullGet = try await object.resolve(
            .getter(
                "text.getter : Swift.String",
                as: (() -> String).self
            )
        )
        let set = try await object.resolve(.setter("text", as: ((String) -> Void).self))
        receiver.text = "!"
        #expect(receiver.text == "42!")
        try unsafe set.unsafeInvoke("?")
        runtime.removeCachedResults()
        for prefix in ["", String(repeating: "prefix", count: 100)] {
            let expected = receiver.title(prefix)
            #expect(try unsafe method.unsafeInvoke(prefix) == expected)
            #expect(try unsafe complete.unsafeInvoke(prefix) == expected)
        }
        #expect(try unsafe get.unsafeInvoke() == receiver.text)
        #expect(try unsafe fullGet.unsafeInvoke() == receiver.text)
    }

    @MainActor @Test func specializationsKeepSeparateMetadataAndReleaseReceivers() async throws {
        let runtime = ABIRuntime()
        weak var first: GenericReceiver<ReceiverNumber>?
        weak var second: GenericReceiver<ReceiverText>?
        var handles: [NativeBoundSwiftMethod<() -> String>] = []
        do {
            let a = GenericReceiver(ReceiverNumber(number: 42))
            let b = GenericReceiver(ReceiverText(text: String(repeating: "text", count: 100)))
            first = a
            second = b
            #expect(a.consumeTitle() == "42")
            #expect(b.consumeTitle() == String(repeating: "text", count: 100))
            for object: AnyObject in [a, b] {
                handles.append(
                    try await runtime.object(object).resolve(
                        .method(
                            "consumeTitle()",
                            as: (() -> String).self,
                            receiver: .consuming
                        )
                    )
                )
            }
        }
        runtime.removeCachedResults()
        #expect(first != nil && second != nil)
        #expect(try unsafe handles[0].unsafeInvoke() == "42")
        #expect(try unsafe handles[1].unsafeInvoke() == String(repeating: "text", count: 100))
        handles.removeAll()
        #expect(first == nil && second == nil)
    }

    @MainActor @Test func effectsUseExistingMethodTransports() async throws {
        let receiver = GenericReceiver(ReceiverNumber(number: 42))
        let object = ABIRuntime.shared.object(receiver)
        let throwing = try await object.resolve(
            .method(
                "throwingTitle(_:)",
                as: ((Bool) throws -> String).self
            )
        )
        #expect(try unsafe throwing.unsafeInvoke(false) == receiver.throwingTitle(false))
        #expect(throws: (any Error).self) { try unsafe throwing.unsafeInvoke(true) }
        let asyncMethod = try await object.resolve(
            .method(
                "asyncTitle(_:)",
                as: ((String) async -> String).self
            )
        )
        let expected = await receiver.asyncTitle("value:")
        #expect(try await unsafe asyncMethod.unsafeInvoke("value:") == expected)
    }

    @MainActor @Test func completeDependentSignaturesUseExplicitFormalABIAdapters() async throws {
        let value = ReceiverText(text: String(repeating: "owned", count: 100))
        let receiver = GenericReceiver(value)
        let object = ABIRuntime.shared.object(receiver)
        let projected = try await object.resolve(
            .method("projected() -> A", as: (() -> ReceiverText).self)
        )
        let echo = try await object.resolve(
            .method(
                "echo(A) -> A",
                as: ((ReceiverText) -> ReceiverText).self
            )
        )
        let getter = try await object.resolve(
            .getter("payload.getter : A", as: (() -> ReceiverText).self)
        )
        #expect(try unsafe projected.unsafeInvoke().text == receiver.projected().text)
        #expect(try unsafe echo.unsafeInvoke(value).text == receiver.echo(value).text)
        #expect(try unsafe getter.unsafeInvoke().text == receiver.payload.text)
    }

    @MainActor @Test func dependentAndIndependentGenericsKeepAdapterBoundary() async throws {
        let object = ABIRuntime.shared.object(GenericReceiver(ReceiverNumber(number: 42)))
        do {
            _ = try await object.resolve(.method("projected()", as: (() -> Int).self))
            Issue.record("Dependent result unexpectedly inferred a concrete ABI")
        } catch ABIResolutionError.declarationNotFound {}
        do {
            _ = try await object.resolve(
                .method("independent<A>(A1) -> A1", as: ((Int) -> Int).self)
            )
            Issue.record("Independent generic metadata was not supplied")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.expected == "1 generic arguments")
        }
    }
}
