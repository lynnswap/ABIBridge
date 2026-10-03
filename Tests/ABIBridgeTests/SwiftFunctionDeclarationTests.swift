#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import Foundation
import ManagedSwiftFixtures
import Testing

struct SwiftFunctionDeclarationTests {
    @Test func arrowOperatorsResolveByLabelsAndCompleteDeclarations() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.ArrowOperatorValue")
        let generic = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericOperatorBox",
            genericArguments: [.type(Int64.self)])
        let first = ArrowOperatorValue(35), second = ArrowOperatorValue(7)
        let genericFirst = GenericOperatorBox<Int64>(35), genericSecond = GenericOperatorBox<Int64>(7)
        for operation in ["-->", "->>"] {
            let expected = operation == "-->" ? (Int64(35) --> Int64(7)) : (Int64(35) ->> Int64(7))
            let function = try await runtime.swiftFunction(named: "ManagedSwiftFixtures." + operation + "(_:_:)",
                as: ((Int64, Int64) -> Int64).self)
            #expect(try unsafe function.unsafeInvoke(35, 7) == expected)
            let complete = try await runtime.swiftFunction(
                named: "ManagedSwiftFixtures." + operation + " infix(Swift.Int64, Swift.Int64) -> Swift.Int64",
                as: ((Int64, Int64) -> Int64).self, in: function.symbol.image)
            #expect(try unsafe complete.unsafeInvoke(35, 7) == expected)
            let method = try await type.staticMethod(named: operation + "(_:_:)",
                as: ((ArrowOperatorValue, ArrowOperatorValue) -> Int64).self)
            let memberControl = operation == "-->" ? (first --> second) : (first ->> second)
            #expect(try unsafe method.unsafeInvoke(first, second) == memberControl)
            let genericMethod = try await generic.staticMethod(named: operation + "(_:_:)",
                as: ((GenericOperatorBox<Int64>, GenericOperatorBox<Int64>) -> Int64).self)
            let genericControl = operation == "-->" ? (genericFirst --> genericSecond) : (genericFirst ->> genericSecond)
            #expect(try unsafe genericMethod.unsafeInvoke(genericFirst, genericSecond) == genericControl)
        }
    }

    @Test func compiledGenericFunctionTypesRequireAdapters() async throws {
        let variants = [("use", ""), ("throwing", " throws"),
                        ("asynchronous", " async"), ("asyncThrowing", " async throws")]
        let module = "GenericArrowFixture"
        let source = "public protocol HasCallback { associatedtype Callback }\n" + variants.map { name, effects in
            """
            public func \(name)<Value: HasCallback>(_ value: Value)\(effects) -> String
                where Value.Callback == (Int) -> String { "unused" }
            """
        }.joined(separator: "\n")
        let fixture = try FixtureLibrary(swiftModule: module, swiftSource: source)
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        for (name, effects) in variants {
            let declaration = "\(module).\(name)<A where A: \(module).HasCallback, A.Callback == (Swift.Int) -> Swift.String>(A)\(effects) -> Swift.String"
            // Establish that the complete spelling identifies an actual compiler
            // symbol before testing rejection at the invocation boundary.
            _ = try await runtime.resolve(.init(name: declaration, language: .swift),
                in: .path(fixture.libraryURL), loading: .loadedOnly)
            do {
                _ = try await runtime.swiftFunction(named: declaration, as: ((Int) -> String).self,
                    in: .path(fixture.libraryURL), loading: .loadedOnly)
                Issue.record("A generic declaration was prepared without metadata or witnesses")
            } catch ABIResolutionError.unsupportedDeclaration {}
            do {
                _ = try await runtime.swiftFunction(named: declaration, as: ((Int) async throws -> String).self,
                    in: .path(fixture.libraryURL), loading: .loadedOnly)
                Issue.record("Matching effects bypassed the generic adapter requirement")
            } catch ABIResolutionError.unsupportedDeclaration {}
        }
    }

    @Test(arguments: ["async", "throws", "async throws"])
    func constrainedClosureTypesDoNotHideOuterEffects(_ effects: String) async throws {
        let declaration = "(extension in Example):Example.Box<A where A == (Swift.Int) -> Swift.String>.value() \(effects) -> Swift.String"
        do {
            _ = try await ABIRuntime().swiftFunction(named: declaration, as: (() -> String).self)
            Issue.record("An outer effect was accepted by a synchronous nonthrowing metatype")
        } catch ABIResolutionError.unsupportedDeclaration {}
    }

    #if DEBUG
    @Test func functionMetadataPreservesTheCompleteSignature() throws {
        enum Failure: Error { case expected }
        let synchronous = try SwiftFunctionSignature(((Int64, String) throws(Failure) -> String).self)
        #expect(synchronous.parameters.elementsEqual([Int64.self, String.self], by: { $0 == $1 }))
        #expect(synchronous.result == String.self && synchronous.failure == Failure.self)
        #expect(!synchronous.isAsync)

        let caller = try SwiftFunctionSignature((nonisolated(nonsending) @Sendable () async throws -> Void).self)
        #expect(caller.parameters.isEmpty && caller.result == Void.self)
        #expect(caller.failure == (any Error).self && caller.isAsync && caller.inheritsCallerIsolation)

        let concurrent = try SwiftFunctionSignature((@concurrent (String) async -> Int64).self)
        #expect(concurrent.parameters.elementsEqual([String.self], by: { $0 == $1 }) && concurrent.result == Int64.self)
        #expect(concurrent.failure == Never.self && concurrent.isAsync && !concurrent.inheritsCallerIsolation)
    }

    @Test(arguments: [
        "Example.use<A where A.Callback == (Swift.Int) -> Swift.String>(A) async throws -> Swift.String",
        "Example.use<A where A.Callback == Swift.Array<(Swift.Int) -> Swift.String>>(A) async throws -> Swift.String",
        "(extension in Example):Example.Box<A where A == (Swift.Int) -> Swift.String>.value() async throws -> Swift.String",
    ])
    func genericRequirementArrowsKeepTheOuterResult(_ declaration: String) {
        let signature = swiftOuterSignature(declaration)
        #expect(signature.result?.trimmingCharacters(in: .whitespaces) == "Swift.String")
        #expect(signature.text.trimmingCharacters(in: .whitespaces).hasSuffix("async throws"))
    }

    @Test(arguments: ["<", "<<", "<>", ">", "-->", "->>"])
    func operatorNamesDoNotHideOuterEffects(_ name: String) throws {
        let declaration = "static Example.Value.\(name) infix(Example.Value, Example.Value) async throws -> Swift.Bool"
        let signature = swiftOuterSignature(declaration)
        #expect(signature.result?.trimmingCharacters(in: .whitespaces) == "Swift.Bool")
        #expect(throws: ABIResolutionError.self) {
            try swiftFunctionDeclaration(named: declaration, as: ((Int, Int) -> Bool).self)
        }
    }

    @Test(arguments: [
        "Example.apply((Swift.Int) async throws -> Swift.String) -> Swift.String",
        "Example.factory() -> (Swift.Int) async throws -> Swift.String",
        "Example.😀<A where A.Callback == (Swift.Int) -> Swift.String>(A) async throws -> Swift.String",
    ])
    func closureArrowsKeepTheFirstOuterResult(_ declaration: String) {
        let signature = swiftOuterSignature(declaration)
        let expected = declaration.contains("factory") ? "(Swift.Int) async throws -> Swift.String" : "Swift.String"
        #expect(signature.result?.trimmingCharacters(in: .whitespaces) == expected)
    }

    @Test(arguments: [
        "Example.apply((Swift.Int) async throws -> Swift.String) -> Swift.String",
        "Example.factory() -> (Swift.Int) async throws -> Swift.String",
        "(extension in Example):Example.Box<A where A == (Swift.Int) -> Swift.String>.value() -> Swift.String",
    ])
    func innerClosureEffectsDoNotRejectSynchronousDeclarations(_ declaration: String) throws {
        let parsed = try swiftFunctionDeclaration(named: declaration, as: (() -> String).self)
        #expect(parsed.name == declaration)
    }
    #endif
}
