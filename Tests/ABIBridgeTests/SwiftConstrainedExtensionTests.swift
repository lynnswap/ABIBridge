@testable import ABIBridge
import Foundation
import Testing

private class ConstrainedBox<Value>: NSObject {
    var value: Value
    init(_ value: Value) { self.value = value }
}
private final class ConstrainedChild: ConstrainedBox<Int> {}

// Preserve private entry points for lookup in optimized fixtures.
extension ConstrainedBox where Value == Int {
    @inline(never) @_optimize(none) func title(_ prefix: String) -> String { prefix + String(value) }
    var number: Int {
        @inline(never) @_optimize(none) get { value }
        @inline(never) @_optimize(none) set { value = newValue }
    }
}
extension ConstrainedBox where Value == String {
    @inline(never) @_optimize(none) func title(_ prefix: String) -> String { prefix + value }
}
extension ConstrainedBox where Value: CustomStringConvertible {
    @inline(never) @_optimize(none) func needsWitness() -> String { value.description }
}

private final class ConstrainedPair<First, Second> {}
extension ConstrainedPair where First == Int {
    @inline(never) @_optimize(none) func partial() -> String { "partial" }
    @inline(never) @_optimize(none) func overlap() -> String { "first" }
}
extension ConstrainedPair where Second == String {
    @inline(never) @_optimize(none) func overlap() -> String { "second" }
}
extension ConstrainedPair where First == Second {
    @inline(never) @_optimize(none) func equal() -> String { "equal" }
}
extension ConstrainedPair where First == (Int) -> String, Second == (Int, String) {
    @inline(never) @_optimize(none) func compound() -> String { "compound" }
}

private struct ConstrainedOuter<First> {
    final class Inner<Second> {}
}
extension ConstrainedOuter.Inner where First == Int, Second == String {
    @inline(never) @_optimize(none) func nested() -> String { "nested" }
}

struct SwiftConstrainedExtensionTests {
    @Test func importedSuperclassHasNoSwiftNominalDescriptor() throws {
        let superclass = try #require(class_getSuperclass(ConstrainedBox<Int>.self))
        #expect(ObjectIdentifier(superclass) == ObjectIdentifier(NSObject.self))
        #expect(try SwiftClassDispatch.nominalDescriptor(of: superclass) == nil)
        #expect(try SwiftClassDispatch.nominalDescriptor(of: ConstrainedBox<Int>.self) != nil)
    }

    @MainActor @Test(arguments: [false, true])
    func selectsConstraintUsingLiveReceiverAndSuperclass(_ inherited: Bool) async throws {
        let runtime = ABIRuntime()
        let number: ConstrainedBox<Int> = inherited ? ConstrainedChild(42) : ConstrainedBox(42)
        let text = ConstrainedBox(String(repeating: "text", count: 100))
        do {
            _ = try await runtime.object(ConstrainedBox(1.5)).method(named: "title(_:)", as: ((String) -> String).self)
            Issue.record("A mismatched specialization resolved")
        } catch ABIResolutionError.declarationNotFound {}
        let numberMethod = try await runtime.object(number).method(named: "title(_:)", as: ((String) -> String).self)
        let textMethod = try await runtime.object(text).method(named: "title(_:)", as: ((String) -> String).self)
        #expect(try unsafe numberMethod.unsafeInvoke("number:") == number.title("number:"))
        #expect(try unsafe textMethod.unsafeInvoke("text:") == text.title("text:"))
        let getter = try await runtime.object(number).getter(named: "number", as: Int.self)
        let setter = try await runtime.object(number).setter(named: "number", as: Int.self)
        number.number = 43
        #expect(number.number == 43)
        try unsafe setter.unsafeInvoke(44)
        #expect(try unsafe getter.unsafeInvoke() == number.number)
        await runtime.removeCachedResults()
        #expect(try unsafe numberMethod.unsafeInvoke("") == "44")
        #expect(try unsafe textMethod.unsafeInvoke("") == text.value)
    }

    @MainActor @Test func partialEqualNestedAndCompoundConstraints() async throws {
        let runtime = ABIRuntime()
        let pair = ConstrainedPair<Int, String>()
        let equal = ConstrainedPair<String, String>()
        let nested = ConstrainedOuter<Int>.Inner<String>()
        let compound = ConstrainedPair<(Int) -> String, (Int, String)>()
        let inputs: [(AnyObject, String, String)] = [
            (pair, "partial()", pair.partial()),
            (equal, "equal()", equal.equal()),
            (nested, "nested()", nested.nested()),
            (compound, "compound()", compound.compound()),
        ]
        for (receiver, member, expected) in inputs {
            let method = try await runtime.object(receiver).method(named: member, as: (() -> String).self)
            #expect(try unsafe method.unsafeInvoke() == expected)
        }
    }

    @MainActor @Test func rejectsMismatchedAndUnestablishedWitnessConstraints() async throws {
        let inputs: [(AnyObject, String)] = [
            (ConstrainedBox(1.5), "title(_:)"),
            (ConstrainedPair<Int, String>(), "equal()"),
            (ConstrainedOuter<String>.Inner<Int>(), "nested()"),
            (ConstrainedBox(42), "needsWitness()"),
        ]
        for (receiver, member) in inputs {
            do {
                if member == "title(_:)" {
                    _ = try await ABIRuntime().object(receiver).method(named: member, as: ((String) -> String).self)
                } else {
                    _ = try await ABIRuntime().object(receiver).method(named: member, as: (() -> String).self)
                }
                Issue.record("An inapplicable or unsupported constrained member was selected")
            } catch ABIResolutionError.declarationNotFound {}
        }
    }

    @MainActor @Test func applicableOverlappingExtensionsRemainAmbiguous() async throws {
        #expect(ConstrainedPair<Int, Bool>().overlap() == "first")
        #expect(ConstrainedPair<Bool, String>().overlap() == "second")
        do {
            _ = try await ABIRuntime().object(ConstrainedPair<Int, String>()).method(
                named: "overlap()", as: (() -> String).self
            )
            Issue.record("Multiple applicable extensions were silently ordered")
        } catch let ABIResolutionError.ambiguousDeclaration(_, candidates) {
            #expect(candidates.count == 2)
        }
    }

    @MainActor @Test func boundConstraintRetainsReceiverUntilFinalRelease() async throws {
        let runtime = ABIRuntime()
        weak var observed: ConstrainedBox<String>?
        var method: NativeBoundSwiftMethod<String, String>?
        do {
            let receiver = ConstrainedBox(String(repeating: "retained", count: 100))
            observed = receiver
            #expect(receiver.title("") == receiver.value)
            method = try await runtime.object(receiver).method(named: "title(_:)", as: ((String) -> String).self)
        }
        await runtime.removeCachedResults()
        #expect(observed != nil)
        #expect(try unsafe method!.unsafeInvoke("") == String(repeating: "retained", count: 100))
        method = nil
        #expect(observed == nil)
    }
}
