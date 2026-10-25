import ABIBridgeCore
import ABIBridgeCore.Backend
import ABIBridgeRuntime

extension RuntimeEnumMetadata {
    func caseIndex(named caseName: String) throws -> Int {
        let matches = cases.indices.filter {
            cases[$0].name.utf8.elementsEqual(caseName.utf8)
        }
        guard let index = matches.first else {
            throw NativeSwiftValueError.enumCaseNotFound(name: caseName)
        }
        guard matches.count == 1 else {
            throw NativeSwiftValueError.ambiguousEnumCase(name: caseName)
        }
        return index
    }
}

extension NativeSwiftValue {
    /// Copies an independently owned copy of the named enum case's entire payload.
    ///
    /// Returns nil when this value inhabits another case or the named case has no payload. Multiple associated values use their native tuple payload; a single tuple associated value has that same tuple representation. Case names must be unique in the runtime field metadata. The enum and its payload must be Copyable, and the returned payload must be Escapable. The original value is neither modified nor consumed.
    ///
    /// Required closure ABI preparation runs away from the caller's executor and joins shared preparation already in progress. Copying and binding captured contexts run on the caller's executor. Function values in the payload are adapted to the convention used by owned runtime values. Supply `valueABIs` for closed nominal types in their parameters or results whose ABI cannot be inferred from runtime metadata.
    public nonisolated(nonsending) func copyEnumPayload(
        forCase caseName: String,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) async throws -> NativeSwiftValue? {
        guard let payload = try enumPayloadSource(forCase: caseName) else { return nil }
        let enumType = type
        let caseIndex = payload.index
        let prepared = try await NativePreparation.run {
            try Self.prepareEnumPayload(
                enumType: enumType,
                caseIndex: caseIndex,
                valueABIs: valueABIs
            )
        }
        return copyEnumPayload(payload, prepared: prepared)
    }

    /// Copies an independently owned enum payload synchronously on the caller's thread.
    ///
    /// This has the same payload and ownership contract as `copyEnumPayload(forCase:valueABIs:)`. It performs or joins required ABI preparation before returning, which can block the caller's thread.
    public func copyEnumPayloadAndWait(
        forCase caseName: String,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) throws -> NativeSwiftValue? {
        guard let payload = try enumPayloadSource(forCase: caseName) else { return nil }
        let prepared = try Self.prepareEnumPayload(
            enumType: type,
            caseIndex: payload.index,
            valueABIs: valueABIs
        )
        return copyEnumPayload(payload, prepared: prepared)
    }

    private struct EnumPayloadSource {
        let storage: NativeValueStorage
        let index: Int
        let isIndirect: Bool
    }

    private func enumPayloadSource(forCase caseName: String) throws -> EnumPayloadSource? {
        let source = try access(.borrowing)
        let enumMetadata = try withRuntimeErrors { try RuntimeEnumMetadata(type.metadata) }
        let index = try enumMetadata.caseIndex(named: caseName)
        guard try withRuntimeErrors({ try enumMetadata.tag(of: source.address) }) == index,
            enumMetadata.cases[index].hasPayload
        else { return nil }
        guard isCopyable else {
            throw NativeSwiftValueError.noncopyableType
        }
        return EnumPayloadSource(
            storage: source,
            index: index,
            isIndirect: enumMetadata.cases[index].isIndirect
        )
    }

    private static func prepareEnumPayload(
        enumType: NativeSwiftType,
        caseIndex: Int,
        valueABIs: [NativeSwiftType: NativeType]
    ) throws -> (NativeSwiftType, SwiftRuntimeValueProjectionPlan) {
        let runtime = try withRuntimeErrors { try RuntimeEnumMetadata(enumType.metadata) }
        guard let metadata = try withRuntimeErrors({ try runtime.payloadType(at: caseIndex) })
        else {
            throw ABIResolutionError.metadataUnavailable("The enum case has no payload metadata.")
        }
        guard SwiftCopyability.accepts(metadata) else {
            throw NativeSwiftValueError.noncopyableType
        }
        guard SwiftEscapability.accepts(metadata) else {
            throw ABIResolutionError.unsupportedDeclaration(
                "An owned runtime value requires an Escapable native type."
            )
        }
        let payloadType = try swiftRuntimeValueType(
            metadata: metadata,
            retaining: [enumType] + Array(valueABIs.keys)
        )
        let plan = try SwiftRuntimeValueProjectionPlan(
            enumType: enumType,
            caseIndex: caseIndex,
            payload: metadata,
            valueABIs: valueABIs
        )
        return (payloadType, plan)
    }

    private func copyEnumPayload(
        _ payload: EnumPayloadSource,
        prepared: (NativeSwiftType, SwiftRuntimeValueProjectionPlan)
    ) -> NativeSwiftValue {
        let (payloadType, plan) = prepared
        let payloadMetadata = unsafeBitCast(payloadType.metadata, to: UnsafeRawPointer.self)
        let metadata = unsafeBitCast(type.metadata, to: UnsafeRawPointer.self)
        let payloadLayout = ABISwiftGetValueLayout(payloadMetadata)
        let enumLayout = ABISwiftGetValueLayout(metadata)
        let storage = NativeValueStorage(
            size: payloadLayout.stride,
            alignment: payloadLayout.alignment,
            owner: payloadType,
            codeLifetime: payloadType.codeLifetime
        )
        let scratch = NativeValueStorage(
            size: enumLayout.stride,
            alignment: enumLayout.alignment,
            owner: type,
            codeLifetime: type.codeLifetime
        )
        return withExtendedLifetime(payload.storage) {
            // Projection consumes this independent enum copy, leaving scratch uninitialized.
            ABISwiftCopyValue(metadata, scratch.address, payload.storage.address)
            ABISwiftTakeEnumPayload(
                metadata,
                scratch.address,
                payloadMetadata,
                payload.isIndirect,
                storage.address
            )
            storage.assumeInitialized { ABISwiftDestroyValue(payloadMetadata, $0) }
            plan.apply(to: storage)
            return NativeSwiftValue(storage: storage, type: payloadType)
        }
    }

    /// Copies one zero-based element from this value's native tuple representation.
    ///
    /// The returned value preserves the element's runtime type and implementation lifetime. The element must be Copyable and Escapable; other tuple elements need not be Copyable. The tuple is neither modified nor consumed. Copying runs on the caller's thread without symbol scanning or call preparation.
    public func copyTupleElement(at index: Int) throws -> NativeSwiftValue {
        let source = try access(.borrowing)
        guard let tuple = RuntimeTupleMetadata(type.metadata) else {
            throw ABIResolutionError.unsupportedDeclaration("The runtime value is not a tuple.")
        }
        guard tuple.elements.indices.contains(index) else {
            throw NativeSwiftValueError.tupleElementIndexOutOfBounds(
                index: index,
                count: tuple.elements.count
            )
        }
        let element = tuple.elements[index]
        let elementType = try swiftRuntimeValueType(metadata: element.type, retaining: [type])
        return try withExtendedLifetime(source) {
            try Self.copy(from: source.address.advanced(by: element.offset), type: elementType)
        }
    }

    /// Copies the concrete value contained in an existential into independently owned storage.
    ///
    /// This opens only an existential container and any directly nested existential containers. It does not unpack Optional, enums, tuples, type-erasing structs, or metatypes. The underlying value must be Copyable and Escapable. Class values retain the same instance. The original container is neither modified nor consumed. Metadata projection and copying run on the caller's thread without symbol scanning or call preparation.
    public func copyUnderlyingValue() throws -> NativeSwiftValue {
        let source = try access(.borrowing)
        func copyUnderlying(
            type underlyingType: Any.Type,
            address: UnsafeRawPointer
        ) throws -> NativeSwiftValue {
            let kind = runtimeMetadataKind(underlyingType)
            if kind == .existential || kind == .extendedExistential {
                return try withRuntimeErrors {
                    try withRuntimeExistentialProjection(type: underlyingType, value: address) {
                        projectedType,
                        projectedValue in
                        try copyUnderlying(type: projectedType, address: projectedValue)
                    }
                }
            }
            let valueType = try swiftRuntimeValueType(metadata: underlyingType, retaining: [type])
            return try Self.copy(from: address, type: valueType)
        }
        return try withExtendedLifetime(source) {
            try withRuntimeErrors {
                try withRuntimeExistentialProjection(type: type.metadata, value: source.address) {
                    projectedType,
                    projectedValue in
                    try copyUnderlying(type: projectedType, address: projectedValue)
                }
            }
        }
    }
}
