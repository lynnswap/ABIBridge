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
extension ConstrainedPair where First: Hashable, Second == [First: Int] {
    @inline(never) @_optimize(none) func dictionary() -> String { "dictionary" }
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
    private struct DeclaredFailure: Error, Equatable { let value: Int }

    @Test func canonicalDeclarationsPreserveProviderImportBoundaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseModule = "DeclaredBaseProvider"
        let conformanceModule = "DeclaredConformanceProvider"
        let base = try FixtureLibrary(swiftModule: baseModule, swiftSource: """
            public protocol Score { static func score() -> Int }
            open class Base { public init() {} }
            """, linkArguments: ["-emit-module", "-emit-module-path", directory.appendingPathComponent(baseModule + ".swiftmodule").path])
        defer { base.cleanup() }
        let conformance = try FixtureLibrary(swiftModule: conformanceModule, swiftSource: """
            import \(baseModule)
            extension Base: @retroactive Score { public static func score() -> Int { 42 } }
            """, linkArguments: ["-I", directory.path, base.libraryURL.path, "-emit-module", "-emit-module-path",
                                  directory.appendingPathComponent(conformanceModule + ".swiftmodule").path])
        defer { conformance.cleanup() }
        let runtime = ABIRuntime()
        let baseType = try await runtime.swiftType(named: baseModule + ".Base", in: .path(base.libraryURL))
        for importsConformance in [false, true] {
            let module = importsConformance ? "DeclaredWithProvider" : "DeclaredWithoutProvider"
            let provider = try FixtureLibrary(swiftModule: module, swiftSource: """
                import \(baseModule)
                \(importsConformance ? "import " + conformanceModule : "")
                public final class ObjectBox<Value: Score> { public init() {} }
                extension ObjectBox where Value: Base {
                    public static func score() -> Int { Value.score() }
                    public func entry<Failure: Error>(_ error: Failure, _ shouldThrow: Bool) throws(Failure) -> Int {
                        if shouldThrow { throw error }
                        return Value.score()
                    }
                }
                public struct Box<Value: Score> {}
                extension Box where Value: Base {
                    public static func entry<Failure: Error>(_ error: Failure, _ shouldThrow: Bool) throws(Failure) -> Int {
                        if shouldThrow { throw error }
                        return Value.score()
                    }
                    public static var score: Int { Value.score() }
                }
                """, linkArguments: ["-I", directory.path, base.libraryURL.path]
                    + (importsConformance ? [conformance.libraryURL.path] : []))
            defer { provider.cleanup() }
            let objectType = try await runtime.swiftType(named: module + ".ObjectBox", in: .path(provider.libraryURL), genericArguments: [.type(baseType)])
            let classScore = try await objectType.staticMethod(named: "score()", as: (() -> Int).self)
            #expect(try unsafe classScore.unsafeInvoke() == 42)
            let initialize = try await objectType.initializer(named: "init()", as: (() -> AnyObject).self)
            let object = try unsafe initialize.unsafeInvoke()
            let classEntry = try await runtime.object(object).method(named: "entry(_:_:)",
                as: ((DeclaredFailure, Bool) throws(DeclaredFailure) -> Int).self,
                genericArguments: [.type(DeclaredFailure.self)])
            #expect(try unsafe classEntry.unsafeInvoke(DeclaredFailure(value: 38), false) == 42)
            do {
                _ = try unsafe classEntry.unsafeInvoke(DeclaredFailure(value: 38), true)
                Issue.record("The class member's typed error was not thrown")
            } catch let error as NativeSwiftError {
                #expect(error.withUnderlyingError { ($0 as? DeclaredFailure) == DeclaredFailure(value: 38) })
            }
            let box = try await runtime.swiftType(named: module + ".Box", in: .path(provider.libraryURL), genericArguments: [.type(baseType)])
            do {
                _ = try await box.staticMethod(named: "entry(_:_:)", as: ((DeclaredFailure, Bool) throws(DeclaredFailure) -> Int).self,
                    genericArguments: [.type(DeclaredFailure.self)])
                Issue.record("A provider-dependent witness convention was inferred from runtime conformance availability")
            } catch ABIResolutionError.unsupportedDeclaration(let reason) {
                #expect(reason.contains("declaredAs:"))
            }
            let witness = importsConformance ? "" : ", A: " + baseModule + ".Score"
            let prefix = "<A, A1 where A: " + baseModule + ".Base" + witness + ", A1: Swift.Error> "
            let entry = try await box.staticMethod(named: "entry(_:_:)",
                as: ((DeclaredFailure, Bool) throws(DeclaredFailure) -> Int).self,
                genericArguments: [.type(DeclaredFailure.self)],
                declaredAs: prefix + "(A1, Swift.Bool) throws(A1) -> Swift.Int")
            #expect(try unsafe entry.unsafeInvoke(DeclaredFailure(value: 37), false) == 42)
            do {
                _ = try unsafe entry.unsafeInvoke(DeclaredFailure(value: 37), true)
                Issue.record("The typed provider error was not thrown")
            } catch let error as NativeSwiftError {
                #expect(error.withUnderlyingError { ($0 as? DeclaredFailure) == DeclaredFailure(value: 37) })
            }
            let getter = try await box.staticGetter(named: "score", as: (() -> Int).self,
                declaredAs: "<A where A: " + baseModule + ".Base" + witness + "> () -> Swift.Int")
            #expect(try unsafe getter.unsafeInvoke() == 42)
        }
    }

    @Test func qualifiedExternalExtensionsNormalizeCollectionSpellings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let module = "QualifiedCollectionProvider"
        let provider = try FixtureLibrary(swiftModule: module, swiftSource: """
            public final class Box<Value> { public init() {} }
            @_cdecl("ABIQualifiedCollectionBox") public func make() -> UnsafeMutableRawPointer {
                Unmanaged.passRetained(Box<String>()).toOpaque()
            }
            """, linkArguments: ["-emit-module", "-emit-module-path", directory.appendingPathComponent(module + ".swiftmodule").path])
        defer { provider.cleanup() }
        let extensionImage = try FixtureLibrary(swiftModule: "QualifiedCollectionExtension", swiftSource: """
            import \(module)
            extension Box {
                public func echo(_ values: [Value]) -> [Value] { values }
                public var empty: [Value] { [] }
            }
            """, linkArguments: ["-I", directory.path, provider.libraryURL.path])
        defer { extensionImage.cleanup() }
        let runtime = ABIRuntime()
        let make = try await runtime.cFunction(named: "ABIQualifiedCollectionBox", as: (() -> UnsafeMutableRawPointer).self,
            in: .path(provider.libraryURL), loading: .loadedOnly)
        let object = runtime.object(Unmanaged<AnyObject>.fromOpaque(try unsafe make.unsafeInvoke()).takeRetainedValue())
        let method = try await object.method(named: module + ".Box.echo(Swift.Array<A>) -> Swift.Array<A>",
            as: (([String]) -> [String]).self)
        #expect(try unsafe method.unsafeInvoke(["external"]) == ["external"])
        let getter = try await object.getter(named: module + ".Box.empty.getter : Swift.Array<A>",
            as: (() -> [String]).self)
        #expect(try unsafe getter.unsafeInvoke().isEmpty)
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
        let getter = try await runtime.object(number).getter(named: "number", as: (() -> Int).self)
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

    @MainActor @Test func dependentConstraintsUseRuntimeConformancesAndSubstitution() async throws {
        #expect(ConstrainedBox(42).needsWitness() == "42")
        #expect(ConstrainedPair<[Int], String>().associated() == "associated")
        #expect(ConstrainedPair<Int, [Int]>().substituted() == "substituted")
        #expect(ConstrainedPair<String, [String: Int]>().dictionary() == "dictionary")
        let inputs: [(AnyObject, String, String)] = [
            (ConstrainedBox(42), "needsWitness()", "42"),
            (ConstrainedPair<[Int], String>(), "associated()", "associated"),
            (ConstrainedPair<Int, [Int]>(), "substituted()", "substituted"),
            (ConstrainedPair<String, [String: Int]>(), "dictionary()", "dictionary"),
        ]
        for (receiver, member, expected) in inputs {
            let method = try await ABIRuntime().object(receiver).method(named: member, as: (() -> String).self)
            #expect(try unsafe method.unsafeInvoke() == expected)
        }
    }

    @MainActor @Test func supportedCandidatesAndSuperclassMembersRemainSelectable() async throws {
        let runtime = ABIRuntime()
        let receiver = ConstrainedPair<Int, String>()
        do {
            _ = try await runtime.object(receiver).method(named: "choice()", as: (() -> String).self)
            Issue.record("Both applicable constraints must remain ambiguous")
        } catch let ABIResolutionError.ambiguousDeclaration(_, candidates) {
            #expect(candidates.count == 2)
        }
        let child = ConstraintChild<Int>()
        let inherited = try await runtime.object(child).method(named: "inheritedChoice()", as: (() -> String).self)
        #expect(try unsafe inherited.unsafeInvoke() == "requires witness")
        await runtime.removeCachedResults()
        do {
            _ = try await runtime.object(receiver).method(named: "choice()", as: (() -> String).self)
            Issue.record("Both applicable constraints must remain ambiguous after clearing caches")
        } catch ABIResolutionError.ambiguousDeclaration {}

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
        let original = try await object.method(named: "choice()", as: (() -> String).self)
        #expect(try unsafe original.unsafeInvoke() == "requires witness")
        let alternative = try FixtureLibrary(swiftModule: "ConstraintLookupExtension", swiftSource: """
            import \(module)
            extension Pair where First == Int {
                public func choice() -> String { "supported image" }
            }
            """, linkArguments: ["-I", directory.path, provider.libraryURL.path])
        defer { alternative.cleanup() }
        do {
            _ = try await object.method(named: "choice()", as: (() -> String).self)
            Issue.record("Applicable extensions in separate images must remain ambiguous")
        } catch ABIResolutionError.ambiguousDeclaration {}
    }

    @Test func genericParameterMetatypesBindThroughTheirReceiverContext() async throws {
        let fixture = try FixtureLibrary(swiftModule: "A", swiftSource: """
            import Foundation
            public struct Type {}
            public struct MetatypeWrapper<Value> {}
            public final class MetatypePair<First, Second>: NSObject {}
            extension MetatypePair where Second == First.Type {
                public func metatype() -> String { "bound" }
            }
            extension MetatypePair where Second == (First.Type, Int) {
                public func tuple() -> String { "bound" }
            }
            extension MetatypePair where Second == First.Type? {
                public func optional() -> String { "bound" }
            }
            extension MetatypePair where Second == First.Type.Type {
                public func nested() -> String { "bound" }
            }
            extension MetatypePair where First == Second.Type {
                public func reversed() -> String { "bound" }
            }
            extension MetatypePair where Second == MetatypeWrapper<First.Type> {
                public func wrapped() -> String { "bound" }
            }
            public final class MetatypeBox<Content>: NSObject {}
            extension MetatypeBox where Content == (Type, Int) {
                public func concrete() -> String { "concrete" }
            }
            public final class MetatypeTriple<First, Second, Third>: NSObject {}
            extension MetatypeTriple where Second == (Type, Int), Third == First.Type {
                public func mixed() -> String { "bound" }
            }
            public struct MetatypeOuter<First> { public final class Inner<Second>: NSObject {} }
            extension MetatypeOuter.Inner where Second == First.Type {
                public func metatype() -> String { "bound" }
            }
            @_cdecl("ABIMetatypeConstraintInstance") public func make(_ kind: Int32) -> UnsafeMutableRawPointer {
                let value: AnyObject
                switch kind {
                case 0: value = MetatypePair<Int, Int.Type>()
                case 1: value = MetatypePair<Int, (Int.Type, Int)>()
                case 2: value = MetatypePair<Int, Int.Type?>()
                case 3: value = MetatypePair<Int, Int.Type.Type>()
                case 4: value = MetatypePair<Int.Type, Int>()
                case 5: value = MetatypeBox<(Type, Int)>()
                case 6: value = MetatypeTriple<Int, (String, Int), Int.Type>()
                case 7: value = MetatypeTriple<Int, (Type, Int), Int.Type>()
                case 9: value = MetatypePair<Int, MetatypeWrapper<Int.Type>>()
                default: value = MetatypeOuter<Int>.Inner<Int.Type>()
                }
                return Unmanaged.passRetained(value).toOpaque()
            }
            """)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let make = try await runtime.cFunction(named: "ABIMetatypeConstraintInstance", as: ((Int32) -> UnsafeMutableRawPointer).self,
            in: .path(fixture.libraryURL), loading: .loadedOnly)
        let members = ["metatype()", "tuple()", "optional()", "nested()", "reversed()", "concrete()", "mixed()", "mixed()", "metatype()", "wrapped()"]
        for (kind, member) in members.enumerated() {
            let receiver = Unmanaged<AnyObject>.fromOpaque(try unsafe make.unsafeInvoke(Int32(kind))).takeRetainedValue()
            if kind == 5 {
                let method = try await runtime.object(receiver).method(named: member, as: (() -> String).self)
                #expect(try unsafe method.unsafeInvoke() == "concrete")
            } else if kind == 6 {
                do {
                    _ = try await runtime.object(receiver).method(named: member, as: (() -> String).self)
                    Issue.record("An unrelated metatype constraint hid a proven mismatch")
                } catch ABIResolutionError.declarationNotFound {}
            } else {
                let method = try await runtime.object(receiver).method(named: member, as: (() -> String).self)
                #expect(try unsafe method.unsafeInvoke() == "bound")
            }
        }
    }

    @Test func moduleNamesAndDependentMembersKeepTheirDistinctMeaning() async throws {
        let fixture = try FixtureLibrary(swiftModule: "A", swiftSource: """
            import Foundation
            public protocol LeafSource { associatedtype Leaf }
            public struct Point: LeafSource { public typealias Leaf = Int }
            public protocol P { associatedtype Value: LeafSource; associatedtype 🍎 }
            public struct Source: P { public typealias Value = Point; public typealias 🍎 = Int }
            public struct Value { public struct Leaf {} }
            public struct ValueQz {}
            public struct 🍎 {}
            public struct Wrapper<Content> {}
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
            extension Box where Content == (🍎, Int) {
                public func concrete() -> String { "concrete" }
            }
            public final class Pair<First: P, Second>: NSObject {}
            extension Pair where Second == First.Value {
                public func projected() -> String { "bound" }
                @_silgen_name("$s1A4PairCAAx5ValueQxRs_rlE8relativeSSyF")
                public func relative() -> String { "bound" }
            }
            extension Pair where Second == First.🍎 {
                public func unicodeProjection() -> String { "bound" }
            }
            extension Pair where Second == (First.Value, Int) {
                public func projected() -> String { "bound" }
            }
            extension Pair where Second == First.Value.Leaf {
                public func projected() -> String { "bound" }
                @_silgen_name("$s1A4PairCAAx5Value_4LeafQXRs_rlE13relativeChainSSyF")
                public func relativeChain() -> String { "bound" }
            }
            extension Pair where Second == Wrapper<First.Value> {
                public func wrapped() -> String { "bound" }
            }
            extension Pair where Second == Wrapper<Wrapper<First.Value?>> {
                public func wrapped() -> String { "bound" }
            }
            public final class ReversedPair<First, Second: P>: NSObject {}
            extension ReversedPair where First == Second.Value {
                public func projected() -> String { "bound" }
            }
            public final class Triplet<First: P, Second, Third>: NSObject {}
            extension Triplet where Second == (Value, Int), Third == First.Value {
                public func mixed() -> String { "bound" }
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
                case 7: value = Triplet<Source, (String, Int), Int>()
                case 8: value = Triplet<Source, (Value, Int), Int>()
                case 9: value = Box<(🍎, Int)>()
                case 10: value = Pair<Source, Wrapper<Value>>()
                case 11: value = Pair<Source, Wrapper<Point>>()
                case 12: value = Pair<Source, Wrapper<Wrapper<Value?>>>()
                case 13: value = Pair<Source, Point>()
                case 14, 19: value = Pair<Source, Int>()
                case 15: value = Pair<Source, (Point, Int)>()
                case 16: value = ReversedPair<Point, Source>()
                case 17: value = Triplet<Source, (Value, Int), Point>()
                case 18: value = Pair<Source, Wrapper<Wrapper<Point?>>>()
                default: value = ReversedPair<Value, Source>()
                }
                return Unmanaged.passRetained(value).toOpaque()
            }
            """)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let make = try await runtime.cFunction(named: "ABIAmbiguousConstraintInstance", as: ((Int32) -> UnsafeMutableRawPointer).self,
            in: .path(fixture.libraryURL), loading: .loadedOnly)
        for kind: Int32 in 0..<20 {
            let receiver = Unmanaged<AnyObject>.fromOpaque(try unsafe make.unsafeInvoke(kind)).takeRetainedValue()
            if kind < 3 || kind == 9 {
                let method = try await runtime.object(receiver).method(named: "concrete()", as: (() -> String).self)
                #expect(try unsafe method.unsafeInvoke() == "concrete")
            } else if kind >= 13 || kind == 11 {
                let member = kind == 17 ? "mixed()" : kind == 18 || kind == 11 ? "wrapped()"
                    : kind == 19 ? "unicodeProjection()" : "projected()"
                let method = try await runtime.object(receiver).method(named: member, as: (() -> String).self)
                #expect(try unsafe method.unsafeInvoke() == "bound")
                if kind == 13 || kind == 14 {
                    let relative = try await runtime.object(receiver).method(
                        named: kind == 13 ? "relative()" : "relativeChain()", as: (() -> String).self)
                    #expect(try unsafe relative.unsafeInvoke() == "bound")
                }
            } else {
                if kind == 7 {
                    do {
                        _ = try await runtime.object(receiver).method(named: "mixed()", as: (() -> String).self)
                        Issue.record("A proven mismatch was hidden by another requirement's dependent type")
                    } catch ABIResolutionError.declarationNotFound {}
                    continue
                }
                do {
                    let member = kind == 8 ? "mixed()" : kind >= 10 ? "wrapped()" : "projected()"
                    _ = try await runtime.object(receiver).method(named: member, as: (() -> String).self)
                    Issue.record("A dependent member was mistaken for a concrete module type")
                } catch ABIResolutionError.declarationNotFound {}
                if kind == 3 || kind == 5 {
                    do {
                        _ = try await runtime.object(receiver).method(named: kind == 3 ? "relative()" : "relativeChain()",
                            as: (() -> String).self)
                        Issue.record("An equivalent relative-base mangling bypassed the adapter requirement")
                    } catch ABIResolutionError.declarationNotFound {}
                }
                if kind == 3 {
                    do {
                        _ = try await runtime.object(receiver).method(named: "unicodeProjection()", as: (() -> String).self)
                        Issue.record("A Unicode associated-type name bypassed the adapter requirement")
                    } catch ABIResolutionError.declarationNotFound {}
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
        var method: NativeBoundSwiftMethod<(String) -> String>?
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
