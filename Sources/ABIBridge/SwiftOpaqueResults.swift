import ABIBridgeCore

final class SwiftOpaqueResultPlan: Sendable {
    let type: CValueType
    let value: SwiftRuntimeValuePlan

    private init(metadata: Any.Type, classBound: Bool, owners: [ResolvedSymbol], resolver: SymbolResolver) throws {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
        type = try classBound ? CValueType(scalar: ABIValuePointer)
            : CValueType(indirectSwiftSize: layout.size, alignment: layout.alignment)
        value = try SwiftRuntimeValuePlan(metadata: metadata, type: type, resolver: resolver,
                                         retaining: owners.map(\.image))
        try value.requireOwnedValue()
    }

    static func make(for result: Any.Type, symbol: ResolvedSymbol,
                             resolver: SymbolResolver?) throws -> SwiftOpaqueResultPlan? {
        guard result == NativeSwiftValue.self else { return nil }
        return try resolve(symbol: symbol, resolver: resolver)
    }

    static func resolve(symbol: ResolvedSymbol, resolver: SymbolResolver?) throws -> SwiftOpaqueResultPlan {
        guard let resolver else {
            throw ABIResolutionError.unsupportedDeclaration("Opaque results require source declaration lookup.")
        }
        guard var origin = DeclarationKey.demangle(symbol.linkageName, language: .swift) else {
            throw ABIResolutionError.metadataUnavailable("The matched opaque declaration is unavailable.")
        }
        if let getter = origin.range(of: ".getter : ") {
            guard origin[getter.upperBound...].split(whereSeparator: \.isWhitespace) == ["some"] else {
                throw ABIResolutionError.unsupportedDeclaration("An opaque result handle requires one native some result.")
            }
            origin = String(origin[..<getter.lowerBound]) + " : some"
        } else if swiftOuterSignature(origin).result?.split(whereSeparator: \.isWhitespace) != ["some"] {
            throw ABIResolutionError.unsupportedDeclaration("An opaque result handle requires one native some result.")
        }
        let descriptor = try resolver.resolve(
            .init(name: "opaque type descriptor for <<opaque return type of " + origin + ">>",
                  language: .swift, kind: .data), in: symbol.image, loading: .loadedOnly)
        let classBound = try classConstraint(descriptor)
        let accessor = try resolver.resolve(.init(name: "swift_getOpaqueTypeMetadata", language: .c),
                                            in: ImageSelector.automatic, loading: .loadedOnly)
        let function = try NativeSwiftFunction<(UInt, UnsafeRawPointer?, UnsafeRawPointer, UInt) -> SwiftMetadataResponse>(symbol: accessor)
        let response = try unsafe descriptor.withUnsafeAddress { address in
            try unsafe function.unsafeInvoke(0, nil, address, 0)
        }
        guard response.address != 0, response.state == 0 else {
            throw ABIResolutionError.metadataUnavailable("Complete opaque result metadata is unavailable.")
        }
        let metadata = unsafeBitCast(response.address, to: Any.Type.self)
        return try SwiftOpaqueResultPlan(metadata: metadata, classBound: classBound,
                                         owners: [symbol, descriptor, accessor], resolver: resolver)
    }

    // Opaque descriptors include the result's own generic parameters. Only the
    // key arguments preceding the underlying type/witness arguments belong to
    // an enclosing generic declaration and must be supplied by its caller.
    // https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h
    private static func classConstraint(_ descriptor: ResolvedSymbol) throws -> Bool {
        let extent = descriptor.sectionRange.upperBound - descriptor.address
        guard extent >= 16 else { throw ABIResolutionError.metadataUnavailable("Incomplete opaque descriptor.") }
        return try unsafe descriptor.withUnsafeAddress { address in
            let flags = address.loadUnaligned(as: UInt32.self)
            guard flags & 0x1f == 4, flags & 0x80 != 0 else {
                throw ABIResolutionError.metadataUnavailable("Expected an opaque type descriptor.")
            }
            let underlying = Int(flags >> 16)
            let parameters = Int(address.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
            let requirements = Int(address.loadUnaligned(fromByteOffset: 10, as: UInt16.self))
            let keyArguments = Int(address.loadUnaligned(fromByteOffset: 12, as: UInt16.self))
            guard underlying > 0, parameters > 0 else {
                throw ABIResolutionError.metadataUnavailable("Opaque descriptor has no result type parameter.")
            }
            guard flags & 0x20 == 0 else {
                throw ABIResolutionError.unsupportedDeclaration("Opaque result erasure requires a Copyable and Escapable result contract.")
            }
            guard keyArguments == underlying, parameters == 1 else {
                throw ABIResolutionError.unsupportedDeclaration("Generic opaque results require enclosing metadata and witness arguments.")
            }
            let requirementsOffset = (16 + parameters + 3) & ~3
            guard requirementsOffset + requirements * 12 <= extent else {
                throw ABIResolutionError.metadataUnavailable("Incomplete opaque generic requirements.")
            }
            var classBound = false
            for index in 0..<requirements {
                let requirement = address.advanced(by: requirementsOffset + index * 12)
                let kind = requirement.loadUnaligned(as: UInt32.self) & 0x1f
                if kind == 5,
                   requirement.loadUnaligned(fromByteOffset: 8, as: UInt16.self) == UInt16(parameters - 1),
                   requirement.loadUnaligned(fromByteOffset: 10, as: UInt16.self) & 2 != 0 {
                    throw ABIResolutionError.unsupportedDeclaration("A nonescapable opaque result requires a scoped result lifetime.")
                }
                let subjectField = requirement.advanced(by: 4)
                let subject = subjectField.advanced(by: Int(subjectField.loadUnaligned(as: Int32.self)))
                // A nongeneric single opaque result is parameter x. Constraints
                // on an associated type do not constrain the result itself.
                guard subject.load(as: UInt8.self) == 120,
                      subject.load(fromByteOffset: 1, as: UInt8.self) == 0 else { continue }
                if kind == 2 || (kind == 31 && requirement.loadUnaligned(fromByteOffset: 8, as: UInt32.self) == 0) {
                    classBound = true
                } else if kind == 0 {
                    classBound = classBound || ABISwiftProtocolRequirementIsClassBound(requirement.advanced(by: 8))
                }
            }
            return classBound
        }
    }

    func makeStorage() -> NativeValueStorage { value.makeStorage() }
    func decode(_ storage: NativeValueStorage) throws -> NativeSwiftValue {
        try value.decode(storage)
    }

}

struct SwiftResultCodec<Value>: Sendable {
    let type: CValueType
    private let ordinary: SwiftValueCodec<Value>?
    private let opaque: SwiftOpaqueResultPlan?
    private let genericValue: Bool
    private let constants = SwiftValueConstants(Value.self)
    private let closure: SwiftClosureCodec?
    private let runtimeValue: SwiftRuntimeValuePlan?
    private let tuple: SwiftTupleValuePlan?

    init(opaque: SwiftOpaqueResultPlan? = nil, generic: SwiftGenericResult = .concrete) throws {
        if case .tuple(let plan) = generic {
            try plan.validateOwnedResult()
            tuple = plan
        } else { tuple = nil }
        if case .runtimeValue(let plan) = generic {
            try plan.requireOwnedValue()
            runtimeValue = plan
        } else { runtimeValue = nil }
        if case .closure(let codec) = generic { closure = codec } else { closure = nil }
        if case .value = generic { genericValue = true } else { genericValue = false }
        if let genericType = generic.type {
            type = genericType
            ordinary = nil; self.opaque = nil
            return
        }
        if let opaque {
            self.opaque = opaque
            ordinary = nil
            type = opaque.type
        } else {
            let codec = try SwiftValueCodec<Value>()
            ordinary = codec
            self.opaque = nil
            type = codec.type
        }
    }

    func makeStorage() -> NativeValueStorage {
        if let tuple { return tuple.makeResultStorage() }
        if let runtimeValue { return runtimeValue.makeStorage() }
        if closure != nil {
            return NativeValueStorage(size: type.size, alignment: type.alignment, codeLifetime: SwiftValueCodeLifetime([]))
        }
        if genericValue { return NativeValueStorage(size: MemoryLayout<Value>.stride, alignment: MemoryLayout<Value>.alignment) }
        if let opaque { return opaque.makeStorage() }
        return ordinary!.makeStorage()
    }

    func decode(_ storage: NativeValueStorage, retaining owner: Any?, retainingCode codeOwner: Any?) throws -> Value {
        if let tuple {
            return try tuple.decodeResult(storage, retaining: owner, retainingCode: codeOwner, as: Value.self)
        }
        if let runtimeValue { return try runtimeValue.decode(storage) as! Value }
        if let closure {
            let value = storage.address.load(as: ABISwiftClosureValue.self)
            storage.relinquishValue()
            return try closure.makeValue(value, codeOwner, true, storage.codeLifetime) as! Value
        }
        if genericValue {
            constants.initialize(at: storage.address)
            return storage.take(as: Value.self)
        }
        if let opaque { return try opaque.decode(storage) as! Value }
        return try ordinary!.decode(storage, retaining: owner, retainingCode: codeOwner)
    }
}
