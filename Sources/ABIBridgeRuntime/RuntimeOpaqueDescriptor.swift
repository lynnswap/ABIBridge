import ABIBridgeCore

package struct RuntimeOpaqueDescriptor {
    package struct Requirement {
        package let flags: UInt32
        package let value: RuntimeGenericRequirement
        package let classBound: Bool
    }
    package struct PackShape {
        package let kind: UInt16
        package let argument: Int
        package let shape: Int
    }

    package let parameters: [UInt8]
    package let requirements: [Requirement]
    package let shapes: [PackShape]
    package let shapeCount: Int
    package let capturedArgumentCount: Int

    package init(_ descriptor: RuntimeSymbol) throws {
        let extent = descriptor.sectionRange.upperBound - descriptor.address
        guard extent >= 16 else {
            throw RuntimeResolutionError.metadataUnavailable("Incomplete opaque descriptor.")
        }
        self = try unsafe descriptor.withUnsafeAddress { address in
            let flags = address.loadUnaligned(as: UInt32.self)
            guard flags & 0x1f == 4, flags & 0x80 != 0 else {
                throw RuntimeResolutionError.metadataUnavailable(
                    "Expected an opaque type descriptor."
                )
            }
            let count = Int(address.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
            let requirementCount = Int(
                address.loadUnaligned(fromByteOffset: 10, as: UInt16.self)
            )
            let keyCount = Int(address.loadUnaligned(fromByteOffset: 12, as: UInt16.self))
            let genericFlags = address.loadUnaligned(fromByteOffset: 14, as: UInt16.self)
            let underlying = Int(flags >> 16)
            let requirementsOffset = (16 + count + 3) & ~3
            guard count > 0, underlying > 0, keyCount >= underlying,
                requirementsOffset + requirementCount * 12 <= extent
            else {
                throw RuntimeResolutionError.metadataUnavailable(
                    "Incomplete opaque generic context."
                )
            }
            let parameters = (0..<count).map {
                address.load(fromByteOffset: 16 + $0, as: UInt8.self)
            }
            let requirements = (0..<requirementCount).map { index in
                let requirement = address.advanced(by: requirementsOffset + index * 12)
                let flags = requirement.loadUnaligned(as: UInt32.self)
                return Requirement(
                    flags: flags,
                    value: RuntimeGenericRequirement(requirement),
                    classBound: flags & 0x1f == 0
                        && ABISwiftProtocolRequirementIsClassBound(requirement.advanced(by: 8))
                )
            }
            var shapes: [PackShape] = [], shapeCount = 0
            if genericFlags & 1 != 0 {
                let offset = requirementsOffset + requirementCount * 12
                guard offset + 4 <= extent else {
                    throw RuntimeResolutionError.metadataUnavailable(
                        "Incomplete opaque pack shapes."
                    )
                }
                let packCount = Int(
                    address.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                )
                shapeCount = Int(
                    address.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self)
                )
                guard offset + 4 + packCount * 8 <= extent else {
                    throw RuntimeResolutionError.metadataUnavailable(
                        "Incomplete opaque pack shapes."
                    )
                }
                shapes = (0..<packCount).map { index in
                    let entry = address.advanced(by: offset + 4 + index * 8)
                    return PackShape(
                        kind: entry.loadUnaligned(as: UInt16.self),
                        argument: Int(entry.loadUnaligned(fromByteOffset: 2, as: UInt16.self)),
                        shape: Int(entry.loadUnaligned(fromByteOffset: 4, as: UInt16.self))
                    )
                }
            }
            return RuntimeOpaqueDescriptor(
                parameters: parameters,
                requirements: requirements,
                shapes: shapes,
                shapeCount: shapeCount,
                capturedArgumentCount: keyCount - underlying
            )
        }
    }

    private init(
        parameters: [UInt8],
        requirements: [Requirement],
        shapes: [PackShape],
        shapeCount: Int,
        capturedArgumentCount: Int
    ) {
        self.parameters = parameters; self.requirements = requirements
        self.shapes = shapes; self.shapeCount = shapeCount
        self.capturedArgumentCount = capturedArgumentCount
    }

}
