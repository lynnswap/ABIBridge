import ABIBridgeCore
import ABIBridgeCore.Backend
import ObjectiveC

private final class RuntimeKeyPathPatternStorage {
    let address: UnsafeMutableRawPointer

    init(keyByteCount: Int) {
        address = .allocate(
            byteCount: ABISwiftKeyPathPatternSize() + keyByteCount,
            alignment: MemoryLayout<UnsafeRawPointer>.alignment
        )
    }

    deinit { address.deallocate() }
}

package struct RuntimeWritableKeyPathPlan: Sendable {
    private let descriptor: RuntimeSymbol
    private let root: Any.Type
    private let value: Any.Type
    private let keyValueCodingKey: String?

    package init(
        descriptor: RuntimeSymbol,
        root: Any.Type,
        value: Any.Type,
        keyValueCodingKey: String? = nil
    ) throws {
        guard keyValueCodingKey?.utf8.contains(0) != true else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "The key-value coding key cannot contain a null character."
            )
        }
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
        self.keyValueCodingKey = keyValueCodingKey
    }

    package func instantiate() -> AnyKeyPath {
        descriptor.withUnsafeAddress { address in
            let rootMetadata = unsafeBitCast(root, to: UnsafeRawPointer.self)
            let valueMetadata = unsafeBitCast(value, to: UnsafeRawPointer.self)
            guard let keyValueCodingKey else {
                let result = ABISwiftCreateWritableKeyPath(address, rootMetadata, valueMetadata)!
                return Unmanaged<AnyKeyPath>.fromOpaque(result).takeRetainedValue()
            }
            let keyBytes = keyValueCodingKey.utf8CString
            let owner = RuntimeKeyPathPatternStorage(keyByteCount: keyBytes.count)
            let result = keyBytes.withUnsafeBufferPointer {
                ABISwiftCreateWritableKeyPathWithKVCKey(
                    address,
                    rootMetadata,
                    valueMetadata,
                    $0.baseAddress!,
                    owner.address
                )!
            }
            let keyPath = Unmanaged<AnyKeyPath>.fromOpaque(result).takeRetainedValue()
            // The KVC string must outlive copies extracted from NativeSwiftValue.
            // KeyPath is a native class object; its associated owner releases the
            // borrowed string storage when the last KeyPath reference is released.
            objc_setAssociatedObject(
                keyPath,
                Unmanaged.passUnretained(owner).toOpaque(),
                owner,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            return keyPath
        }
    }
}
