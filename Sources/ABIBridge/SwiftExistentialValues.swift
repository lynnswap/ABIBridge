import ABIBridgeCore

// Simple existential metadata has a kind word followed by 32-bit flags.
// Extended existentials and existential metatypes have distinct metadata kinds.
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h
enum SwiftExistentialRepresentation {
    case opaque
    case classBound(witnessTables: Int)
    case error

    init?(_ type: Any.Type) {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        guard metadata.load(as: UInt.self) == 0x303 else { return nil }
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
