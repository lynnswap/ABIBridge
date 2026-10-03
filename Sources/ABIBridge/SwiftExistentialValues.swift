import ABIBridgeCore
import ObjectiveC

// Simple existential metadata has a kind word followed by 32-bit flags.
// Extended shapes preserve their constraint signature and container convention.
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h
enum SwiftExistentialRepresentation {
    case opaque
    case classBound(witnessTables: Int)
    case error

    init?(_ type: Any.Type) {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let kind = metadata.load(as: UInt.self)
        if kind == 0x307 {
            let shape = ABISwiftExtendedExistentialShape(metadata)!
            switch shape.load(as: UInt32.self) & 0xff {
            case 0, 3: self = .opaque
            case 1:
                let parameters = shape.load(fromByteOffset: 8, as: UInt16.self)
                let arguments = shape.load(fromByteOffset: 12, as: UInt16.self)
                self = .classBound(witnessTables: Int(arguments - parameters))
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

    func valueType<Value>(for type: Value.Type) throws -> CValueType {
        switch self {
        case .opaque:
            return try CValueType(indirectSwiftSize: MemoryLayout<Value>.size,
                                  alignment: MemoryLayout<Value>.alignment)
        case .classBound(let witnesses):
            let pointer = try CValueType(scalar: ABIValuePointer)
            return try CValueType(fields: Array(repeating: pointer, count: witnesses + 1))
        case .error:
            return try CValueType(scalar: ABIValuePointer)
        }
    }

    func closureAuthType(optional: Bool) -> String {
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

/// Concrete classes and Objective-C-compatible existentials satisfy Swift's
/// object constraints. A Swift protocol existential with witness tables does
/// not itself satisfy an AnyObject generic parameter.
struct SwiftObjectType {
    let classType: AnyClass?
    private let protocols: [Protocol]

    init?(_ type: Any.Type) {
        if let type = type as? AnyClass {
            classType = type
            protocols = []
            return
        }
        guard case .classBound(witnessTables: 0) = SwiftExistentialRepresentation(type) else { return nil }
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        // SwiftObjectType decodes the protocol list of simple Objective-C
        // existentials; extended shapes are handled by their own metadata.
        guard metadata.load(as: UInt.self) == 0x303 else { return nil }
        let word = MemoryLayout<UInt>.size
        let flags = metadata.load(fromByteOffset: word, as: UInt32.self)
        let count = metadata.load(fromByteOffset: word + 4, as: UInt32.self)
        var offset = word + 8
        if flags & 0x4000_0000 != 0 {
            classType = unsafeBitCast(metadata.load(fromByteOffset: offset, as: UInt.self), to: AnyClass.self)
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

    func isSubclass(of expected: AnyClass) -> Bool {
        var current: AnyClass? = classType
        while let type = current {
            if type === expected { return true }
            current = class_getSuperclass(type)
        }
        return false
    }

    func conforms(to expected: Protocol) -> Bool {
        if let classType, class_conformsToProtocol(classType, expected) { return true }
        return protocols.contains { protocol_conformsToProtocol($0, expected) }
    }
}
