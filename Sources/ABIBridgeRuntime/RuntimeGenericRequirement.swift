import ABIBridgeCore

package struct RuntimeGenericRequirement {
    package let address: UnsafeRawPointer
    package init(_ address: UnsafeRawPointer) { self.address = address }
    package var flags: UInt32 { address.loadUnaligned(as: UInt32.self) }
    package var kind: UInt32 { flags & 0x1f }
    package var isKey: Bool { flags & 0x80 != 0 }
    package var isPack: Bool { flags & 0x20 != 0 }
    package var invertedGenericParameterIndex: UInt16 {
        address.loadUnaligned(fromByteOffset: 8, as: UInt16.self)
    }
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
    /// The descriptors of the requirements that witness tables hold, in
    /// their order after the slot of the conformance descriptor.
    package var witnessRequirements: [RuntimeProtocolRequirement] {
        let signature = Int(address.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        let count = Int(address.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
        let start = address.advanced(by: 24 + signature * 12)
        return (0..<count).map { RuntimeProtocolRequirement(start.advanced(by: $0 * 8)) }
    }
}

/// A protocol requirement descriptor, which records a requirement's kind and
/// effects but not its name.
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/MetadataValues.h
package struct RuntimeProtocolRequirement {
    package let address: UnsafeRawPointer
    package init(_ address: UnsafeRawPointer) { self.address = address }
    package var flags: UInt32 { address.loadUnaligned(as: UInt32.self) }
    /// 1 method, 2 initializer, 3 getter, 4 setter, 5 read and 6 modify
    /// coroutines; 0, 7, and 8 are base protocols, associated types, and
    /// associated conformances.
    package var kind: UInt32 { flags & 0x0f }
    package var isInstance: Bool { flags & 0x10 != 0 }
    package var isAsync: Bool { flags & 0x20 != 0 }
    /// Whether a conformance implements the requirement with code, which a
    /// witness thunk provides.
    package var isCode: Bool { ![0, 7, 8].contains(kind) }
}
