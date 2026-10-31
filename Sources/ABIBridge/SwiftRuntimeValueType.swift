import ABIBridgeCore
import ABIBridgeCore.Backend
import ABIBridgeRuntime

func swiftRuntimeValueType(
    metadata: Any.Type,
    retaining types: [NativeSwiftType]
) throws -> NativeSwiftType {
    try validateSwiftRuntimeValueStorage(metadata)
    if let type = types.first(where: { $0.metadata == metadata }) { return type }
    let resolver = types.first?.resolver ?? .shared
    let images = types.flatMap(\.codeImages)
    let generic = try SwiftGenericTypeMetadata(metadata: metadata, retaining: images)
    let name = try swiftNativeTypeName(metadata)
    let image: NativeImage
    if let descriptor = ABISwiftTypeDescriptor(unsafeBitCast(metadata, to: UnsafeRawPointer.self)),
        let definingImage = try swiftImplementationImage(containing: descriptor)
    {
        image = definingImage
    } else if let objectType = metadata as? AnyClass {
        image = try swiftClassImage(
            objectType,
            named: name,
            resolver: resolver,
            retaining: types.first?.image
        )
    } else if let owner = generic.images.first {
        image = owner
    } else {
        throw ABIResolutionError.metadataUnavailable(
            "The runtime value's implementation image is unavailable."
        )
    }
    let lifetime =
        SwiftValueCodeLifetime.connect(
            types.map(\.codeLifetime),
            retaining: [image] + generic.images
        ) ?? SwiftValueCodeLifetime([image] + generic.images)
    return NativeSwiftType(
        name: name,
        image: image,
        metadata: metadata,
        representation: nil,
        resolver: resolver,
        genericMetadata: generic,
        codeLifetime: lifetime
    )
}

func validateSwiftRuntimeValueStorage(_ type: Any.Type) throws {
    let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
    if runtimeMetadataKind(type) == .existential {
        let flags = metadata.advanced(by: MemoryLayout<UInt>.size).load(as: UInt32.self)
        // This composition has two native words but a one-word generic VWT.
        // Copying projected storage cannot repair that compiler/runtime mismatch.
        // https://github.com/lynnswap/ABIBridge/issues/302
        if flags & 0x3f00_0000 == 0x0100_0000 && flags & 0x8000_0000 == 0 {
            throw ABIResolutionError.unsupportedDeclaration(
                "Swift.Error & Swift.AnyObject has incompatible native and generic storage layouts."
            )
        }
    }
    if let optional = type as? any NativeOptionalValue.Type {
        try validateSwiftRuntimeValueStorage(optional.wrappedType)
    } else if let tuple = RuntimeTupleMetadata(type) {
        for element in tuple.elements {
            try validateSwiftRuntimeValueStorage(element.type)
        }
    }
}
