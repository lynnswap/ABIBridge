import ABIBridgeCore

package struct RuntimeWritableKeyPathPlan: Sendable {
    private let descriptor: RuntimeSymbol
    private let root: Any.Type
    private let value: Any.Type

    package init(descriptor: RuntimeSymbol, root: Any.Type, value: Any.Type) throws {
        guard descriptor.sectionRange.contains(descriptor.address),
            descriptor.sectionRange.upperBound - descriptor.address >= 4
        else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The property descriptor header lies outside its image section."
            )
        }
        // The descriptor starts with a KeyPathComponentHeader. A zero header
        // leaves identity and accessors to the compiler's local component.
        // https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/KeyPath.h
        let header = descriptor.withUnsafeAddress { $0.loadUnaligned(as: UInt32.self) }
        guard header != 0 else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "The property descriptor does not carry key-path accessors."
            )
        }
        guard header & 0x7f000000 == 0x02000000 else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "Only computed-property descriptors can create writable key paths."
            )
        }
        guard header & 0x00400000 != 0 else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "The property descriptor is read-only."
            )
        }
        guard header & 0x00080000 == 0 else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "The property descriptor requires generic arguments or captured subscript values."
            )
        }
        guard descriptor.sectionRange.upperBound - descriptor.address >= 16 else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The property descriptor accessors lie outside its image section."
            )
        }
        self.descriptor = descriptor
        self.root = root
        self.value = value
    }

    package func instantiate() -> AnyKeyPath {
        descriptor.withUnsafeAddress { address in
            let result = ABISwiftCreateWritableKeyPath(
                address,
                unsafeBitCast(root, to: UnsafeRawPointer.self),
                unsafeBitCast(value, to: UnsafeRawPointer.self)
            )!
            return Unmanaged<AnyKeyPath>.fromOpaque(result).takeRetainedValue()
        }
    }
}
