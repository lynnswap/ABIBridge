import ABIBridgeCore
import Foundation

private func swiftGenericRequirementSubject(_ subject: String, qualifiers: Set<String>) -> String {
    // A symbolic protocol reference was replaced with __C.<identifier>.
    // Objective-C protocols cannot declare associated types, so this synthetic
    // qualification is unambiguous in a dependent member path.
    var name = subject.replacingOccurrences(of: #"\.__C\.[^.]+\."#, with: ".", options: .regularExpression)
    for qualifier in qualifiers.sorted(by: { $0.count > $1.count }) {
        name = name.replacingOccurrences(of: "." + qualifier + ".", with: ".")
    }
    return name
}

/// A descriptor can come from a symbol or from an instantiated type's context.
struct SwiftProtocolDescriptor: Sendable {
    private let address: UInt
    let image: NativeImage?

    init(_ symbol: ResolvedSymbol) {
        address = unsafe symbol.withUnsafeAddress { UInt(bitPattern: $0) }
        image = symbol.image
    }

    init(address: UnsafeRawPointer) throws {
        self.address = UInt(bitPattern: address)
        image = try swiftImplementationImage(containing: address)
    }

    @unsafe func withUnsafeAddress<Result>(_ body: (UnsafeRawPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawPointer(bitPattern: address)!)
    }

    func name() throws -> String {
        let metadata = unsafe withUnsafeAddress { ABISwiftProtocolTypeMetadata($0)! }
        return try swiftNativeTypeName(unsafeBitCast(metadata, to: Any.Type.self))
    }

    func associatedConformances(of member: String) throws -> [SwiftProtocolDescriptor] {
        var visited: Set<UInt> = []
        var matches: [SwiftProtocolDescriptor] = []
        func visit(_ descriptor: SwiftProtocolDescriptor) throws {
            guard visited.insert(descriptor.address).inserted else { return }
            let qualifiers = try descriptor.qualifiedNames()
            try unsafe descriptor.withUnsafeAddress { address in
                let count = Int(address.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                for index in 0..<count {
                    let requirement = address.advanced(by: 24 + index * 12)
                    guard requirement.loadUnaligned(as: UInt32.self) & 0x1f == 0,
                          let protocolAddress = ABISwiftProtocolRequirementDescriptor(requirement.advanced(by: 8)),
                          let reference = ABICopySwiftGenericRequirementSubject(requirement) else { continue }
                    defer { ABIFreeString(reference) }
                    guard let subject = DeclarationKey.demangle(String(cString: reference), language: .swift) else { continue }
                    let inherited = try SwiftProtocolDescriptor(address: protocolAddress)
                    if subject == "A" { try visit(inherited) }
                    else if swiftGenericRequirementSubject(subject, qualifiers: qualifiers) == "A." + member {
                        matches.append(inherited)
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
                          let base = ABISwiftProtocolRequirementDescriptor(requirement.advanced(by: 8)) else { continue }
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

    init(metadata: Any.Type) throws {
        var failure: OpaquePointer?
        guard let result = ABICopySwiftTypeMetadata(unsafeBitCast(metadata, to: UnsafeRawPointer.self), &failure) else {
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
                throw ABIResolutionError.metadataUnavailable("Cannot decode the generic parameter " + reference + ".")
            }
            parameters.append(.init(name: name, isPack: ABISwiftTypeMetadataArgumentIsPack(result, index)))
            if ABISwiftTypeMetadataArgumentIsKey(result, index) { keyParameters.insert(name) }
        }
        self.parameters = parameters
        self.keyParameters = keyParameters
        var requirements: [(String, SwiftProtocolDescriptor?)] = []
        var qualifiers: Set<String> = []
        for index in 0..<ABISwiftTypeMetadataRequirementCount(result) {
            let reference = String(cString: ABISwiftTypeMetadataRequirementSubject(result, index)!)
            guard let subject = DeclarationKey.demangle(reference, language: .swift) else {
                throw ABIResolutionError.metadataUnavailable("Cannot decode the generic requirement " + reference + ".")
            }
            let descriptor = try ABISwiftTypeMetadataRequirementProtocol(result, index).map {
                try SwiftProtocolDescriptor(address: $0)
            }
            if let descriptor { qualifiers.formUnion(try descriptor.qualifiedNames()) }
            requirements.append((subject, descriptor))
        }
        conformances = try requirements.map { subject, descriptor in
            let name = swiftGenericRequirementSubject(subject, qualifiers: qualifiers)
            return try .init(subject: SwiftFormalType(name),
                             name: descriptor?.name() ?? "Swift.AnyObject", descriptor: descriptor)
        }
    }
}
