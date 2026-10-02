#if DEBUG
@testable import ABIBridge
import ABIBridgeCore
import ManagedSwiftFixtures
import Testing

struct SwiftGenericBindingTests {
    @Test func syntaxPreservesGenericDepthWithoutPrintedParameterNames() throws {
        let node: SwiftSyntax.Node
        do {
            let syntax = try SwiftSyntax(symbol: "$s20ManagedSwiftFixtures15GenericValueBoxV7checked_4failxqd___Sbtqd__YKs5ErrorRd__lF")
            node = try #require(syntax.root.child(kind: "Function")?.child(kind: "Type")?
                .child(kind: "DependentGenericType")?.child(kind: "Type")?
                .child(kind: "FunctionType")?.child(kind: "TypedThrowsAnnotation")?
                .child(kind: "DependentGenericParamType"))
        }
        #expect(node.children().compactMap(\.index) == [1, 0])
        #expect(try node.name() == "A1")
        #expect(throws: ABIResolutionError.self) { try SwiftSyntax(symbol: "not a Swift symbol") }
    }

    @Test func syntaxReadsSymbolicNominalFieldReferencesAtTheirOriginalAddress() throws {
        let metadata = unsafeBitCast(ResilientRecord.self, to: UnsafeRawPointer.self)
        let handle = try #require(ABICopySwiftTypeFieldSyntax(metadata, 0))
        let syntax = SwiftSyntax(adopting: handle)
        let reference = try #require(syntax.root.child(kind: "TypeSymbolicReference"))
        let descriptor = try #require(ABISwiftTypeDescriptor(unsafeBitCast(ManagedRecord.self, to: UnsafeRawPointer.self)))
        #expect(reference.index == UInt64(UInt(bitPattern: descriptor)))
    }

    @Test func genericClassInitializersPropertiesAndMethodsShareBinding() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.GenericTypeClass",
            genericArguments: [.type(String.self)])
        let initialize = try await type.initializer(
            named: "init(_:)",
            as: ((String) -> GenericTypeClass<String>).self)
        let receiver = try unsafe initialize.unsafeInvoke(String(repeating: "initial", count: 20))
        let get = try await type.getter(named: "value", as: (() -> String).self)
        let set = try await type.setter(named: "value", as: String.self)
        let identity = try await type.staticMethod(named: "identity(_:)", as: ((String) -> String).self)
        let compare = try await type.method(named: "compare(_:)",
            as: ((Int) -> (String, Int, Bool)).self, genericArguments: [.type(Int.self)])
        #expect(try unsafe get.unsafeInvoke(on: receiver) == receiver.value)
        try unsafe set.unsafeInvoke(on: receiver, String(repeating: "updated", count: 20))
        #expect(receiver.value == String(repeating: "updated", count: 20))
        #expect(try unsafe identity.unsafeInvoke("static") == "static")
        let result = try unsafe compare.unsafeInvoke(on: receiver, 42)
        #expect(result.0 == receiver.value && result.1 == 42 && result.2)
    }

    @Test func nominalContextsPreserveParameterDepthAndAssociatedConstraints() throws {
        let collection = try SwiftGenericTypeContext(metadata: GenericTypeCollection<[String]>.self)
        #expect(collection.parameters.map(\.name) == ["A"])
        #expect(collection.keyParameters == ["A"])
        #expect(collection.conformances.map { $0.subject.spelling + ": " + $0.name }.sorted()
            == ["A.Element: Swift.Equatable", "A: Swift.Collection"])
        let nested = try SwiftGenericTypeContext(
            metadata: GenericTypeOuter<[String]>.Inner<String>.Constrained<Bool>.self)
        #expect(nested.parameters.map(\.name) == ["A", "A1", "A2"])
        #expect(nested.keyParameters == ["A", "A1", "A2"])
        #expect(nested.conformances.contains { $0.subject.spelling == "A1" && $0.name == "Swift.Equatable" })
        let related = try SwiftGenericTypeContext(metadata: GenericTypeRelated<[String], String>.self)
        #expect(related.parameters.map(\.name) == ["A", "B"])
        #expect(related.keyParameters == ["A", "B"])
        let recursive = try SwiftGenericTypeContext(metadata: GenericRecursive<GenericLeaf>.self)
        #expect(recursive.conformances.map { $0.subject.spelling + ": " + $0.name }.sorted()
            == ["A.Child.Child: Swift.Equatable", "A: ManagedSwiftFixtures.GenericTree"])
        let pack = try SwiftGenericTypeContext(metadata: GenericTypePack<String, Int>.self)
        #expect(pack.parameters.count == 1 && pack.parameters[0].isPack)
        #expect(pack.conformances.first?.name == "Swift.Equatable")
    }
    @Test func nominalMetadataUsesRuntimeConstraintsAndCanonicalIdentity() async throws {
        let runtime = ABIRuntime()
        func packMetadata<each Value>(_ types: repeat (each Value).Type) -> Any.Type where repeat each Value: Equatable {
            GenericTypePack<repeat each Value>.self
        }
        let cases: [(String, [NativeSwiftGenericArgument], Any.Type)] = [
            ("Swift.Array", [.type(String.self)], [String].self),
            ("Swift.Dictionary", [.type(String.self), .type([Int].self)], [String: [Int]].self),
            ("ManagedSwiftFixtures.GenericRecord", [.type(ConditionalMetric<ManagedRecord>.self)],
             GenericRecord<ConditionalMetric<ManagedRecord>>.self),
            ("ManagedSwiftFixtures.GenericTypeClass", [.type([String].self)], GenericTypeClass<[String]>.self),
            ("ManagedSwiftFixtures.GenericTypeDerived", [.type(String.self)], GenericTypeDerived<String>.self),
            ("ManagedSwiftFixtures.GenericTypeEnum", [.type(String.self)], GenericTypeEnum<String>.self),
            ("ManagedSwiftFixtures.GenericTypeCollection", [.type([String].self)], GenericTypeCollection<[String]>.self),
            ("ManagedSwiftFixtures.GenericTypeRelated", [.type([String].self), .type(String.self)],
             GenericTypeRelated<[String], String>.self),
            ("ManagedSwiftFixtures.GenericTypeOuter.Inner", [.type(Bool.self), .type(Double.self)],
             GenericTypeOuter<Bool>.Inner<Double>.self),
            ("ManagedSwiftFixtures.GenericTypeOuter.FixedInner", [.type(Bool.self)],
             GenericTypeOuter<Bool>.FixedInner.self),
            ("ManagedSwiftFixtures.GenericTypeOuter.InExtension", [.type(Bool.self), .type(Double.self)],
             GenericTypeOuter<Bool>.InExtension<Double>.self),
            ("ManagedSwiftFixtures.GenericTypeOuter.Inner.Constrained",
             [.type([String].self), .type(String.self), .type(Bool.self)],
             GenericTypeOuter<[String]>.Inner<String>.Constrained<Bool>.self),
            ("ManagedSwiftFixtures.GenericTypeNamespace.Member", [.type(String.self)],
             GenericTypeNamespace.Member<String>.self),
            ("ManagedSwiftFixtures.GenericTypePack", [.pack([.type(String.self), .type(Int.self)])],
             GenericTypePack<String, Int>.self),
            ("ManagedSwiftFixtures.GenericTypePack", [.pack([])], packMetadata()),
            ("ManagedSwiftFixtures.GenericTypeMixedPack", [.type(Bool.self), .pack([.type(String.self), .type(Int.self)])],
             GenericTypeMixedPack<Bool, String, Int>.self)
        ]
        for (name, arguments, expected) in cases {
            let type = try await runtime.swiftType(named: name, genericArguments: arguments)
            let metadata = await type.metadata
            #expect(ObjectIdentifier(metadata) == ObjectIdentifier(expected), "\(name)")
            let again = try await runtime.swiftType(named: name, in: type.image, genericArguments: arguments)
            #expect(type === again)
            var failure: OpaquePointer?
            let copy = ABICopySwiftTypeMetadata(unsafeBitCast(expected, to: UnsafeRawPointer.self), &failure)
            defer { if let failure { ABIReleaseResolutionFailure(failure) } }
            let recovered = try #require(copy, "\(name)")
            defer { ABIReleaseSwiftTypeMetadata(recovered) }
            #expect(ABISwiftTypeMetadataArgumentCount(recovered) == arguments.count)
            for (index, argument) in arguments.enumerated() {
                let elements: [NativeSwiftGenericArgument]
                switch argument.storage {
                case .type:
                    #expect(!ABISwiftTypeMetadataArgumentIsPack(recovered, index))
                    elements = [argument]
                case .pack(let pack):
                    #expect(ABISwiftTypeMetadataArgumentIsPack(recovered, index))
                    elements = pack
                }
                #expect(ABISwiftTypeMetadataArgumentElementCount(recovered, index) == elements.count)
                for (element, expected) in elements.enumerated() {
                    guard case .type(let type, _) = expected.storage else { continue }
                    #expect(ABISwiftTypeMetadataArgumentElement(recovered, index, element)
                        == unsafeBitCast(type, to: UnsafeRawPointer.self))
                }
            }
        }
        let first = try await runtime.swiftType(named: "Swift.Array", genericArguments: [.type(String.self)])
        let second = try await runtime.swiftType(named: "Swift.Array", genericArguments: [.type(Int.self)])
        let firstMetadata = await first.metadata
        let secondMetadata = await second.metadata
        #expect(first !== second && firstMetadata != secondMetadata)
    }

    @Test func invalidNominalArgumentsFailWithoutEnteringAnInvalidAccessor() async throws {
        let runtime = ABIRuntime()
        let cases: [(String, [NativeSwiftGenericArgument])] = [
            ("Swift.Array", []),
            ("Swift.Array", [.pack([.type(String.self)])]),
            ("Swift.Array", [.type(Int.self), .type(String.self)]),
            ("Swift.Int", [.type(Int.self)]),
            ("ManagedSwiftFixtures.GenericTypeCollection", [.type(Int.self)]),
            ("ManagedSwiftFixtures.GenericRecord", [.type(String.self)]),
            ("ManagedSwiftFixtures.GenericTypeRelated", [.type([String].self), .type(Int.self)]),
            ("ManagedSwiftFixtures.GenericTypePack", [.type(Int.self)]),
            ("ManagedSwiftFixtures.GenericTypePack", [.pack([.type(LifetimeToken.self)])]),
            ("ManagedSwiftFixtures.GenericTypePack", [.pack([.pack([])])])
        ]
        for (name, arguments) in cases {
            await #expect(throws: ABIResolutionError.self) {
                _ = try await runtime.swiftType(named: name, genericArguments: arguments)
            }
        }
    }

    @Test func cachedNominalMetadataRetainsIncomingRuntimeTypeOwners() async throws {
        let runtime = ABIRuntime()
        let name = "ManagedSwiftFixtures.GenericTypeEnum"
        let bare = try await runtime.swiftType(named: name, genericArguments: [.type(ManagedRecord.self)])
        var result: NativeSwiftType?
        weak var argumentOwner: NativeSwiftType?
        do {
            let argument = try await runtime.swiftType(named: "ManagedSwiftFixtures.ManagedRecord")
            argumentOwner = argument
            result = try await runtime.swiftType(named: name, genericArguments: [.type(argument)])
            let metadata = await result!.metadata
            let bareMetadata = await bare.metadata
            #expect(ObjectIdentifier(metadata) == ObjectIdentifier(bareMetadata))
            await runtime.removeCachedResults()
        }
        #expect(argumentOwner != nil)
        result = nil
        #expect(argumentOwner == nil)
    }

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
