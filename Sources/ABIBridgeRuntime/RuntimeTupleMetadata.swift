import ABIBridgeCore

package struct RuntimeTupleMetadata {
    package struct Element {
        package init(type: Any.Type, offset: Int) { self.type = type; self.offset = offset }
        package let type: Any.Type
        package let offset: Int
    }
    package let elements: [Element]
    package let labels: [String]

    package init?(_ type: Any.Type) {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let word = MemoryLayout<UInt>.size
        guard metadata.load(as: UInt.self) == 0x301 else { return nil }
        let count = metadata.load(fromByteOffset: word, as: Int.self)
        if let names = metadata.load(fromByteOffset: 2 * word, as: UnsafePointer<CChar>?.self) {
            labels = String(cString: names).split(separator: " ", omittingEmptySubsequences: false)
                .prefix(count).map(String.init)
        } else {
            labels = Array(repeating: "", count: count)
        }
        elements = (0..<count).map {
            Element(
                type: metadata.load(fromByteOffset: (3 + 2 * $0) * word, as: Any.Type.self),
                offset: metadata.load(fromByteOffset: (4 + 2 * $0) * word, as: Int.self)
            )
        }
    }

    package func layout<Value>(
        for type: Value.Type,
        fields: [RuntimeValueType]
    ) throws -> RuntimeValueType {
        try RuntimeValueType(
            swiftTuple: fields,
            offsets: elements.map(\.offset),
            size: MemoryLayout<Value>.size,
            alignment: MemoryLayout<Value>.alignment
        )
    }
}
