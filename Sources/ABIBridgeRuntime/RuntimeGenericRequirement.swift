import ABIBridgeCore

package struct RuntimeGenericRequirement {
    package let address: UnsafeRawPointer
    package init(_ address: UnsafeRawPointer) { self.address = address }
    package var flags: UInt32 { address.loadUnaligned(as: UInt32.self) }
    package var kind: UInt32 { flags & 0x1f }
    package var isKey: Bool { flags & 0x80 != 0 }
    package var isPack: Bool { flags & 0x20 != 0 }
    package var invertedProtocols: UInt16 {
        address.loadUnaligned(fromByteOffset: 10, as: UInt16.self)
    }
    package var isClassLayout: Bool {
        address.loadUnaligned(fromByteOffset: 8, as: UInt32.self) == 0
    }
    package var protocolDescriptor: UnsafeRawPointer? {
        ABISwiftProtocolRequirementDescriptor(address.advanced(by: 8))
    }
    package var objectiveCProtocol: UnsafeRawPointer? {
        ABISwiftProtocolRequirementObjectiveCProtocol(address.advanced(by: 8))
    }
    package var isClassBoundProtocol: Bool {
        kind == 0 && ABISwiftProtocolRequirementIsClassBound(address.advanced(by: 8))
    }
    package var isInheritedProtocol: Bool {
        guard kind == 0 else { return false }
        let field = address.advanced(by: 4)
        let subject = field.advanced(by: Int(field.loadUnaligned(as: Int32.self)))
        return subject.load(as: UInt8.self) == 120
            && subject.load(fromByteOffset: 1, as: UInt8.self) == 0
    }
    package func copyTypeSyntax(constraint: Bool) throws -> OpaquePointer {
        guard let handle = ABICopySwiftGenericRequirementTypeSyntax(address, constraint) else {
            throw RuntimeResolutionError.metadataUnavailable(
                "Cannot decode the Swift generic requirement type."
            )
        }
        return handle
    }
}

package struct RuntimeProtocolLayout {
    private let address: UnsafeRawPointer
    package init(_ address: UnsafeRawPointer) { self.address = address }
    package var associatedTypes: [String] {
        let field = address.advanced(by: 20)
        let offset = Int(field.loadUnaligned(as: Int32.self))
        guard offset != 0 else { return [] }
        return String(cString: field.advanced(by: offset).assumingMemoryBound(to: CChar.self))
            .split(separator: " ").map(String.init)
    }
    package var requirements: [RuntimeGenericRequirement] {
        let count = Int(address.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        return (0..<count).map { RuntimeGenericRequirement(address.advanced(by: 24 + $0 * 12)) }
    }
}
