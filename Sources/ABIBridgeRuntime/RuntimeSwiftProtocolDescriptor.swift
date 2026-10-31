import ABIBridgeCore
import ABIBridgeCore.Backend
import Synchronization

/// A protocol's requirement identities and their native witness-table slots.
package struct RuntimeSwiftProtocolDescriptor: Sendable {
    private static let descriptors = Mutex<[UInt64: Self]>([:])

    package static func cached(
        symbol: RuntimeSymbol,
        resolver: RuntimeSymbolResolver
    ) throws -> Self {
        if let cached = descriptors.withLock({ $0[symbol.address] }) { return cached }
        // Parsing can resolve symbols and acquire image leases. Do that work
        // outside the process cache lock, then publish one successful result.
        let candidate = try Self(symbol: symbol, resolver: resolver)
        return withExtendedLifetime(candidate) {
            descriptors.withLock { descriptors in
                if let cached = descriptors[symbol.address] { return cached }
                descriptors[symbol.address] = candidate
                return candidate
            }
        }
    }

    package struct Requirement: Sendable {
        package let identity: String
        package let name: String
        /// The witness-table index, including its leading conformance descriptor.
        package let slot: Int
        package let flags: UInt32
    }

    package let symbol: RuntimeSymbol
    package let protocolName: String
    package let requirements: [Requirement]

    package init(symbol: RuntimeSymbol, resolver: RuntimeSymbolResolver) throws {
        self.symbol = symbol
        let prefix = "protocol descriptor for "
        let spelling =
            DeclarationKey.demangle(symbol.linkageName, language: .swift)
            ?? symbol.declaration.name
        guard spelling.hasPrefix(prefix) else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "Expected a Swift protocol descriptor, found \(spelling)."
            )
        }
        let protocolName = String(spelling.dropFirst(prefix.count))
        self.protocolName = protocolName
        requirements = try unsafe symbol.withUnsafeAddress { address in
            let layout = RuntimeProtocolLayout(address)
            guard address.loadUnaligned(as: UInt32.self) & 0x10000 == 0 else {
                throw RuntimeResolutionError.unsupportedDeclaration(
                    "\(protocolName) must be class-bound to create a protocol value."
                )
            }
            guard layout.associatedTypes.isEmpty else {
                throw RuntimeResolutionError.unsupportedDeclaration(
                    "\(protocolName) has associated types; protocol values require a protocol without associated types."
                )
            }
            for requirement in layout.requirements {
                if requirement.isInheritedProtocol {
                    throw RuntimeResolutionError.unsupportedDeclaration(
                        "\(protocolName) inherits another protocol; inherited protocol values are not supported."
                    )
                }
                // The implicit Self: AnyObject requirement is the only
                // generic signature constraint in this initial contract.
                let field = requirement.address.advanced(by: 4)
                let subject = field.advanced(by: Int(field.loadUnaligned(as: Int32.self)))
                guard requirement.kind == 31, requirement.isClassLayout,
                    subject.load(as: UInt8.self) == 120,
                    subject.load(fromByteOffset: 1, as: UInt8.self) == 0
                else {
                    throw RuntimeResolutionError.unsupportedDeclaration(
                        "\(protocolName) has unsupported generic or superclass requirements."
                    )
                }
            }

            let entries = layout.witnessRequirements
            for (index, requirement) in entries.enumerated() {
                guard requirement.kind == 1, requirement.isInstance, !requirement.isAsync else {
                    throw RuntimeResolutionError.unsupportedDeclaration(
                        "\(protocolName) requirement \(index + 1) must be a synchronous instance method."
                    )
                }
            }
            var identities = entries.map {
                resolver.swiftMethodDescriptorRequirements(
                    at: UInt64(UInt(bitPattern: $0.address)),
                    in: symbol.image
                )
            }
            if identities.contains(where: \.isEmpty) {
                try Self.completeRequirementIdentities(
                    &identities,
                    protocolAddress: address,
                    image: symbol.image,
                    resolver: resolver
                )
            }
            return try entries.enumerated().map { index, requirement in
                guard identities[index].count == 1,
                    let identity = identities[index].first,
                    let name = DeclarationKey.demangle(identity, language: .swift)
                else {
                    throw RuntimeResolutionError.metadataUnavailable(
                        "The identity of \(protocolName) requirement \(index + 1) is not uniquely established by its method descriptor or original conformance witnesses."
                    )
                }
                return Requirement(
                    identity: identity,
                    name: name,
                    slot: index + 1,
                    flags: requirement.flags
                )
            }
        }
    }

    private static func completeRequirementIdentities(
        _ identities: inout [Set<String>],
        protocolAddress: UnsafeRawPointer,
        image: RuntimeImage,
        resolver: RuntimeSymbolResolver
    ) throws {
        var visited: Set<RuntimeImageIdentity> = []
        func inspect(_ image: RuntimeImage) throws {
            guard visited.insert(image.identity).inserted else { return }
            let anchor = UnsafeRawPointer(bitPattern: UInt(image.identity.headerAddress))!
            let count = ABISwiftImageConformanceDescriptors(anchor, protocolAddress, nil, 0)
            guard count != 0 else { return }
            var descriptors = [UnsafeRawPointer?](repeating: nil, count: count)
            let copied = descriptors.withUnsafeMutableBufferPointer {
                ABISwiftImageConformanceDescriptors(
                    anchor,
                    protocolAddress,
                    $0.baseAddress,
                    $0.count
                )
            }
            var targets: [UInt64: UInt64]?
            for descriptor in descriptors.prefix(min(count, copied)).compactMap({ $0 }) {
                // Generic or resilient conformances can have partial patterns.
                // Their slot names require method descriptors instead.
                let flags = descriptor.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                guard flags & 0x30000 == 0,
                    let table = ABISwiftConformanceWitnessTablePattern(descriptor)
                else { continue }
                let witnesses = resolver.swiftWitnesses(
                    ofConformanceAt: UInt64(UInt(bitPattern: descriptor)),
                    in: image
                )
                guard !witnesses.isEmpty else { continue }
                if targets == nil {
                    targets = try OriginalImageMetadata(image: image).pointerTargets()
                }
                var names: [UInt64: Set<String>] = [:]
                for witness in witnesses {
                    if let identity = witness.record.requirement {
                        names[witness.symbol.address, default: []].insert(identity)
                    }
                }
                for index in identities.indices where identities[index].isEmpty {
                    let slot =
                        UInt64(UInt(bitPattern: table))
                        + UInt64((index + 1) * MemoryLayout<UInt>.size)
                    if let target = targets?[slot], let found = names[target] {
                        identities[index].formUnion(found)
                    }
                }
            }
        }
        try inspect(image)
        if identities.contains(where: \.isEmpty) {
            for candidate in try resolver.images(matching: .automatic) {
                try inspect(candidate)
                if !identities.contains(where: \.isEmpty) { break }
            }
        }
    }
}
