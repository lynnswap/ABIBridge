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

/// Uses the provider's generalized shape when the caller has no concrete
/// existential metadata. The descriptor owns the signature and witness order.
struct SwiftExtendedExistentialMetadata {
    let value: Any.Type

    init(descriptor: ResolvedSymbol, arguments: [Any.Type], resolver: SymbolResolver) throws {
        value = try unsafe descriptor.withUnsafeAddress { address in
            // The non-unique descriptor prefixes the shape with its cache ref.
            let shape = address.advanced(by: 4)
            let flags = shape.loadUnaligned(as: UInt32.self)
            let reqParameters = Int(shape.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
            let reqRequirements = Int(shape.loadUnaligned(fromByteOffset: 10, as: UInt16.self))
            let hasGeneralization = flags & 0x100 != 0
            let parameterCount = hasGeneralization ? Int(shape.loadUnaligned(fromByteOffset: 16, as: UInt16.self)) : 0
            let requirementCount = hasGeneralization ? Int(shape.loadUnaligned(fromByteOffset: 18, as: UInt16.self)) : 0
            let keyCount = hasGeneralization ? Int(shape.loadUnaligned(fromByteOffset: 20, as: UInt16.self)) : 0
            var offset = 16 + (hasGeneralization ? 8 : 0)
            if flags & 0x200 != 0 { offset += 4 }
            if flags & 0x400 != 0 { offset += 4 }
            if flags & 0x800 == 0 { offset += reqParameters }
            let parameters = (0..<parameterCount).map { index in
                flags & 0x1000 != 0 ? UInt8(0x80) : shape.load(fromByteOffset: offset + index, as: UInt8.self)
            }
            if flags & 0x1000 == 0 { offset += parameterCount }
            offset = (offset + 3) & ~3
            offset += reqRequirements * 12
            let requirements = try (0..<requirementCount).map { index in
                try SwiftMetadataRequirement(shape.advanced(by: offset + index * 12))
            }
            let declaration = SwiftGenericDeclaration(parameters: parameters.indices.map {
                .init(name: SwiftFormalType.parameterName(depth: 0, index: $0), isPack: parameters[$0] & 0x3f == 1)
            }, requirements: requirements.map(\.value), arguments: [], result: .tuple([]), failure: nil,
                isAsync: false, consumesArguments: false)
            let binding = try SwiftGenericBinding(declaration: declaration, arguments: arguments.map { .type($0) },
                signature: SwiftFunctionSignature((() -> Void).self), resolver: resolver, image: descriptor.image)
            var words: [UnsafeRawPointer?] = parameters.enumerated().filter { $0.element & 0x80 != 0 }.map {
                unsafeBitCast(arguments[$0.offset], to: UnsafeRawPointer.self)
            }
            for (index, requirement) in requirements.enumerated()
                where shape.loadUnaligned(fromByteOffset: offset + index * 12, as: UInt32.self) & 0x80 != 0 {
                guard let protocolType = requirement.descriptor else {
                    throw ABIResolutionError.metadataUnavailable("The extended existential requires an unavailable witness.")
                }
                let type = try binding.types(requirement.subject)[0]
                let witness = unsafe protocolType.withUnsafeAddress {
                    ABISwiftConformance(unsafeBitCast(type, to: UnsafeRawPointer.self), $0)
                }
                words.append(witness)
            }
            guard words.count == keyCount else {
                throw ABIResolutionError.metadataUnavailable("The extended existential generalization arguments are incomplete.")
            }
            return withExtendedLifetime(binding) {
                words.withUnsafeBufferPointer {
                    unsafeBitCast(ABISwiftExtendedExistentialMetadata(address, $0.baseAddress)!, to: Any.Type.self)
                }
            }
        }
    }
}
