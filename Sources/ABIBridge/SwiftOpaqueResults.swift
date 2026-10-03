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
        guard let origin = DeclarationKey.demangle(symbol.linkageName, language: .swift) else {
            throw ABIResolutionError.metadataUnavailable("The matched opaque declaration is unavailable.")
        }
        let resultName: Substring?
        if let getter = origin.range(of: ".getter : ") { resultName = origin[getter.upperBound...] }
        else { resultName = swiftOuterSignature(origin).result }
        guard resultName?.split(whereSeparator: \.isWhitespace) == ["some"] else {
            throw ABIResolutionError.unsupportedDeclaration("Opaque result storage requires the outer native result's complete type.")
        }
        return try resolve(symbol: symbol, resolver: resolver)
    }

    static func resolve(symbol: ResolvedSymbol, resolver: SymbolResolver?) throws -> SwiftOpaqueResultPlan {
        let prepared = try prepare(symbol: symbol, resolver: resolver, indices: [0], binding: nil)
        return prepared[0]!
    }

    static func resolve(symbol: ResolvedSymbol, resolver: SymbolResolver, indices: Set<Int>,
                        binding: SwiftGenericBinding) throws -> [Int: SwiftRuntimeValuePlan] {
        try prepare(symbol: symbol, resolver: resolver, indices: indices, binding: binding).mapValues(\.value)
    }

    private static func prepare(symbol: ResolvedSymbol, resolver: SymbolResolver?, indices: Set<Int>,
                                binding: SwiftGenericBinding?) throws -> [Int: SwiftOpaqueResultPlan] {
        guard let resolver else {
            throw ABIResolutionError.unsupportedDeclaration("Opaque results require source declaration lookup.")
        }
        guard var origin = DeclarationKey.demangle(symbol.linkageName, language: .swift) else {
            throw ABIResolutionError.metadataUnavailable("The matched opaque declaration is unavailable.")
        }
        if let getter = origin.range(of: ".getter : ") {
            origin = String(origin[..<getter.lowerBound]) + " : " + origin[getter.upperBound...]
        }
        let symbolDescriptor = try resolver.resolve(
            .init(name: "opaque type descriptor for <<opaque return type of " + origin + ">>",
                  language: .swift, kind: .data), in: symbol.image, loading: .loadedOnly)
        let descriptor = try Descriptor(symbolDescriptor)
        let arguments = try descriptor.arguments(binding: binding)
        let accessor = try resolver.resolve(.init(name: "swift_getOpaqueTypeMetadata", language: .c),
                                            in: .automatic, loading: .loadedOnly)
        let function = try NativeSwiftFunction<(UInt, UnsafeRawPointer?, UnsafeRawPointer, UInt) -> SwiftMetadataResponse>(symbol: accessor)
        var results: [Int: SwiftOpaqueResultPlan] = [:]
        for index in indices.sorted() {
            guard index >= 0, index < descriptor.parameters.count - (binding?.declaration.parameters.count ?? 0) else {
                throw ABIResolutionError.metadataUnavailable("The opaque result index is outside its descriptor's generic parameters.")
            }
            let response = try unsafe symbolDescriptor.withUnsafeAddress { address in
                try withExtendedLifetime(arguments) {
                    try unsafe function.unsafeInvoke(0,
                        arguments.words.count == 0 ? nil : UnsafeRawPointer(bitPattern: arguments.words.address), address, UInt(index))
                }
            }
            guard response.address != 0, response.state == 0 else {
                throw ABIResolutionError.metadataUnavailable("Complete opaque result metadata is unavailable.")
            }
            results[index] = try SwiftOpaqueResultPlan(metadata: unsafeBitCast(response.address, to: Any.Type.self),
                classBound: descriptor.isClassBound(index: index, binding: binding),
                owners: [symbol, symbolDescriptor, accessor], resolver: resolver)
        }
        return results
    }

    func makeStorage() -> NativeValueStorage { value.makeStorage() }
    func decode(_ storage: NativeValueStorage) throws -> NativeSwiftValue { try value.decode(storage) }

    // The descriptor's generic context contains captured parameters followed by
    // the opaque parameters. Its trailing underlying arguments describe both
    // the returned types and their witness tables; they are not caller inputs.
    // https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/GenericContext.h
    private struct Descriptor {
        struct Requirement {
            let flags: UInt32
            let value: SwiftMetadataRequirement
            let classBound: Bool
        }
        struct PackShape {
            let kind: UInt16
            let argument: Int
            let shape: Int
        }
        struct Arguments {
            let words: SwiftGenericArgumentBuffer
            let packs: [SwiftGenericArgumentBuffer]
        }
        let parameters: [UInt8]
        let requirements: [Requirement]
        let shapes: [PackShape]
        let shapeCount: Int
        let capturedArgumentCount: Int

        init(_ descriptor: ResolvedSymbol) throws {
            let extent = descriptor.sectionRange.upperBound - descriptor.address
            guard extent >= 16 else { throw ABIResolutionError.metadataUnavailable("Incomplete opaque descriptor.") }
            self = try unsafe descriptor.withUnsafeAddress { address in
                let flags = address.loadUnaligned(as: UInt32.self)
                guard flags & 0x1f == 4, flags & 0x80 != 0 else {
                    throw ABIResolutionError.metadataUnavailable("Expected an opaque type descriptor.")
                }
                let count = Int(address.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
                let requirementCount = Int(address.loadUnaligned(fromByteOffset: 10, as: UInt16.self))
                let keyCount = Int(address.loadUnaligned(fromByteOffset: 12, as: UInt16.self))
                let genericFlags = address.loadUnaligned(fromByteOffset: 14, as: UInt16.self)
                let underlying = Int(flags >> 16)
                let requirementsOffset = (16 + count + 3) & ~3
                guard count > 0, underlying > 0, keyCount >= underlying,
                      requirementsOffset + requirementCount * 12 <= extent else {
                    throw ABIResolutionError.metadataUnavailable("Incomplete opaque generic context.")
                }
                let parameters = (0..<count).map { address.load(fromByteOffset: 16 + $0, as: UInt8.self) }
                let requirements = try (0..<requirementCount).map { index in
                    let requirement = address.advanced(by: requirementsOffset + index * 12)
                    let flags = requirement.loadUnaligned(as: UInt32.self)
                    return Requirement(flags: flags, value: try SwiftMetadataRequirement(requirement),
                        classBound: flags & 0x1f == 0 && ABISwiftProtocolRequirementIsClassBound(requirement.advanced(by: 8)))
                }
                var shapes: [PackShape] = [], shapeCount = 0
                if genericFlags & 1 != 0 {
                    let offset = requirementsOffset + requirementCount * 12
                    guard offset + 4 <= extent else { throw ABIResolutionError.metadataUnavailable("Incomplete opaque pack shapes.") }
                    let packCount = Int(address.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    shapeCount = Int(address.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self))
                    guard offset + 4 + packCount * 8 <= extent else {
                        throw ABIResolutionError.metadataUnavailable("Incomplete opaque pack shapes.")
                    }
                    shapes = (0..<packCount).map { index in
                        let entry = address.advanced(by: offset + 4 + index * 8)
                        return PackShape(kind: entry.loadUnaligned(as: UInt16.self),
                            argument: Int(entry.loadUnaligned(fromByteOffset: 2, as: UInt16.self)),
                            shape: Int(entry.loadUnaligned(fromByteOffset: 4, as: UInt16.self)))
                    }
                }
                return Descriptor(parameters: parameters, requirements: requirements, shapes: shapes,
                    shapeCount: shapeCount, capturedArgumentCount: keyCount - underlying)
            }
        }

        private init(parameters: [UInt8], requirements: [Requirement], shapes: [PackShape],
                     shapeCount: Int, capturedArgumentCount: Int) {
            self.parameters = parameters; self.requirements = requirements
            self.shapes = shapes; self.shapeCount = shapeCount
            self.capturedArgumentCount = capturedArgumentCount
        }

        func arguments(binding: SwiftGenericBinding?) throws -> Arguments {
            guard let binding else {
                guard capturedArgumentCount == 0 else {
                    throw ABIResolutionError.metadataUnavailable("This opaque result requires its enclosing generic bindings.")
                }
                return Arguments(words: SwiftGenericArgumentBuffer([]), packs: [])
            }
            guard binding.declaration.parameters.count < parameters.count else {
                throw ABIResolutionError.metadataUnavailable("The opaque descriptor has no underlying type parameter.")
            }
            var words = Array(repeating: UInt(0), count: shapeCount)
            var packs: [SwiftGenericArgumentBuffer] = []
            func appendPack(_ elements: [UInt]) -> UInt {
                let pack = SwiftGenericArgumentBuffer(elements)
                packs.append(pack)
                return pack.address
            }
            for (parameter, flags) in zip(binding.declaration.parameters, parameters) where flags & 0x80 != 0 {
                let argument = binding.arguments[parameter.name]!
                if flags & 0x3f == 1 {
                    if let shape = shapes.first(where: { $0.kind == 0 && $0.argument == words.count }) {
                        words[shape.shape] = UInt(argument.types.count)
                    }
                    words.append(appendPack(argument.types.map { unsafeBitCast($0, to: UInt.self) }))
                } else {
                    words.append(unsafeBitCast(argument.types[0], to: UInt.self))
                }
            }
            for requirement in requirements where requirement.flags & 0x80 != 0 {
                let subject = requirement.value.subject
                guard binding.dependsOnParameters(subject), let protocolType = requirement.value.descriptor else { continue }
                let witnesses = try binding.types(subject).map { metadata -> UInt in
                    guard let witness = unsafe protocolType.withUnsafeAddress({ ABISwiftConformance(unsafeBitCast(metadata, to: UnsafeRawPointer.self), $0) }) else {
                        throw ABIResolutionError.metadataUnavailable("The captured opaque conformance is unavailable.")
                    }
                    return UInt(bitPattern: witness)
                }
                if requirement.flags & 0x20 != 0 { words.append(appendPack(witnesses)) }
                else { words.append(contentsOf: witnesses) }
            }
            guard words.count == capturedArgumentCount else {
                throw ABIResolutionError.metadataUnavailable("The opaque descriptor's captured generic arguments are incomplete.")
            }
            return Arguments(words: SwiftGenericArgumentBuffer(words), packs: packs)
        }

        func isClassBound(index: Int, binding: SwiftGenericBinding?) -> Bool {
            let depth = (binding?.declaration.parameters.map { parameter in
                Int(parameter.name.drop(while: { $0.isLetter })) ?? 0
            }.max() ?? -1) + 1
            let subject = SwiftFormalType.named(SwiftFormalType.parameterName(depth: depth, index: index), [])
            return requirements.contains { requirement in
                guard requirement.value.subject == subject else { return false }
                if requirement.classBound { return true }
                switch requirement.value.value {
                case .superclass: return true
                case .conformance(_, let name): return name == "Swift.AnyObject"
                default: return false
                }
            }
        }
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
            try plan.requireOwnedValue(as: Value.self)
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
        if let closure { return try closure.makeValue(storage.address.load(as: ABISwiftClosureValue.self), codeOwner, true, storage.codeLifetime) as! Value }
        if genericValue {
            constants.initialize(at: storage.address)
            return storage.take(as: Value.self)
        }
        if let opaque { return try opaque.decode(storage) as! Value }
        return try ordinary!.decode(storage, retaining: owner, retainingCode: codeOwner)
    }
}
