import ABIBridgeCore

package struct RuntimeExtendedExistentialShapeLayout {
    package let shape: UnsafeRawPointer
    package let flags: UInt32
    package let requirementCount: Int
    package let genericParameterCount: Int
    package let genericRequirementCount: Int
    package let genericKeyCount: Int
    package let genericParametersOffset: Int
    package let requirementsOffset: Int

    package init(_ shape: UnsafeRawPointer) {
        self.shape = shape
        flags = shape.loadUnaligned(as: UInt32.self)
        let requirementParameters = Int(shape.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
        requirementCount = Int(shape.loadUnaligned(fromByteOffset: 10, as: UInt16.self))
        let generalized = flags & 0x100 != 0
        genericParameterCount =
            generalized ? Int(shape.loadUnaligned(fromByteOffset: 16, as: UInt16.self)) : 0
        genericRequirementCount =
            generalized ? Int(shape.loadUnaligned(fromByteOffset: 18, as: UInt16.self)) : 0
        genericKeyCount =
            generalized ? Int(shape.loadUnaligned(fromByteOffset: 20, as: UInt16.self)) : 0
        var offset = 16 + (generalized ? 8 : 0)
        if flags & 0x200 != 0 { offset += 4 }
        if flags & 0x400 != 0 { offset += 4 }
        if flags & 0x800 == 0 { offset += requirementParameters }
        genericParametersOffset = offset
        if flags & 0x1000 == 0 { offset += genericParameterCount }
        requirementsOffset = (offset + 3) & ~3
    }

    package var witnessCount: Int? {
        let depth: UInt64 = flags & 0x100 != 0 ? 1 : 0
        var count = 0
        for index in 0..<requirementCount {
            let requirement = shape.advanced(by: requirementsOffset + index * 12)
            guard requirement.loadUnaligned(as: UInt32.self) & 0x9f == 0x80 else { continue }
            guard let handle = ABICopySwiftGenericRequirementTypeSyntax(requirement, false) else {
                return nil
            }
            defer { ABIReleaseSwiftSyntax(handle) }
            var subject = ABISwiftSyntaxRoot(handle)!
            while String(cString: ABISwiftSyntaxNodeKind(subject)) == "Type" {
                guard let child = ABISwiftSyntaxNodeChild(subject, 0) else { return nil }
                subject = child
            }
            if String(cString: ABISwiftSyntaxNodeKind(subject)) == "DependentGenericParamType",
                ABISwiftSyntaxNodeChildCount(subject) == 2,
                let first = ABISwiftSyntaxNodeChild(subject, 0),
                let second = ABISwiftSyntaxNodeChild(subject, 1),
                ABISwiftSyntaxNodeHasIndex(first), ABISwiftSyntaxNodeIndex(first) == depth,
                ABISwiftSyntaxNodeHasIndex(second), ABISwiftSyntaxNodeIndex(second) == 0
            {
                count += 1
            }
        }
        return count
    }
}
extension RuntimeExtendedExistentialShapeLayout {
    package init(nonUniqueDescriptor address: UnsafeRawPointer) {
        self.init(address.advanced(by: 4))
    }
    package var genericParameters: [UInt8] {
        (0..<genericParameterCount).map {
            flags & 0x1000 != 0
                ? UInt8(0x80)
                : shape.load(fromByteOffset: genericParametersOffset + $0, as: UInt8.self)
        }
    }
    package var genericRequirements: [RuntimeGenericRequirement] {
        let offset = requirementsOffset + requirementCount * 12
        return (0..<genericRequirementCount).map {
            RuntimeGenericRequirement(shape.advanced(by: offset + $0 * 12))
        }
    }
}
