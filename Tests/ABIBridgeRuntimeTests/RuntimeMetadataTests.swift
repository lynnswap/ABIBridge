import ABIBridgeCore
import ABIBridgeRuntime
import ManagedSwiftFixtures
import Testing

public struct RuntimeGenericBox<Value: Equatable> {}
public protocol RuntimeClassProtocol: AnyObject {}

struct RuntimeMetadataTests {
    @Test func functionMetadataPreservesEffectsAndFormalTypes() throws {
        let function = try RuntimeFunctionMetadata(
            (@Sendable (Int64, String) async throws(ScalarFailure) -> Double).self
        )
        #expect(function.parameters.count == 2)
        #expect(function.parameters[0] == Int64.self && function.parameters[1] == String.self)
        #expect(function.result == Double.self && function.failure == ScalarFailure.self)
        #expect(function.isAsync && function.isSendable)
        let changed = try function.replacing(
            parameters: [UInt64.self, String.self],
            result: Float.self,
            parameterFlags: [0, 0]
        )
        let expected: Any.Type = (@Sendable (UInt64, String) async throws(ScalarFailure) -> Float)
            .self
        #expect(ObjectIdentifier(changed) == ObjectIdentifier(expected))
        let untyped = try RuntimeFunctionMetadata((() throws -> Void).self)
        #expect(ObjectIdentifier(untyped.failure) == ObjectIdentifier((any Error).self))
        #expect(try RuntimeFunctionMetadata((() -> Void).self).failure == Never.self)
    }

    @Test func functionMetadataKeepsInoutAndActorConventions() throws {
        let inoutFunction = try RuntimeFunctionMetadata(((inout Int64) -> Void).self)
        #expect(inoutFunction.parameterFlags == [1])
        let actor = try RuntimeFunctionMetadata((@MainActor () -> Void).self)
        #expect(actor.globalActor == MainActor.self)
        #expect(throws: RuntimeResolutionError.self) { try RuntimeFunctionMetadata(Int64.self) }
    }

    @Test func tupleOffsetsAndLabelsMatchCompilerStorage() throws {
        typealias Value = (small: UInt8, number: Int64, tail: UInt16)
        let metadata = try #require(RuntimeTupleMetadata(Value.self))
        #expect(metadata.labels == ["small", "number", "tail"])
        var value: Value = (3, 42, 7)
        withUnsafeBytes(of: &value) { bytes in
            #expect(bytes.load(fromByteOffset: metadata.elements[0].offset, as: UInt8.self) == 3)
            #expect(bytes.load(fromByteOffset: metadata.elements[1].offset, as: Int64.self) == 42)
            #expect(bytes.load(fromByteOffset: metadata.elements[2].offset, as: UInt16.self) == 7)
        }
        let layout = try metadata.layout(
            for: Value.self,
            fields: [
                RuntimeValueType(scalar: ABIValueUInt8), RuntimeValueType(scalar: ABIValueInt64),
                RuntimeValueType(scalar: ABIValueUInt16),
            ]
        )
        #expect(
            layout.size == MemoryLayout<Value>.size
                && layout.alignment == MemoryLayout<Value>.alignment
        )
    }

    @Test func metatypesAndExistentialsKeepTheirDistinctRepresentations() throws {
        #expect(try #require(RuntimeMetatypeMetadata(Int64.Type.self)).isSingleton)
        #expect(!((try #require(RuntimeMetatypeMetadata(LifetimeToken.Type.self))).isSingleton))
        let existential = try #require(RuntimeMetatypeMetadata((any Equatable.Type).self))
        #expect(existential.isExistential && existential.witnessCount == 1)
        guard
            case .classBound(let witnesses) = RuntimeExistentialRepresentation(
                (any RuntimeClassProtocol).self
            )
        else {
            Issue.record("Expected an object and one Swift witness table")
            return
        }
        #expect(witnesses == 1)
        guard case .error = RuntimeExistentialRepresentation((any Error).self),
            case .opaque = RuntimeExistentialRepresentation((any Collection<Int>).self)
        else {
            Issue.record("Error and extended existential metadata use different containers")
            return
        }
    }

    @Test func genericMetadataUsesRuntimeWitnessesAndRetainsItsImages() throws {
        let metadata = try RuntimeGenericTypeMetadata(metadata: RuntimeGenericBox<Int64>.self)
        #expect(ObjectIdentifier(metadata.value) == ObjectIdentifier(RuntimeGenericBox<Int64>.self))
        guard case .type(let argument) = try #require(metadata.arguments.first) else {
            Issue.record("Expected one scalar generic argument")
            return
        }
        #expect(ObjectIdentifier(argument) == ObjectIdentifier(Int64.self))
        let address = try #require(
            ABISwiftTypeDescriptor(unsafeBitCast(metadata.value, to: UnsafeRawPointer.self))
        )
        let descriptor = try RuntimeNominalDescriptor(address: address)
        let instantiated = try RuntimeGenericTypeMetadata(
            descriptor: descriptor,
            arguments: [.type(String.self)]
        )
        #expect(
            ObjectIdentifier(instantiated.value) == ObjectIdentifier(RuntimeGenericBox<String>.self)
        )
        #expect(!instantiated.images.isEmpty)
    }

    @Test func physicalInterfaceCacheKeepsConventionAndOwnership() throws {
        let word = try RuntimeValueType(scalar: ABIValueInt64)
        let direct = try RuntimeSwiftCallInterface.cached(result: word, parameters: [word])
        #expect(
            try RuntimeSwiftCallInterface.cached(
                result: RuntimeValueType(scalar: ABIValueInt64),
                parameters: [word]
            ) === direct
        )
        let indirect = try RuntimeValueType(indirectSwiftSize: 8, alignment: 8)
        #expect(
            try RuntimeSwiftCallInterface.cached(result: indirect, parameters: [word]) !== direct
        )
        let typed = try RuntimeSwiftCallInterface.cached(
            result: word,
            parameters: [word],
            errorPlan: .init(type: word, isTyped: true)
        )
        let untyped = try RuntimeSwiftCallInterface.cached(
            result: word,
            parameters: [word],
            errorPlan: .init(type: word, isTyped: false)
        )
        #expect(typed !== untyped && typed !== direct)
    }
}
