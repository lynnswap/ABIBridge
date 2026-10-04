import ABIBridgeCore

package struct RuntimeMetatypeMetadata {
    package let instance: Any.Type?
    package let isExistential: Bool
    package let witnessCount: Int

    package init?(_ type: Any.Type) {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let kind = metadata.load(as: UInt.self)
        if kind == 0x307, let shape = ABISwiftExtendedExistentialShape(metadata),
            shape.loadUnaligned(as: UInt32.self) & 0xff == 2
        {
            guard let witnesses = RuntimeExtendedExistentialShapeLayout(shape).witnessCount else {
                return nil
            }
            instance = nil
            isExistential = true
            witnessCount = witnesses
            return
        }
        guard kind == 0x304 || kind == 0x306 else { return nil }
        instance = metadata.load(fromByteOffset: MemoryLayout<UInt>.size, as: Any.Type.self)
        isExistential = kind == 0x306
        witnessCount =
            isExistential
            ? Int(
                metadata.load(fromByteOffset: 2 * MemoryLayout<UInt>.size, as: UInt32.self)
                    & 0x00ffffff
            ) : 0
    }

    package var isSingleton: Bool {
        !isExistential && instance.map(Self.hasSingletonMetatype) == true
    }

    private static func hasSingletonMetatype(_ instance: Any.Type) -> Bool {
        if instance is AnyClass { return false }
        if let metatype = Self(instance), !metatype.isExistential, let nested = metatype.instance {
            return hasSingletonMetatype(nested)
        }
        return true
    }

    package func runtimeValueType<Value>(
        for type: Value.Type,
        thin: Bool? = nil
    ) throws -> RuntimeValueType {
        let components: RuntimeValueType
        if thin ?? isSingleton {
            components = try RuntimeValueType(scalar: ABIValueVoid)
        } else {
            let pointer = try RuntimeValueType(scalar: ABIValuePointer)
            components =
                witnessCount == 0
                ? pointer
                : try RuntimeValueType(fields: Array(repeating: pointer, count: 1 + witnessCount))
        }
        return try RuntimeValueType(
            swiftComponents: components,
            size: MemoryLayout<Value>.size,
            alignment: MemoryLayout<Value>.alignment
        )
    }
}
