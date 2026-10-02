#if DEBUG
@testable import ABIBridge
import ABIBridgeCore
import ManagedSwiftFixtures
import Testing

struct SwiftGenericBindingTests {
    @Test func tupleClosureAuthenticationMatchesCompilerLowering() throws {
        let signature = try SwiftFunctionSignature((((String, Int8)) -> (String, Int8, Int8)).self)
        #expect(try signature.closureDiscriminator() == 3335)
        #expect(swiftClosureDiscriminator(parameters: ["-indirect", "$ss4Int8V"],
            results: ["-indirect", "$ss4Int8V", "$ss4Int8V"]) == 8528)
        #expect(swiftClosureDiscriminator(parameters: ["-"], results: ["-indirect"]) == 47754)
        #expect(try SwiftFunctionSignature(((LargeManagedValue) -> LargeManagedValue).self).closureDiscriminator() == 55683)
    }

    @Test func collectionSugarMatchesRuntimeAndToolchainDemanglers() {
        let nominal = "Example.map<A, B>(Swift.Array<A>, (A) -> B) -> Swift.Dictionary<Swift.String, Swift.Optional<B>>"
        let sugared = "Example.map<A, B>([A], (A) -> B) -> [Swift.String: B?]"
        #expect(DeclarationKey.make(nominal, language: .swift) == DeclarationKey.make(sugared, language: .swift))
        #expect(DeclarationKey.make(nominal, language: .cxx) != DeclarationKey.make(sugared, language: .cxx))
        #expect(DeclarationKey.make("Example.Swift.Array<A>", language: .swift) != DeclarationKey.make("Example.[A]", language: .swift))
    }

    @Test func multipleParametersAndConditionalConformancesBindWithoutAdapters() throws {
        let declaration = try SwiftGenericDeclaration(
            "Example.select<A, B where A: Swift.Equatable, B: Swift.Collection, B.Element == A>(A, B) -> A")
        let signature = try SwiftFunctionSignature(((String, [String]) -> String).self)
        let binding = try SwiftGenericBinding(declaration: declaration,
            arguments: [.type(String.self), .type([String].self)],
            signature: signature, resolver: .shared)
        #expect(binding.metadataArguments.count == 4)
        #expect(try binding.types(.named("B.Element", []))[0] == String.self)
        try binding.validate([String].self, for: .named("Swift.Array", [.named("A", [])]))

        let conditional = try SwiftGenericBinding(
            declaration: SwiftGenericDeclaration("Example.echo<A where A: Swift.Equatable>(A) -> A"),
            arguments: [.type([String].self)],
            signature: SwiftFunctionSignature((([String]) -> [String]).self), resolver: .shared)
        #expect(conditional.metadataArguments.count == 2)

        #expect(throws: ABIResolutionError.self) {
            try SwiftGenericBinding(declaration: declaration,
                arguments: [.type(Int.self), .type([String].self)],
                signature: signature, resolver: .shared)
        }
    }

    @Test func canonicalDeclarationsPreserveDependentTypesEffectsAndPacks() throws {
        let transform = try SwiftGenericDeclaration(
            "GenericEvidence.transform<A, B>([A], (A) -> B) -> [B]")
        #expect(transform.parameters.map(\.name) == ["A", "B"])
        #expect(transform.arguments[0] == .named("Swift.Array", [.named("A", [])]))
        #expect(transform.arguments[1] == .function([.named("A", [])], .named("B", []), failure: nil, isAsync: false))
        #expect(transform.result == .named("Swift.Array", [.named("B", [])]))

        let member = try SwiftGenericDeclaration(
            "GenericEvidence.Container<A>.method<A1>(A1) async throws(A1) -> (A, A1)")
        #expect(member.parameters.map(\.name) == ["A", "A1"])
        #expect(member.result == .tuple([.named("A", []), .named("A1", [])]))
        #expect(member.failure == .named("A1", []))
        #expect(member.isAsync)

        let pack = try SwiftGenericDeclaration(
            "GenericEvidence.constrainedPack<each A where A: Swift.Equatable>(repeat A) -> (repeat A)")
        #expect(pack.parameters.count == 1 && pack.parameters[0].isPack)
        #expect(pack.arguments == [.pack(.named("A", []))])
        #expect(pack.result == .tuple([.pack(.named("A", []))]))
        #expect(pack.requirements.count == 1)

        let dependent = try SwiftGenericDeclaration(
            "GenericEvidence.dependentTwo<A, B where A: Swift.Collection, B == A.Element>(A, B) -> B")
        #expect(dependent.requirements.count == 2)
        let labeled = try SwiftGenericDeclaration(
            "GenericEvidence.apply<A, B>(input: Swift.Dictionary<A, B>, transform: (A, B) throws -> B) rethrows -> Swift.Dictionary<A, B>")
        #expect(labeled.arguments.count == 2)
        #expect(labeled.failure == .named("Swift.Error", []))
    }

    @Test func runtimeMetadataAndWitnessOperationsMatchCompilerTypes() async throws {
        let runtime = ABIRuntime.shared
        let array = try await runtime.resolve(.init(
            name: "nominal type descriptor for Swift.Array", language: .swift, kind: .data))
        let metadata = unsafeBitCast(String.self, to: UnsafeRawPointer.self)
        let actual = unsafe array.withUnsafeAddress { descriptor in
            [Optional(metadata)].withUnsafeBufferPointer {
                ABISwiftGenericTypeMetadata(descriptor, $0.baseAddress)
            }
        }
        #expect(try #require(actual) == unsafeBitCast([String].self, to: UnsafeRawPointer.self))

        let equatable = try await runtime.resolve(.init(
            name: "protocol descriptor for Swift.Equatable", language: .swift, kind: .data))
        let witness = unsafe equatable.withUnsafeAddress {
            ABISwiftConformance(metadata, $0)
        }
        #expect(witness != nil)
        #expect(ABISwiftConformanceDescriptor(try #require(witness)) != nil)

        let collection = try await runtime.resolve(.init(
            name: "protocol descriptor for Swift.Collection", language: .swift, kind: .data))
        let element = unsafe collection.withUnsafeAddress { descriptor in
            "Element".withCString {
                ABISwiftAssociatedType(unsafeBitCast([String].self, to: UnsafeRawPointer.self), descriptor, $0)
            }
        }
        #expect(element == metadata)
        let missing = unsafe collection.withUnsafeAddress { descriptor in
            "Missing".withCString {
                ABISwiftAssociatedType(unsafeBitCast([String].self, to: UnsafeRawPointer.self), descriptor, $0)
            }
        }
        #expect(missing == nil)
    }
}

#endif
