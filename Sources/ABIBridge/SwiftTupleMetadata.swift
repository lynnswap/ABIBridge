import ABIBridgeCore

/// Swift tuple metadata supplies the instantiated element offsets, which need
/// not match a C struct's tail-padding rules.
struct SwiftTupleMetadata {
    struct Element {
        let type: Any.Type
        let offset: Int
    }
    let elements: [Element]

    init?(_ type: Any.Type) {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let word = MemoryLayout<UInt>.size
        guard metadata.load(as: UInt.self) == 0x301 else { return nil }
        let count = metadata.load(fromByteOffset: word, as: Int.self)
        elements = (0..<count).map {
            Element(type: metadata.load(fromByteOffset: (3 + 2 * $0) * word, as: Any.Type.self),
                    offset: metadata.load(fromByteOffset: (4 + 2 * $0) * word, as: Int.self))
        }
    }

    func layout<Value>(for type: Value.Type, fields: [CValueType]) throws -> CValueType {
        try CValueType(swiftTuple: fields, offsets: elements.map(\.offset),
                       size: MemoryLayout<Value>.size, alignment: MemoryLayout<Value>.alignment)
    }
}
