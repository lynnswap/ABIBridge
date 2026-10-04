import ABIBridgeCore
import ObjectiveC

package enum RuntimeExistentialRepresentation {
    case opaque
    case classBound(witnessTables: Int)
    case error

    package init?(_ type: Any.Type) {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let kind = metadata.load(as: UInt.self)
        if kind == 0x307 {
            let shape = ABISwiftExtendedExistentialShape(metadata)!
            switch shape.load(as: UInt32.self) & 0xff {
            case 0, 3: self = .opaque
            case 1:
                guard let witnesses = RuntimeExtendedExistentialShapeLayout(shape).witnessCount
                else { return nil }
                self = .classBound(witnessTables: witnesses)
            default: return nil
            }
            return
        }
        guard kind == 0x303 else { return nil }
        let flags = metadata.load(fromByteOffset: MemoryLayout<UInt>.size, as: UInt32.self)
        if flags & 0x8000_0000 == 0 {
            self = .classBound(witnessTables: Int(flags & 0x00ff_ffff))
        } else if flags & 0x3f00_0000 == 0x0100_0000 {
            self = .error
        } else {
            self = .opaque
        }
    }

    package func runtimeValueType<Value>(for type: Value.Type) throws -> RuntimeValueType {
        switch self {
        case .opaque:
            return try RuntimeValueType(
                indirectSwiftSize: MemoryLayout<Value>.size,
                alignment: MemoryLayout<Value>.alignment
            )
        case .classBound(let witnesses):
            let pointer = try RuntimeValueType(scalar: ABIValuePointer)
            return try RuntimeValueType(fields: Array(repeating: pointer, count: witnesses + 1))
        case .error:
            return try RuntimeValueType(scalar: ABIValuePointer)
        }
    }

    package func closureAuthType(optional: Bool) -> String {
        switch self {
        case .opaque: return "-indirect"
        // A loadable class existential stays formally direct even when its
        // physical components exceed the backend's register aggregate limit.
        case .classBound(let witnesses):
            return optional && witnesses != 0 ? "Optional<-class>" : "-class"
        case .error:
            return optional ? "Optional<$ss5ErrorP>" : "$ss5ErrorP"
        }
    }
}

package struct RuntimeObjectType {
    package let classType: AnyClass?
    private let protocols: [Protocol]

    package init?(_ type: Any.Type) {
        if let type = type as? AnyClass {
            classType = type
            protocols = []
            return
        }
        guard case .classBound(witnessTables: 0) = RuntimeExistentialRepresentation(type) else {
            return nil
        }
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        // RuntimeObjectType decodes the protocol list of simple Objective-C
        // existentials; extended shapes are handled by their own metadata.
        guard metadata.load(as: UInt.self) == 0x303 else { return nil }
        let word = MemoryLayout<UInt>.size
        let flags = metadata.load(fromByteOffset: word, as: UInt32.self)
        let count = metadata.load(fromByteOffset: word + 4, as: UInt32.self)
        var offset = word + 8
        if flags & 0x4000_0000 != 0 {
            classType = unsafeBitCast(
                metadata.load(fromByteOffset: offset, as: UInt.self),
                to: AnyClass.self
            )
            offset += word
        } else {
            classType = nil
        }
        // Metadata.h / MetadataRef.h: superclass metadata precedes tagged
        // protocol references; Objective-C references have their low bit set.
        protocols = (0..<Int(count)).compactMap { index in
            let reference = metadata.load(fromByteOffset: offset + index * word, as: UInt.self)
            return reference & 1 == 1 ? unsafeBitCast(reference & ~1, to: Protocol.self) : nil
        }
    }

    package func isSubclass(of expected: AnyClass) -> Bool {
        var current: AnyClass? = classType
        while let type = current {
            if type === expected { return true }
            current = class_getSuperclass(type)
        }
        return false
    }

    package func conforms(to expected: Protocol) -> Bool {
        if let classType, class_conformsToProtocol(classType, expected) { return true }
        return protocols.contains { protocol_conformsToProtocol($0, expected) }
    }
}
