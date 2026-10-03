import ABIBridgeCore
import ObjectiveC
import Synchronization

struct SwiftExtendedExistentialShapeLayout {
    let shape: UnsafeRawPointer
    let flags: UInt32
    let requirementCount: Int
    let genericParameterCount: Int
    let genericRequirementCount: Int
    let genericKeyCount: Int
    let genericParametersOffset: Int
    let requirementsOffset: Int

    init(_ shape: UnsafeRawPointer) {
        self.shape = shape
        flags = shape.loadUnaligned(as: UInt32.self)
        let requirementParameters = Int(shape.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
        requirementCount = Int(shape.loadUnaligned(fromByteOffset: 10, as: UInt16.self))
        let generalized = flags & 0x100 != 0
        genericParameterCount = generalized ? Int(shape.loadUnaligned(fromByteOffset: 16, as: UInt16.self)) : 0
        genericRequirementCount = generalized ? Int(shape.loadUnaligned(fromByteOffset: 18, as: UInt16.self)) : 0
        genericKeyCount = generalized ? Int(shape.loadUnaligned(fromByteOffset: 20, as: UInt16.self)) : 0
        var offset = 16 + (generalized ? 8 : 0)
        if flags & 0x200 != 0 { offset += 4 }
        if flags & 0x400 != 0 { offset += 4 }
        if flags & 0x800 == 0 { offset += requirementParameters }
        genericParametersOffset = offset
        if flags & 0x1000 == 0 { offset += genericParameterCount }
        requirementsOffset = (offset + 3) & ~3
    }

    var witnessCount: Int? {
        let depth: UInt64 = flags & 0x100 != 0 ? 1 : 0
        var count = 0
        for index in 0..<requirementCount {
            let requirement = shape.advanced(by: requirementsOffset + index * 12)
            guard requirement.loadUnaligned(as: UInt32.self) & 0x9f == 0x80 else { continue }
            guard let handle = ABICopySwiftGenericRequirementTypeSyntax(requirement, false) else { return nil }
            var subject = SwiftSyntax(adopting: handle).root
            while subject.kind == "Type" || subject.kind == "DependentMemberType" {
                guard let child = subject.children().first else { return nil }
                subject = child
            }
            let indices = subject.children()
            if subject.kind == "DependentGenericParamType", indices.count == 2,
               indices[0].index == depth, indices[1].index == 0 { count += 1 }
        }
        return count
    }
}

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
                guard let witnesses = SwiftExtendedExistentialShapeLayout(shape).witnessCount else { return nil }
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

    static func metadata(shape: String, constraints: [SwiftFormalType.ExistentialConstraint],
                         arguments: [Any.Type], resolver: SymbolResolver) throws -> Any.Type {
        try SwiftSyntheticExistentialShape.metadata(shape: shape, constraints: constraints, arguments: arguments, resolver: resolver)
    }

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

// Swift interns metadata by shape and keeps that shape's references permanently.
// Only synthesized descriptors and their protocol images share that lifetime.
private final class SwiftSyntheticExistentialShape: @unchecked Sendable {
    private struct Key: Hashable {
        let name: [UInt8]
        let subjects: [[UInt8]]
    }
    private static let shapes = Mutex<[Key: SwiftSyntheticExistentialShape]>([:])
    let address: UnsafeMutableRawPointer
    let images: [NativeImage]

    private init(address: UnsafeMutableRawPointer, images: [NativeImage]) {
        self.address = address
        self.images = images
    }
    deinit { ABIReleaseSwiftExtendedExistentialShape(address) }

    static func metadata(shape name: String, constraints: [SwiftFormalType.ExistentialConstraint],
                         arguments: [Any.Type], resolver: SymbolResolver) throws -> Any.Type {
        let key = Key(name: Array(name.utf8), subjects: constraints.map { Array($0.subject.utf8) })
        let shape: SwiftSyntheticExistentialShape
        if let cached = shapes.withLock({ $0[key] }) { shape = cached }
        else {
            let syntax = try SwiftSyntax(symbol: name)
            let shapeType = try syntax.root.requiredChild().requiredChild()
                .requiredChild(kind: "Type").requiredChild()
            var existential = shapeType
            while existential.kind == "ExistentialMetatype" {
                existential = try existential.requiredChild(kind: "Type").requiredChild()
            }
            var protocols: [SwiftProtocolDescriptor] = []
            var classBound = false
            func collect(_ node: SwiftSyntax.Node) throws {
                if node.kind == "ProtocolListWithClass" {
                    throw ABIResolutionError.metadataUnavailable("A superclass-constrained existential requires compiler-emitted metadata or its complete provider shape.")
                }
                if node.kind == "ProtocolListWithAnyObject" { classBound = true }
                if node.kind == "Protocol" {
                    let descriptor = SwiftProtocolDescriptor(try resolver.resolve(
                        .init(name: "protocol descriptor for " + node.name(), language: .swift, kind: .data),
                        in: .automatic, loading: .loadedOnly))
                    protocols.append(descriptor)
                    if unsafe descriptor.withUnsafeAddress({ $0.loadUnaligned(as: UInt32.self) & 0x10000 == 0 }) { classBound = true }
                    return
                }
                try node.children().forEach(collect)
            }
            try collect(existential.requiredChild(kind: "Type"))
            func mangled(_ descriptor: SwiftProtocolDescriptor) throws -> String {
                let metadata = unsafe descriptor.withUnsafeAddress { ABISwiftProtocolTypeMetadata($0)! }
                guard let name = _mangledTypeName(unsafeBitCast(metadata, to: Any.Type.self)) else {
                    throw ABIResolutionError.metadataUnavailable("The protocol's type spelling is unavailable.")
                }
                return name
            }
            var written: [String] = [], declaring: [String] = []
            var images = protocols.compactMap(\.image)
            for constraint in constraints {
                let components = constraint.subject.split(separator: ".").map(String.init)
                let member = components.last!
                let qualifier = components.count > 2 ? components.dropFirst().dropLast().joined(separator: ".") : nil
                var candidates: [(SwiftProtocolDescriptor, SwiftProtocolDescriptor)] = []
                for descriptor in protocols {
                    if let qualifier, try !descriptor.qualifiedNames().contains(qualifier) { continue }
                    for declaring in try descriptor.protocolsDeclaring(member)
                        where !candidates.contains(where: { $0.1 == declaring }) {
                        candidates.append((descriptor, declaring))
                    }
                }
                guard candidates.count == 1 else {
                    throw ABIResolutionError.metadataUnavailable("Cannot identify the declaring protocol for " + constraint.subject + ".")
                }
                written.append(try mangled(candidates[0].0))
                declaring.append(try mangled(candidates[0].1))
                if let image = candidates[0].1.image { images.append(image) }
            }
            let addresses = protocols.map { descriptor in Optional(unsafe descriptor.withUnsafeAddress { $0 }) }
            let candidate = try SwiftSyntheticExistentialShape(address: shapeType.makeExtendedExistentialShape(
                protocols: addresses, written: written, declaring: declaring, classBound: classBound), images: images)
            shape = shapes.withLock { values in
                if let cached = values[key] { return cached }
                values[key] = candidate
                return candidate
            }
        }
        let pointers = arguments.map { Optional(unsafeBitCast($0, to: UnsafeRawPointer.self)) }
        return withExtendedLifetime(shape) {
            pointers.withUnsafeBufferPointer {
                unsafeBitCast(ABISwiftExtendedExistentialMetadata(shape.address, $0.baseAddress)!, to: Any.Type.self)
            }
        }
    }
}
