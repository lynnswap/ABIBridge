import ABIBridgeRuntime
import ABIBridgeCore
import ObjectiveC
import Synchronization

typealias SwiftExtendedExistentialShapeLayout = RuntimeExtendedExistentialShapeLayout

// Simple existential metadata has a kind word followed by 32-bit flags.
// Extended shapes preserve their constraint signature and container convention.
// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h
typealias SwiftExistentialRepresentation = RuntimeExistentialRepresentation

extension RuntimeExistentialRepresentation {
    func valueType<Value>(for type: Value.Type) throws -> CValueType {
        try withRuntimeErrors { CValueType(try runtimeValueType(for: type)) }
    }
}

/// Concrete classes and Objective-C-compatible existentials satisfy Swift's
/// object constraints. A Swift protocol existential with witness tables does
/// not itself satisfy an AnyObject generic parameter.
typealias SwiftObjectType = RuntimeObjectType

/// Uses the provider's generalized shape when the caller has no concrete
/// existential metadata. The descriptor owns the signature and witness order.
struct SwiftExtendedExistentialMetadata {
    static func formalType(_ metadata: Any.Type) throws -> SwiftFormalType {
        try SwiftFormalType(SwiftSyntax.metadataType(metadata))
    }

    let value: Any.Type

    static func metadata(
        shape: String,
        constraints: [SwiftFormalType.ExistentialConstraint],
        arguments: [Any.Type],
        superclass: SwiftGenericTypeMetadata?,
        resolver: SymbolResolver
    ) throws -> Any.Type {
        try SwiftSyntheticExistentialShape.metadata(
            shape: shape,
            constraints: constraints,
            arguments: arguments,
            superclass: superclass,
            resolver: resolver
        )
    }

    init(descriptor: ResolvedSymbol, arguments: [Any.Type], resolver: SymbolResolver) throws {
        value = try unsafe descriptor.withUnsafeAddress { address in
            try Self.metadata(
                address: address,
                arguments: arguments,
                resolver: resolver,
                image: descriptor.image
            )
        }
    }

    static func metadata(
        address: UnsafeRawPointer,
        arguments: [Any.Type],
        resolver: SymbolResolver,
        image: NativeImage? = nil
    ) throws -> Any.Type {
        let layout = RuntimeExtendedExistentialShapeLayout(nonUniqueDescriptor: address)
        let keyCount = layout.genericKeyCount
        let parameters = layout.genericParameters
        let rawRequirements = layout.genericRequirements
        let requirements = try rawRequirements.map(SwiftMetadataRequirement.init)
        let declaration = SwiftGenericDeclaration(
            parameters: parameters.indices.map {
                .init(
                    name: SwiftFormalType.parameterName(depth: 0, index: $0),
                    isPack: parameters[$0] & 0x3f == 1
                )
            },
            requirements: requirements.map(\.value),
            arguments: [],
            result: .tuple([]),
            failure: nil,
            isAsync: false,
            consumesArguments: false
        )
        let binding = try SwiftGenericBinding(
            declaration: declaration,
            arguments: arguments.map { .type($0) },
            signature: SwiftFunctionSignature((() -> Void).self),
            resolver: resolver,
            image: image
        )
        var words: [UnsafeRawPointer?] = parameters.enumerated().filter { $0.element & 0x80 != 0 }
            .map {
                unsafeBitCast(arguments[$0.offset], to: UnsafeRawPointer.self)
            }
        for (index, requirement) in requirements.enumerated()
        where rawRequirements[index].isKey {
            guard let protocolType = requirement.descriptor else {
                throw ABIResolutionError.metadataUnavailable(
                    "The extended existential requires an unavailable witness."
                )
            }
            let type = try binding.types(requirement.subject)[0]
            let witness = unsafe protocolType.withUnsafeAddress {
                ABISwiftConformance(unsafeBitCast(type, to: UnsafeRawPointer.self), $0)
            }
            words.append(witness)
        }
        guard words.count == keyCount else {
            throw ABIResolutionError.metadataUnavailable(
                "The extended existential generalization arguments are incomplete."
            )
        }
        return withExtendedLifetime(binding) {
            words.withUnsafeBufferPointer {
                unsafeBitCast(
                    ABISwiftExtendedExistentialMetadata(address, $0.baseAddress)!,
                    to: Any.Type.self
                )
            }
        }
    }
}

// Swift interns metadata by shape and keeps that shape's references permanently.
// Synthesized descriptors and their referenced declaration images share that lifetime.
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

    static func metadata(
        shape name: String,
        constraints: [SwiftFormalType.ExistentialConstraint],
        arguments: [Any.Type],
        superclass: SwiftGenericTypeMetadata?,
        resolver: SymbolResolver
    ) throws -> Any.Type {
        let key = Key(name: Array(name.utf8), subjects: constraints.map { Array($0.subject.utf8) })
        let shape: SwiftSyntheticExistentialShape
        if let cached = shapes.withLock({ $0[key] }) {
            shape = cached
        } else {
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
                if node.kind == "ProtocolListWithClass" || node.kind == "ProtocolListWithAnyObject"
                {
                    classBound = true
                }
                if node.kind == "Protocol" {
                    let descriptor = SwiftProtocolDescriptor(
                        try resolver.resolve(
                            .init(
                                name: "protocol descriptor for " + node.name(),
                                language: .swift,
                                kind: .data
                            ),
                            in: .automatic,
                            loading: .loadedOnly
                        )
                    )
                    protocols.append(descriptor)
                    if unsafe descriptor.withUnsafeAddress({
                        $0.loadUnaligned(as: UInt32.self) & 0x10000 == 0
                    }) {
                        classBound = true
                    }
                    return
                }
                try node.children().forEach(collect)
            }
            try collect(existential.requiredChild(kind: "Type"))
            func mangled(_ descriptor: SwiftProtocolDescriptor) throws -> String {
                let metadata = unsafe descriptor.withUnsafeAddress {
                    ABISwiftProtocolTypeMetadata($0)!
                }
                guard let name = _mangledTypeName(unsafeBitCast(metadata, to: Any.Type.self)) else {
                    throw ABIResolutionError.metadataUnavailable(
                        "The protocol's type spelling is unavailable."
                    )
                }
                return name
            }
            var written: [String] = [], declaring: [String] = []
            var images = protocols.compactMap(\.image)
            if let superclass {
                if let descriptor = ABISwiftTypeDescriptor(
                    unsafeBitCast(superclass.value, to: UnsafeRawPointer.self)
                ),
                    let image = try swiftImplementationImage(containing: descriptor)
                {
                    images.append(image)
                }
                let context = try SwiftGenericTypeContext(metadata: superclass.value)
                images += context.conformances.compactMap { $0.descriptor?.image }
            }
            for constraint in constraints {
                let components = constraint.subject.split(separator: ".").map(String.init)
                let member = components.last!
                let qualifier =
                    components.count > 2
                    ? components.dropFirst().dropLast().joined(separator: ".") : nil
                var candidates: [(SwiftProtocolDescriptor, SwiftProtocolDescriptor)] = []
                for descriptor in protocols {
                    if let qualifier, try !descriptor.qualifiedNames().contains(qualifier) {
                        continue
                    }
                    for declaring in try descriptor.protocolsDeclaring(member)
                    where !candidates.contains(where: { $0.1 == declaring }) {
                        candidates.append((descriptor, declaring))
                    }
                }
                guard candidates.count == 1 else {
                    throw ABIResolutionError.metadataUnavailable(
                        "Cannot identify the declaring protocol for " + constraint.subject + "."
                    )
                }
                written.append(try mangled(candidates[0].0))
                declaring.append(try mangled(candidates[0].1))
                if let image = candidates[0].1.image { images.append(image) }
            }
            let addresses = protocols.map { descriptor in
                Optional(unsafe descriptor.withUnsafeAddress { $0 })
            }
            let candidate = try SwiftSyntheticExistentialShape(
                address: shapeType.makeExtendedExistentialShape(
                    protocols: addresses,
                    written: written,
                    declaring: declaring,
                    classBound: classBound,
                    superclass: superclass?.value
                ),
                images: images
            )
            shape = shapes.withLock { values in
                if let cached = values[key] { return cached }
                values[key] = candidate
                return candidate
            }
        }
        return try withExtendedLifetime(shape) {
            try SwiftExtendedExistentialMetadata.metadata(
                address: shape.address,
                arguments: arguments,
                resolver: resolver
            )
        }
    }
}
