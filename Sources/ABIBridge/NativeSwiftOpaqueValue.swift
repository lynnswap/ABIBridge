import ABIBridgeCore

/// An owned value returned by a native Swift declaration returning some P.
///
/// Use this type as the result in a function-type metatype. The bridge resolves
/// the opaque descriptor and complete underlying metadata before preparing the
/// native result convention. The value, metadata, and implementation images remain
/// alive through this handle's final release. The hidden value is not assumed
/// Sendable. Generic substitutions and noncopyable/nonescapable opaque contracts
/// require a compiled adapter.
public struct NativeSwiftOpaqueValue {
    private let storage: NativeValueStorage
    private let plan: SwiftOpaqueResultPlan

    /// The runtime type of the hidden concrete value.
    public var valueType: Any.Type { plan.metadata }

    init(storage: NativeValueStorage, plan: SwiftOpaqueResultPlan) {
        self.storage = storage
        self.plan = plan
    }

    /// Borrows access to an Any copy of the hidden value.
    ///
    /// Standard Swift casts can inspect its existing protocol conformances.
    /// Keep this handle alive if a native value or metatype escapes the body
    /// and may later execute code from its image, including during destruction.
    public func withValue<Result>(_ body: (Any) throws -> Result) rethrows -> Result {
        try withExtendedLifetime(self) { try body(plan.read(storage)) }
    }
}

final class SwiftOpaqueResultPlan: Sendable {
    let metadata: Any.Type
    let type: CValueType
    private let size: Int
    private let alignment: Int
    private let owners: [ResolvedSymbol]
    private let adopt: @Sendable (NativeValueStorage) -> Void
    let read: @Sendable (NativeValueStorage) -> Any

    private init<Value>(metadata: Value.Type, classBound: Bool, owners: [ResolvedSymbol]) throws {
        self.metadata = metadata
        size = MemoryLayout<Value>.stride
        alignment = MemoryLayout<Value>.alignment
        type = try classBound ? CValueType(scalar: ABIValuePointer)
            : CValueType(indirectSwiftSize: MemoryLayout<Value>.size, alignment: alignment)
        self.owners = owners
        adopt = { $0.assumeInitialized(as: Value.self) }
        read = { $0.address.load(as: Value.self) }
    }

    static func make<Result>(for result: Result.Type, symbol: ResolvedSymbol,
                             resolver: SymbolResolver?) throws -> SwiftOpaqueResultPlan? {
        guard result == NativeSwiftOpaqueValue.self else { return nil }
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
        let function = try NativeSwiftFunction<SwiftMetadataResponse, UInt, UnsafeRawPointer?, UnsafeRawPointer, UInt>(symbol: accessor)
        let response = try unsafe descriptor.withUnsafeAddress { address in
            try unsafe function.unsafeInvoke(0, nil, address, 0)
        }
        guard response.address != 0, response.state == 0 else {
            throw ABIResolutionError.metadataUnavailable("Complete opaque result metadata is unavailable.")
        }
        let metadata = unsafeBitCast(response.address, to: Any.Type.self)
        func open<Value>(_ type: Value.Type) throws -> SwiftOpaqueResultPlan {
            try SwiftOpaqueResultPlan(metadata: type, classBound: classBound, owners: [symbol, descriptor, accessor])
        }
        return try _openExistential(metadata, do: open)
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
                   requirement.loadUnaligned(fromByteOffset: 10, as: UInt16.self) & 3 != 0 {
                    throw ABIResolutionError.unsupportedDeclaration("Opaque result erasure requires a Copyable and Escapable result contract.")
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

    func makeStorage() -> NativeValueStorage {
        NativeValueStorage(size: size, alignment: alignment, owner: self)
    }

    func decode(_ storage: NativeValueStorage) throws -> NativeSwiftOpaqueValue {
        if metadata is AnyClass || !ABISwiftValueIsIndirect(type.handle),
           storage.address.load(as: UnsafeRawPointer?.self) == nil {
            throw ABIInvocationError.unexpectedNilResult(expected: String(reflecting: metadata))
        }
        adopt(storage)
        return NativeSwiftOpaqueValue(storage: storage, plan: self)
    }
}

struct SwiftResultCodec<Value>: Sendable {
    let type: CValueType
    private let ordinary: SwiftValueCodec<Value>?
    private let opaque: SwiftOpaqueResultPlan?

    init(opaque: SwiftOpaqueResultPlan? = nil) throws {
        if Value.self == NativeSwiftOpaqueValue.self {
            guard let opaque else {
                throw ABIResolutionError.unsupportedDeclaration("Opaque result handles require an opaque-return declaration.")
            }
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
        if let opaque { return opaque.makeStorage() }
        return ordinary!.makeStorage()
    }

    func decode(_ storage: NativeValueStorage, retaining owner: Any?, retainingCode codeOwner: Any?) throws -> Value {
        if let opaque { return try opaque.decode(storage) as! Value }
        return try ordinary!.decode(storage, retaining: owner, retainingCode: codeOwner)
    }
}
