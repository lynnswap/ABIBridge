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
    @MainActor @Test func unsupportedOverloadsDoNotHideUsableMembers() async throws {
        let runtime = ABIRuntime()
        for receiver in [GenericReceiver(ReceiverNumber(number: 42)),
                         InheritedGenericReceiver(ReceiverNumber(number: 43))] {
            let object = runtime.object(receiver)
            let read = try await object.method(named: "read(_:)", as: ((Int64) -> Int64).self)
            #expect(try unsafe read.unsafeInvoke(41) == receiver.read(Int64(41)))
            let extensionRead = try await object.method(named: "read(_:)", as: ((Double) -> Double).self)
            #expect(try unsafe extensionRead.unsafeInvoke(40) == receiver.read(Double(40)))
            do {
                _ = try await object.method(named: "unsupportedRead(_:)", as: ((String) -> String).self)
                Issue.record("Expected the unsupported candidate's preparation error")
            } catch ABIResolutionError.unsupportedDeclaration(let reason) {
                #expect(reason.contains("OpaqueReturnType"))
            }
        }
    }

    @MainActor @Test func completeMemberDeclarationsPreserveConcreteAdapters() async throws {
        let runtime = ABIRuntime()
        let receiver = GenericReceiver(ReceiverNumber(number: 42))
        let object = runtime.object(receiver)
        let name = "throwingTitle(Swift.Bool) throws -> Swift.String"
        let method = try await object.method(named: name, as: ((ReceiverBoolAdapter) throws -> String).self)
        #expect(try unsafe method.unsafeInvoke(ReceiverBoolAdapter(false)) == "42")
        do {
            _ = try unsafe method.unsafeInvoke(ReceiverBoolAdapter(true))
            Issue.record("Expected the concrete native error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is ReceiverFailure })
        }
        let qualified = try await object.method(named: method.method.symbol.declaration.name,
            as: ((ReceiverBoolAdapter) throws -> String).self)
        #expect(try unsafe qualified.unsafeInvoke(ReceiverBoolAdapter(false)) == "42")
        let borrowed = try await object.method(named: name,
            as: ((NativeSwiftBorrowing<ReceiverBoolAdapter>) throws -> String).self)
        #expect(try unsafe borrowed.unsafeInvoke(.init(ReceiverBoolAdapter(false))) == "42")
        for invalidName in ["throwingTitle(_:)", "throwingTitle(Swift.String) throws -> Swift.String"] {
            do {
                _ = try await object.method(named: invalidName, as: ((ReceiverBoolAdapter) throws -> String).self)
                Issue.record("An adapter must use the selected native declaration's concrete type")
            } catch ABIResolutionError.declarationNotFound {}
        }
        do {
            _ = try await object.method(named: "echo(A) -> A", as: ((ReceiverBoolAdapter) -> ReceiverBoolAdapter).self)
            Issue.record("A dependent argument must still use its bound Swift type")
        } catch ABIResolutionError.declarationNotFound {}
    }

    @Test func completeInitializersAndAccessorsPreserveConcreteAdapters() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericEffectfulGetter",
            genericArguments: [.type(String.self), .type(GenericGetterFailure.self)])
        let initialize = try await type.initializer(
            named: "init(A, B, Swift.Bool) -> ManagedSwiftFixtures.GenericEffectfulGetter<A, B>",
            as: ((String, GenericGetterFailure, ReceiverBoolAdapter) -> GenericEffectfulGetter<String, GenericGetterFailure>).self)
        let receiver = try unsafe initialize.unsafeInvoke("adapter", GenericGetterFailure(1), ReceiverBoolAdapter(false))
        let object = runtime.object(receiver)
        let getter = try await object.getter(named: "shouldThrow.getter : Swift.Bool", as: (() -> ReceiverBoolAdapter).self)
        let setter = try await object.setter(named: "shouldThrow.setter : Swift.Bool", as: ReceiverBoolAdapter.self)
        #expect(try unsafe getter.unsafeInvoke().value == false)
        try unsafe setter.unsafeInvoke(ReceiverBoolAdapter(true))
        let updated = try unsafe getter.unsafeInvoke()
        #expect(receiver.shouldThrow && updated.value)
    }

    @MainActor @Test func concreteMemberArgumentsKeepTheirBorrowingMarkers() async throws {
        let receiver = GenericReceiver(ReceiverNumber(number: 42))
        let method = try await ABIRuntime().object(receiver).method(named: "title(_:)",
            as: ((NativeSwiftBorrowing<String>) -> String).self)
        #expect(try unsafe method.unsafeInvoke(.init("borrowed:")) == receiver.title("borrowed:"))
    }

    @MainActor @Test func effectfulGenericGettersUseTheDeclaredErrorConvention() async throws {
        let runtime = ABIRuntime()
        let owner = GenericEffectfulGetter("getter", GenericGetterFailure(42), false)
        let object = runtime.object(owner)
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericEffectfulGetter",
            genericArguments: [.type(String.self), .type(GenericGetterFailure.self)])
        let checked = try await object.getter(named: "checked",
            as: (() throws(GenericGetterFailure) -> String).self, declaredAs: "() throws(B) -> A")
        let fixed = try await type.getter(named: "fixedFailure",
            as: (() throws(GenericGetterFailure) -> String).self,
            declaredAs: "() throws(ManagedSwiftFixtures.GenericGetterFailure) -> A")
        let delayed = try await object.getter(named: "delayed", as: (() async -> String).self)
        let delayedChecked = try await object.getter(named: "delayedChecked",
            as: (() async throws(GenericGetterFailure) -> String).self, declaredAs: "() async throws(B) -> A")
        let number = try await object.getter(named: "checkedNumber", as: (() throws(GenericGetterFailure) -> Int64).self,
            declaredAs: "() throws(B) -> Swift.Int64")
        let fixedNumber = try await object.getter(named: "fixedNumber", as: (() throws(GenericGetterFailure) -> Int64).self,
            declaredAs: "() throws(ManagedSwiftFixtures.GenericGetterFailure) -> Swift.Int64")
        let delayedNumber = try await object.getter(named: "delayedNumber", as: (() async throws(GenericGetterFailure) -> Int64).self,
            declaredAs: "() async throws(B) -> Swift.Int64")
        let delayedFixedNumber = try await object.getter(named: "delayedFixedNumber", as: (() async throws(GenericGetterFailure) -> Int64).self,
            declaredAs: "() async throws(ManagedSwiftFixtures.GenericGetterFailure) -> Swift.Int64")
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
        let staticGetter = try await type.staticGetter(named: "checkedType",
            as: (() throws(GenericGetterFailure) -> String.Type).self, declaredAs: "() throws(B) -> A.Type")
        let asyncStaticGetter = try await type.staticGetter(named: "delayedType",
            as: (() async throws(GenericGetterFailure) -> String.Type).self, declaredAs: "() async throws(B) -> A.Type")
        #expect(try unsafe staticGetter.unsafeInvoke() == String.self)
        #expect(try unsafe await asyncStaticGetter.unsafeInvoke() == String.self)
        do {
            _ = try await object.getter(named: "checked", as: (() throws(GenericGetterFailure) -> String).self)
            Issue.record("The formal error cannot be inferred from the bound error type")
        } catch ABIResolutionError.unsupportedDeclaration {}
    }
    @MainActor @Test(arguments: [false, true])
    func dependentMembersAndIndependentParametersUseRawSwiftValues(_ inherited: Bool) async throws {
        let receiver: GenericReceiver<ReceiverNumber> = inherited
            ? InheritedGenericReceiver(.init(number: 42)) : GenericReceiver(.init(number: 42))
        let object = ABIRuntime().object(receiver)
        let projected = try await object.method(named: "projected()", as: (() -> ReceiverNumber).self)
        let echo = try await object.method(named: "echo(_:)", as: ((ReceiverNumber) -> ReceiverNumber).self)
        let getter = try await object.getter(named: "payload", as: (() -> ReceiverNumber).self)
        let independent = try await object.method(named: "independent(_:)",
            as: ((String) -> String).self, genericArguments: [.type(String.self)])
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
            consuming = try await runtime.object(original).method(
                named: "consumeTitle()", as: (() -> String).self, consuming: true
            ).method
            asynchronous = try await runtime.object(original).method(
                named: "asyncTitle(_:)", as: ((String) async -> String).self
            ).method
        }
        await runtime.removeCachedResults()
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
        let method = try await object.method(named: "title(_:)", as: ((String) -> String).self)
        let complete = try await object.method(named: "title(Swift.String) -> Swift.String", as: ((String) -> String).self)
        let get = try await object.getter(named: "text", as: (() -> String).self)
        let fullGet = try await object.getter(named: "text.getter : Swift.String", as: (() -> String).self)
        let set = try await object.setter(named: "text", as: String.self)
        receiver.text = "!"
        #expect(receiver.text == "42!")
        try unsafe set.unsafeInvoke("?")
        await runtime.removeCachedResults()
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
                handles.append(try await runtime.object(object).method(
                    named: "consumeTitle()", as: (() -> String).self, consuming: true
                ))
            }
        }
        await runtime.removeCachedResults()
        #expect(first != nil && second != nil)
        #expect(try unsafe handles[0].unsafeInvoke() == "42")
        #expect(try unsafe handles[1].unsafeInvoke() == String(repeating: "text", count: 100))
        handles.removeAll()
        #expect(first == nil && second == nil)
    }

    @MainActor @Test func effectsUseExistingMethodTransports() async throws {
        let receiver = GenericReceiver(ReceiverNumber(number: 42))
        let object = ABIRuntime().object(receiver)
        let throwing = try await object.method(named: "throwingTitle(_:)", as: ((Bool) throws -> String).self)
        #expect(try unsafe throwing.unsafeInvoke(false) == receiver.throwingTitle(false))
        #expect(throws: (any Error).self) { try unsafe throwing.unsafeInvoke(true) }
        let asyncMethod = try await object.method(named: "asyncTitle(_:)", as: ((String) async -> String).self)
        let expected = await receiver.asyncTitle("value:")
        #expect(try await unsafe asyncMethod.unsafeInvoke("value:") == expected)
    }

    @MainActor @Test func completeDependentSignaturesUseExplicitFormalABIAdapters() async throws {
        let value = ReceiverText(text: String(repeating: "owned", count: 100))
        let receiver = GenericReceiver(value)
        let object = ABIRuntime().object(receiver)
        let projected = try await object.method(named: "projected() -> A", as: (() -> ReceiverText).self)
        let echo = try await object.method(named: "echo(A) -> A", as: ((ReceiverText) -> ReceiverText).self)
        let getter = try await object.getter(named: "payload.getter : A", as: (() -> ReceiverText).self)
        #expect(try unsafe projected.unsafeInvoke().text == receiver.projected().text)
        #expect(try unsafe echo.unsafeInvoke(value).text == receiver.echo(value).text)
        #expect(try unsafe getter.unsafeInvoke().text == receiver.payload.text)
    }

    @Test(arguments: [
        "async.f<A where A: async.P>(A) -> A",
        "throws.f<A where A: throws.P>(A) -> A",
        "Example.(Private in _ABCD).f<A where A: async.P>(A) -> A",
        "Example.(Private in _ABCD).f<A where A: throws.P>(A) async throws -> A",
    ])
    func genericRequirementsDoNotBecomeFunctionEffects(_ declaration: String) async throws {
        do {
            _ = try await ABIRuntime().swiftFunction(
                named: declaration, as: ((Int) async throws -> Int).self
            )
            Issue.record("Generic metadata and witnesses were not supplied")
        } catch ABIResolutionError.unsupportedDeclaration {}
    }

    @MainActor @Test func dependentAndIndependentGenericsKeepAdapterBoundary() async throws {
        let object = ABIRuntime().object(GenericReceiver(ReceiverNumber(number: 42)))
        do {
            _ = try await object.method(named: "projected()", as: (() -> Int).self)
            Issue.record("Dependent result unexpectedly inferred a concrete ABI")
        } catch ABIResolutionError.declarationNotFound {}
        do {
            _ = try await object.method(named: "independent<A>(A1) -> A1", as: ((Int) -> Int).self)
            Issue.record("Independent generic metadata was not supplied")
        } catch ABIResolutionError.unsupportedDeclaration {}
    }
}
