import ABIBridgeCore

package struct RuntimeFunctionMetadata: Sendable {
    package let flags: UInt
    package let parameters: [Any.Type]
    package let result: Any.Type
    package let failure: Any.Type
    package let parameterFlags: [UInt32]
    package enum Isolation: UInt32, Sendable { case none = 0, isolatedAny = 2, caller = 4 }
    package enum Differentiability: UInt, Sendable {
        case none = 0, forward = 1, reverse = 2, normal = 3, linear = 4
    }
    package let isAsync: Bool
    package let isEscaping: Bool
    package let isSendable: Bool
    package let isolation: Isolation
    package let differentiability: Differentiability
    package let hasSendingResult: Bool
    package let globalActor: Any.Type?
    package let extendedFlags: UInt32

    package init(_ type: Any.Type) throws {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let word = MemoryLayout<UInt>.size
        guard metadata.load(as: UInt.self) == 0x302 else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "Expected a Swift function type: \(String(reflecting: type))."
            )
        }
        flags = metadata.load(fromByteOffset: word, as: UInt.self)
        let count = Int(flags & 0xffff)
        result = metadata.load(fromByteOffset: 2 * word, as: Any.Type.self)
        parameters = (0..<count).map {
            metadata.load(fromByteOffset: (3 + $0) * word, as: Any.Type.self)
        }
        var offset = (3 + count) * word
        parameterFlags =
            flags & 0x02000000 != 0
            ? (0..<count).map { metadata.load(fromByteOffset: offset + $0 * 4, as: UInt32.self) }
            : Array(repeating: 0, count: count)
        if flags & 0x02000000 != 0 { offset += count * 4 }
        func alignToWord() { offset = (offset + word - 1) & ~(word - 1) }
        alignToWord()
        let differentiability =
            flags & 0x08000000 != 0 ? metadata.load(fromByteOffset: offset, as: UInt.self) : 0
        if flags & 0x08000000 != 0 { offset += word }
        globalActor =
            flags & 0x10000000 != 0 ? metadata.load(fromByteOffset: offset, as: Any.Type.self) : nil
        if flags & 0x10000000 != 0 { offset += word }
        let extended =
            flags & 0x80000000 != 0 ? metadata.load(fromByteOffset: offset, as: UInt32.self) : 0
        extendedFlags = extended
        if flags & 0x80000000 != 0 { offset += 4 }
        alignToWord()
        if extended & 1 != 0 {
            failure = metadata.load(fromByteOffset: offset, as: Any.Type.self)
        } else {
            failure = flags & 0x01000000 != 0 ? (any Error).self : Never.self
        }
        guard let isolation = Isolation(rawValue: extended & 0x0e),
            let differentiation = Differentiability(rawValue: differentiability)
        else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The function metadata has an unknown effect convention."
            )
        }
        isAsync = flags & 0x20000000 != 0
        isEscaping = flags & 0x04000000 != 0
        isSendable = flags & 0x40000000 != 0
        self.isolation = isolation
        self.differentiability = differentiation
        hasSendingResult = extended & 0x10 != 0
    }
}

extension RuntimeFunctionMetadata {
    package func replacing(
        parameters: [Any.Type],
        result: Any.Type,
        parameterFlags: [UInt32]
    ) throws -> Any.Type {
        let hasParameterFlags = parameterFlags.contains { $0 != 0 }
        let flags = (flags & ~UInt(0x02000000)) | (hasParameterFlags ? 0x02000000 : 0)
        let pointers = parameters.map { Optional(unsafeBitCast($0, to: UnsafeRawPointer.self)) }
        let value = pointers.withUnsafeBufferPointer { pointers in
            parameterFlags.withUnsafeBufferPointer { parameters in
                ABISwiftFunctionTypeMetadata(
                    flags,
                    pointers.baseAddress,
                    hasParameterFlags ? parameters.baseAddress : nil,
                    unsafeBitCast(result, to: UnsafeRawPointer.self),
                    extendedFlags,
                    extendedFlags & 1 == 0
                        ? nil : unsafeBitCast(failure, to: UnsafeRawPointer.self),
                    differentiability.rawValue,
                    globalActor.map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
                )
            }
        }
        guard let value else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The Swift runtime could not construct the function type."
            )
        }
        return unsafeBitCast(value, to: Any.Type.self)
    }
}
