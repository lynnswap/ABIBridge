import ABIBridgeRuntime
import ABIBridgeCore
import Foundation
import ObjectiveC

/// A descriptor can come from a symbol or from an instantiated type's context.
struct SwiftProtocolDescriptor: Sendable, Equatable {
    private let address: UInt
    let image: NativeImage?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.address == rhs.address }

    init(_ symbol: ResolvedSymbol) {
        address = unsafe symbol.withUnsafeAddress { UInt(bitPattern: $0) }
        image = symbol.image
    }

    init(address: UnsafeRawPointer) throws {
        self.address = UInt(bitPattern: address)
        image = try swiftImplementationImage(containing: address)
    }

    @unsafe func withUnsafeAddress<Result>(
        _ body: (UnsafeRawPointer) throws -> Result
    ) rethrows -> Result {
        try body(UnsafeRawPointer(bitPattern: address)!)
    }

    func name() throws -> String {
        let metadata = unsafe withUnsafeAddress { ABISwiftProtocolTypeMetadata($0)! }
        return try swiftNativeTypeName(unsafeBitCast(metadata, to: Any.Type.self))
    }

    /// Declaration ordering ignores private-name discriminators, which are
    /// identity information rather than identifier names in TypeDecl::compare.
    func orderingPath() throws -> [String] {
        let metadata = unsafe withUnsafeAddress { ABISwiftProtocolTypeMetadata($0)! }
        guard let mangled = _mangledTypeName(unsafeBitCast(metadata, to: Any.Type.self)) else {
            throw ABIResolutionError.metadataUnavailable(
                "The protocol's declaration identity is unavailable."
            )
        }
        let syntax = try mangled.utf8CString.withUnsafeBufferPointer {
            try unsafe SwiftSyntax(typeReference: $0.baseAddress!, length: $0.count - 1)
        }
        var node = syntax.root
        while node.kind != "Protocol" { node = try node.requiredChild() }
        func path(_ node: SwiftSyntax.Node) throws -> [String] {
            if node.kind == "Module" { return [try node.requiredText()] }
            if node.kind == "Extension" || node.kind == "AnonymousContext" {
                return try path(node.children()[1])
            }
            if node.kind == "Type" { return try path(node.requiredChild()) }
            let children = node.children()
            let name = children[1]
            guard
                let identifier = name.kind == "Identifier"
                    ? name : name.children().last(where: { $0.kind == "Identifier" })
            else {
                throw ABIResolutionError.metadataUnavailable(
                    "The protocol context has no declaration name."
                )
            }
            return try path(children[0]) + [identifier.requiredText()]
        }
        return try path(node)
    }

    func associatedConformances(of member: String) throws -> [SwiftProtocolDescriptor] {
        try associatedRequirements(of: member).compactMap(\.descriptor)
    }

    func protocolsDeclaring(_ member: String) throws -> [SwiftProtocolDescriptor] {
        var visited: Set<UInt> = [], result: [SwiftProtocolDescriptor] = []
        func visit(_ descriptor: SwiftProtocolDescriptor) throws {
            guard visited.insert(descriptor.address).inserted else { return }
            try unsafe descriptor.withUnsafeAddress { address in
                let field = address.advanced(by: 20)
                let offset = Int(field.loadUnaligned(as: Int32.self))
                if offset != 0,
                    String(cString: field.advanced(by: offset).assumingMemoryBound(to: CChar.self))
                        .split(separator: " ").contains(Substring(member))
                {
                    result.append(descriptor)
                }
                let count = Int(address.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                for index in 0..<count {
                    let requirement = try SwiftMetadataRequirement(
                        address.advanced(by: 24 + index * 12)
                    )
                    if requirement.subject == .named("A", []),
                        let inherited = requirement.descriptor
                    {
                        try visit(inherited)
                    }
                }
            }
        }
        try visit(self)
        return result
    }

    func associatedRequirements(of member: String) throws -> [SwiftMetadataRequirement] {
        var visited: Set<UInt> = []
        var matches: [SwiftMetadataRequirement] = []
        func visit(_ descriptor: SwiftProtocolDescriptor) throws {
            guard visited.insert(descriptor.address).inserted else { return }
            try unsafe descriptor.withUnsafeAddress { address in
                let count = Int(address.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                for index in 0..<count {
                    let requirement = try SwiftMetadataRequirement(
                        address.advanced(by: 24 + index * 12)
                    )
                    if requirement.subject == .named("A", []),
                        let inherited = requirement.descriptor
                    {
                        try visit(inherited)
                    } else if case .associated(.named("A", []), member, _) = requirement.subject {
                        matches.append(requirement)
                    }
                }
            }
        }
        try visit(self)
        return matches
    }

    /// Names used to qualify associated types include inherited protocols.
    func qualifiedNames() throws -> Set<String> {
        var visited: Set<UInt> = []
        var names: Set<String> = []
        func visit(_ descriptor: SwiftProtocolDescriptor) throws {
            guard visited.insert(descriptor.address).inserted else { return }
            names.insert(try descriptor.name())
            try unsafe descriptor.withUnsafeAddress { address in
                let count = Int(address.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                for index in 0..<count {
                    let requirement = address.advanced(by: 24 + index * 12)
                    guard requirement.loadUnaligned(as: UInt32.self) & 0x1f == 0 else { continue }
                    let field = requirement.advanced(by: 4)
                    let subject = field.advanced(by: Int(field.loadUnaligned(as: Int32.self)))
                    guard subject.load(as: UInt8.self) == 120,
                        subject.load(fromByteOffset: 1, as: UInt8.self) == 0,
                        let base = ABISwiftProtocolRequirementDescriptor(
                            requirement.advanced(by: 8)
                        )
                    else { continue }
                    try visit(SwiftProtocolDescriptor(address: base))
                }
            }
        }
        try visit(self)
        return names
    }
}

/// The nominal declaration contributes implicit parameters and requirements to
/// each member. Completed metadata has already validated these requirements.
struct SwiftGenericTypeContext: Sendable {
    let parameters: [SwiftGenericDeclaration.Parameter]
    let keyParameters: Set<String>
    let conformances: [SwiftGenericBinding.Conformance]
    let requirements: [SwiftGenericDeclaration.Requirement]

    init(metadata: Any.Type) throws {
        var failure: OpaquePointer?
        guard
            let result = ABICopySwiftTypeMetadata(
                unsafeBitCast(metadata, to: UnsafeRawPointer.self),
                &failure
            )
        else {
            throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftMetadata")
        }
        defer { ABIReleaseSwiftTypeMetadata(result) }
        guard ABIPrepareSwiftTypeMetadataContext(result, &failure) else {
            throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftMetadata")
        }
        var parameters: [SwiftGenericDeclaration.Parameter] = []
        var keyParameters: Set<String> = []
        for index in 0..<ABISwiftTypeMetadataArgumentCount(result) {
            let reference = String(cString: ABISwiftTypeMetadataParameterReference(result, index)!)
            guard let name = DeclarationKey.demangle(reference, language: .swift) else {
                throw ABIResolutionError.metadataUnavailable(
                    "Cannot decode the generic parameter " + reference + "."
                )
            }
            parameters.append(
                .init(name: name, isPack: ABISwiftTypeMetadataArgumentIsPack(result, index))
            )
            if ABISwiftTypeMetadataArgumentIsKey(result, index) { keyParameters.insert(name) }
        }
        self.parameters = parameters
        self.keyParameters = keyParameters
        let decoded = try (0..<ABISwiftTypeMetadataRequirementCount(result)).map { index in
            try SwiftMetadataRequirement(ABISwiftTypeMetadataRequirement(result, index)!)
        }
        requirements = decoded.map(\.value)
        conformances = decoded.compactMap { requirement in
            guard case .conformance(let subject, let name) = requirement.value else { return nil }
            return .init(
                subject: subject,
                name: name,
                descriptor: requirement.descriptor,
                objectiveC: requirement.objectiveC
            )
        }
    }
}

struct SwiftObjectiveCProtocol: Sendable {
    private let address: UInt
    let name: String
    let image: NativeImage?

    init(_ value: Protocol) throws {
        let address = unsafeBitCast(value, to: UnsafeRawPointer.self)
        self.address = UInt(bitPattern: address)
        name = String(cString: protocol_getName(value))
        image = try swiftImplementationImage(containing: address)
    }

    func accepts(_ type: Any.Type) -> Bool {
        SwiftObjectType(type)?.conforms(to: unsafeBitCast(address, to: Protocol.self)) ?? false
    }
}

struct SwiftMetadataRequirement {
    let subject: SwiftFormalType
    let value: SwiftGenericDeclaration.Requirement
    var descriptor: SwiftProtocolDescriptor? = nil
    var objectiveC: SwiftObjectiveCProtocol? = nil

    init(_ address: UnsafeRawPointer) throws {
        func type(constraint: Bool) throws -> SwiftFormalType {
            guard let handle = ABICopySwiftGenericRequirementTypeSyntax(address, constraint) else {
                throw ABIResolutionError.metadataUnavailable(
                    "Cannot decode the Swift generic requirement type."
                )
            }
            return try SwiftFormalType(SwiftSyntax(adopting: handle).root)
        }
        subject = try type(constraint: false)
        switch address.loadUnaligned(as: UInt32.self) & 0x1f {
        case 0:
            if let protocolAddress = ABISwiftProtocolRequirementDescriptor(address.advanced(by: 8))
            {
                let descriptor = try SwiftProtocolDescriptor(address: protocolAddress)
                self.descriptor = descriptor
                value = .conformance(subject, try descriptor.name())
            } else if let protocolAddress = ABISwiftProtocolRequirementObjectiveCProtocol(
                address.advanced(by: 8)
            ) {
                let protocolValue = try SwiftObjectiveCProtocol(
                    unsafeBitCast(protocolAddress, to: Protocol.self)
                )
                objectiveC = protocolValue
                value = .conformance(subject, protocolValue.name)
            } else {
                throw ABIResolutionError.metadataUnavailable(
                    "The Swift generic protocol requirement is unavailable."
                )
            }
        case 1: value = .sameType(subject, try type(constraint: true))
        case 2: value = .superclass(subject, try type(constraint: true))
        case 4: value = .sameShape(subject, try type(constraint: true))
        case 5:
            value = .invertedProtocols(
                subject,
                address.loadUnaligned(fromByteOffset: 10, as: UInt16.self)
            )
        case 31:
            guard address.loadUnaligned(fromByteOffset: 8, as: UInt32.self) == 0 else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "The Swift metadata layout requirement is not a class constraint."
                )
            }
            value = .conformance(subject, "Swift.AnyObject")
        default:
            throw ABIResolutionError.unsupportedDeclaration(
                "Cannot decode this Swift metadata generic requirement."
            )
        }
    }
}
