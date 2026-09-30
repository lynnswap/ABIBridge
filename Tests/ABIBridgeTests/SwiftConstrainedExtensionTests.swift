import ABIBridge
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
    @inline(never) @_optimize(none) func choice() -> String { "supported" }
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
extension ConstrainedPair where Second: CustomStringConvertible {
    @inline(never) @_optimize(none) func choice() -> String { "requires witness" }
}
extension ConstrainedPair where First: Sequence, First.Element == Int {
    @inline(never) @_optimize(none) func associated() -> String { "associated" }
}
extension ConstrainedPair where Second == [First] {
    @inline(never) @_optimize(none) func substituted() -> String { "substituted" }
}
extension ConstrainedPair where First == (A: Int, other: String) {
    @inline(never) @_optimize(none) func tupleLabels() -> String { "tuple labels" }
}
extension ConstrainedPair where First: CustomStringConvertible, Second == Int {
    @inline(never) @_optimize(none) func mixed() -> String { "mixed" }
}

private class ConstraintParent: NSObject {
    @inline(never) @_optimize(none) func inheritedChoice() -> String { "parent" }
}
private final class ConstraintChild<Value>: ConstraintParent {}
extension ConstraintChild where Value: CustomStringConvertible {
    @inline(never) @_optimize(none) func inheritedChoice() -> String { "requires witness" }
}

private struct ConstrainedOuter<First> {
    final class Inner<Second> {}
}
extension ConstrainedOuter.Inner where First == Int, Second == String {
    @inline(never) @_optimize(none) func nested() -> String { "nested" }
}

struct SwiftConstrainedExtensionTests {
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
        let tuple = ConstrainedPair<(A: Int, other: String), Bool>()
        let inputs: [(AnyObject, String, String)] = [
            (pair, "partial()", pair.partial()),
            (equal, "equal()", equal.equal()),
            (nested, "nested()", nested.nested()),
            (compound, "compound()", compound.compound()),
            (tuple, "tupleLabels()", tuple.tupleLabels()),
        ]
        for (receiver, member, expected) in inputs {
            let method = try await runtime.object(receiver).method(named: member, as: (() -> String).self)
            #expect(try unsafe method.unsafeInvoke() == expected)
        }
    }

    @MainActor @Test func mismatchedConstraintsRemainAbsent() async throws {
        let inputs: [(AnyObject, String)] = [
            (ConstrainedBox(1.5), "title(_:)"),
            (ConstrainedPair<Int, String>(), "equal()"),
            (ConstrainedOuter<String>.Inner<Int>(), "nested()"),
            (ConstrainedPair<String, String>(), "mixed()"),
            (ConstrainedPair<(A: Double, other: String), Bool>(), "tupleLabels()"),
        ]
        for (receiver, member) in inputs {
            do {
                if member == "title(_:)" {
                    _ = try await ABIRuntime().object(receiver).method(named: member, as: ((String) -> String).self)
                } else {
                    _ = try await ABIRuntime().object(receiver).method(named: member, as: (() -> String).self)
                }
                Issue.record("An inapplicable constrained member was selected")
            } catch ABIResolutionError.declarationNotFound {}
        }
    }

    @MainActor @Test func unestablishedConstraintsReportAdapterRequirement() async throws {
        #expect(ConstrainedBox(42).needsWitness() == "42")
        #expect(ConstrainedPair<[Int], String>().associated() == "associated")
        #expect(ConstrainedPair<Int, [Int]>().substituted() == "substituted")
        let inputs: [(AnyObject, String)] = [
            (ConstrainedBox(42), "needsWitness()"),
            (ConstrainedPair<[Int], String>(), "associated()"),
            (ConstrainedPair<Int, [Int]>(), "substituted()"),
        ]
        for (receiver, member) in inputs {
            do {
                _ = try await ABIRuntime().object(receiver).method(named: member, as: (() -> String).self)
                Issue.record("An unsupported constraint was accepted without an adapter")
            } catch ABIResolutionError.unsupportedDeclaration {}
        }
    }

    @MainActor @Test func supportedCandidatesAndSuperclassMembersRemainSelectable() async throws {
        let runtime = ABIRuntime()
        let receiver = ConstrainedPair<Int, String>()
        let choice = try await runtime.object(receiver).method(named: "choice()", as: (() -> String).self)
        #expect(try unsafe choice.unsafeInvoke() == "supported")
        let child = ConstraintChild<Int>()
        let inherited = try await runtime.object(child).method(named: "inheritedChoice()", as: (() -> String).self)
        #expect(try unsafe inherited.unsafeInvoke() == "parent")
        await runtime.removeCachedResults()
        let repeated = try await runtime.object(receiver).method(named: "choice()", as: (() -> String).self)
        #expect(try unsafe repeated.unsafeInvoke() == "supported")
    }

    @Test func supportedExtensionInAnotherImageRemainsSelectable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let module = "ConstraintLookupProvider"
        let provider = try FixtureLibrary(swiftModule: module, swiftSource: """
            import Foundation
            public final class Pair<First, Second>: NSObject {}
            extension Pair where Second: CustomStringConvertible {
                public func choice() -> String { "requires witness" }
            }
            @_cdecl("ABIConstraintInstance") public func make() -> UnsafeMutableRawPointer {
                Unmanaged.passRetained(Pair<Int, String>()).toOpaque()
            }
            """, linkArguments: ["-emit-module", "-emit-module-path", directory.appendingPathComponent(module + ".swiftmodule").path])
        defer { provider.cleanup() }
        let runtime = ABIRuntime()
        let make = try await runtime.cFunction(named: "ABIConstraintInstance", as: (() -> UnsafeMutableRawPointer).self,
            in: .path(provider.libraryURL), loading: .loadedOnly)
        let receiver = Unmanaged<AnyObject>.fromOpaque(try unsafe make.unsafeInvoke()).takeRetainedValue()
        let object = runtime.object(receiver)
        do {
            _ = try await object.method(named: "choice()", as: (() -> String).self)
            Issue.record("An unsupported declaration was accepted before loading its supported alternative")
        } catch ABIResolutionError.unsupportedDeclaration {}
        let alternative = try FixtureLibrary(swiftModule: "ConstraintLookupExtension", swiftSource: """
            import \(module)
            extension Pair where First == Int {
                public func choice() -> String { "supported image" }
            }
            """, linkArguments: ["-I", directory.path, provider.libraryURL.path])
        defer { alternative.cleanup() }
        let choice = try await object.method(named: "choice()", as: (() -> String).self)
        #expect(try unsafe choice.unsafeInvoke() == "supported image")
    }

    @Test func moduleNamesAndDependentMembersKeepTheirDistinctMeaning() async throws {
        let fixture = try FixtureLibrary(swiftModule: "A", swiftSource: """
            import Foundation
            public protocol LeafSource { associatedtype Leaf }
            public struct Point: LeafSource { public typealias Leaf = Int }
            public protocol P { associatedtype Value: LeafSource }
            public struct Source: P { public typealias Value = Point }
            public struct Value { public struct Leaf {} }
            public struct ValueQz {}
            public final class Box<Content>: NSObject {}
            extension Box where Content == (Value, Int) {
                public func concrete() -> String { "concrete" }
            }
            extension Box where Content == (ValueQz, Int) {
                public func concrete() -> String { "concrete" }
            }
            extension Box where Content == (Value.Leaf, Int) {
                public func concrete() -> String { "concrete" }
            }
            public final class Pair<First: P, Second>: NSObject {}
            extension Pair where Second == First.Value {
                public func projected() -> String { "unsupported" }
                @_silgen_name("$s1A4PairCAAx5ValueQxRs_rlE8relativeSSyF")
                public func relative() -> String { "unsupported" }
            }
            extension Pair where Second == (First.Value, Int) {
                public func projected() -> String { "unsupported" }
            }
            extension Pair where Second == First.Value.Leaf {
                public func projected() -> String { "unsupported" }
                @_silgen_name("$s1A4PairCAAx5Value_4LeafQXRs_rlE13relativeChainSSyF")
                public func relativeChain() -> String { "unsupported" }
            }
            public final class ReversedPair<First, Second: P>: NSObject {}
            extension ReversedPair where First == Second.Value {
                public func projected() -> String { "unsupported" }
            }
            @_cdecl("ABIAmbiguousConstraintInstance") public func make(_ kind: Int32) -> UnsafeMutableRawPointer {
                let value: NSObject
                switch kind {
                case 0: value = Box<(Value, Int)>()
                case 1: value = Box<(ValueQz, Int)>()
                case 2: value = Box<(Value.Leaf, Int)>()
                case 3: value = Pair<Source, Value>()
                case 4: value = Pair<Source, (Value, Int)>()
                case 5: value = Pair<Source, Value.Leaf>()
                default: value = ReversedPair<Value, Source>()
                }
                return Unmanaged.passRetained(value).toOpaque()
            }
            """)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let make = try await runtime.cFunction(named: "ABIAmbiguousConstraintInstance", as: ((Int32) -> UnsafeMutableRawPointer).self,
            in: .path(fixture.libraryURL), loading: .loadedOnly)
        for kind: Int32 in 0..<7 {
            let receiver = Unmanaged<AnyObject>.fromOpaque(try unsafe make.unsafeInvoke(kind)).takeRetainedValue()
            if kind < 3 {
                let method = try await runtime.object(receiver).method(named: "concrete()", as: (() -> String).self)
                #expect(try unsafe method.unsafeInvoke() == "concrete")
            } else {
                do {
                    _ = try await runtime.object(receiver).method(named: "projected()", as: (() -> String).self)
                    Issue.record("A dependent member was mistaken for a concrete module type")
                } catch ABIResolutionError.unsupportedDeclaration {}
                if kind == 3 || kind == 5 {
                    do {
                        _ = try await runtime.object(receiver).method(named: kind == 3 ? "relative()" : "relativeChain()",
                            as: (() -> String).self)
                        Issue.record("An equivalent relative-base mangling bypassed the adapter requirement")
                    } catch ABIResolutionError.unsupportedDeclaration {}
                }
            }
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
