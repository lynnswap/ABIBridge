import ABIBridge
import ManagedSwiftFixtures
import Testing

@Suite(.serialized)
struct SwiftParameterizedRuntimeGetterTests {
    @Test func associatedWitnessPreservesItsDeclaringProtocol() async throws {
        let runtime = ABIRuntime.shared
        let receiver = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.RuntimeAssociatedGetter",
            genericArguments: [.type(Int64.self)]
        )
        typealias Storage = RuntimeAssociatedElement<FreshCollectionSuperclassValue<[Int64]>>
        let storage = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.RuntimeAssociatedElement",
            genericArguments: [.type(FreshCollectionSuperclassValue<[Int64]>.self)]
        )
        let getter = try await receiver.resolveGetter(
            named: "storage",
            as: (() -> NativeSwiftValue).self,
            valueABIs: [storage: .opaque(named: storage.name)],
            receiverABI: .opaque(named: receiver.name)
        )
        let value = try unsafe getter.unsafeInvoke(on: RuntimeAssociatedGetter<Int64>(42))
        #expect(try value.take(as: Storage.self).element == 42)
    }

    @MainActor @Test
    func explicitNestedNominalABIComposesWithRuntimeGettersAndClosures() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeRuntimeParameterizedGetter(_:)",
            as: ((Int64) -> NativeSwiftValue).self
        )
        let source = try unsafe make.unsafeInvoke(42)
        let structureType = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.RuntimeParameterizedGetter.Structure",
            genericArguments: [.type(Int64.self)]
        )
        let valueABIs = [structureType: try NativeType.opaque(named: structureType.name)]
        let getter = try await source.type.resolveGetter(
            named: "structure",
            as: (() -> NativeSwiftValue).self,
            valueABIs: valueABIs,
            receiverABI: .opaque(named: source.type.name)
        )
        let value = try unsafe getter.unsafeInvoke(on: source)
        #expect(value.type == structureType)
        let structure = try value.take(as: RuntimeParameterizedGetter<Int64>.Structure.self)
        switch structure {
        case .body(let body): #expect(body() == 42)
        }

        typealias Signature = @MainActor () -> NativeSwiftValue
        let factory = try await source.type.resolveGetter(
            named: "makeStructure",
            as: (() -> NativeSwiftClosure<Signature>).self,
            valueABIs: valueABIs,
            receiverABI: .opaque(named: source.type.name)
        )
        let closure = try unsafe factory.unsafeInvoke(on: source)
        let returned = try unsafe closure.unsafeInvoke()
        let fromClosure = try returned.take(as: RuntimeParameterizedGetter<Int64>.Structure.self)
        switch fromClosure {
        case .body(let body): #expect(body() == 42)
        }
        #expect(!source.isConsumed)
    }

    @Test func explicitHintsPreserveFormalGenericIndirection() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
            as: ((Int64) -> NativeSwiftValue).self
        )
        let input = try unsafe make.unsafeInvoke(42)
        let echo = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.echoGeneric(_:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self,
            genericArguments: [.type(input.type)],
            valueABIs: [input.type: .int64]
        )
        let result = try unsafe echo.unsafeInvoke(input)
        #expect(try result.take(as: Int64.self) == 42)
        #expect(!input.isConsumed)

        let elementStorage = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.GenericElementStorage",
            genericArguments: [.type([Int64].self)]
        )
        let arrayElement = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.arrayElementGeneric(_:)",
            as: ((GenericElementStorage<[Int64]>) -> GenericElementStorage<[Int64]>).self,
            genericArguments: [.type(Int64.self)],
            valueABIs: [elementStorage: .int64]
        )
        #expect(try unsafe arrayElement.unsafeInvoke(.init(42)).element == 42)
    }
}
