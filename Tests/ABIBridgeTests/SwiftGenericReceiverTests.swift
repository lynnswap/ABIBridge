import ABIBridge
import Foundation
import Testing

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

// Keep the private generic entry points in optimized tests. Without this,
// specialization removes their unspecialized symbols or changes ownership.
private class GenericReceiver<Value: ReceiverMetric>: NSObject {
    let value: Value
    var suffix = ""
    init(_ value: Value) { self.value = value }
    @inline(never) @_optimize(none) func title(_ prefix: String) -> String { prefix + value.text + suffix }
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
private final class InheritedGenericReceiver: GenericReceiver<ReceiverNumber> {}
private enum ReceiverFailure: Error { case rejected }

struct SwiftGenericReceiverTests {
    @MainActor @Test(arguments: [false, true])
    func concreteMembersUseLiveGenericContext(_ inherited: Bool) async throws {
        let receiver: GenericReceiver<ReceiverNumber> = inherited
            ? InheritedGenericReceiver(.init(number: 42)) : GenericReceiver(.init(number: 42))
        let runtime = ABIRuntime()
        let object = runtime.object(receiver)
        let method = try await object.method(named: "title(_:)", as: ((String) -> String).self)
        let complete = try await object.method(named: "title(Swift.String) -> Swift.String", as: ((String) -> String).self)
        let get = try await object.getter(named: "text", as: String.self)
        let fullGet = try await object.getter(named: "text.getter : Swift.String", as: String.self)
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
        var handles: [NativeBoundSwiftMethod<String>] = []
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
        let getter = try await object.getter(named: "payload.getter : A", as: ReceiverText.self)
        #expect(try unsafe projected.unsafeInvoke().text == receiver.projected().text)
        #expect(try unsafe echo.unsafeInvoke(value).text == receiver.echo(value).text)
        #expect(try unsafe getter.unsafeInvoke().text == receiver.payload.text)
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
