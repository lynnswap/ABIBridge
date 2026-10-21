import ABIBridgeCore

/// Lowers Swift values to their native calling-convention storage.
///
/// A declaration position derives its storage from its formal type: generic
/// parameters and unbound fields are stored indirectly, `valueABIs` layouts
/// apply to closed nominal types, and other closed values use their own Swift
/// metadata.
enum SwiftValueSchema {
    /// The storage of a value at a declaration position with the formal type
    /// `formal`, where the caller supplies `actual`.
    static func layout(
        _ formal: SwiftFormalType,
        actual: Any.Type,
        binding: SwiftGenericBinding
    ) throws -> CValueType {
        let canonical = try binding.canonicalType(of: formal)
        if canonical != formal { return try layout(canonical, actual: actual, binding: binding) }
        if binding.isArchetype(formal) {
            return try binding.isClassBound(formal)
                ? CValueType(scalar: ABIValuePointer)
                : storage(of: actual)
        }
        if case .tuple(let fields, _) = formal {
            return try tupleLayout(fields, actual: actual, binding: binding)
        }
        if case .function = formal {
            let pointer = try CValueType(scalar: ABIValuePointer)
            return try CValueType(fields: [pointer, pointer])
        }
        if let index = formal.opaqueIndex {
            guard let opaque = binding.opaqueResults[index] else {
                throw ABIResolutionError.metadataUnavailable(
                    "The opaque result ABI has not been resolved."
                )
            }
            return opaque.type
        }
        if formal.nominalDeclaration != nil, !binding.dependsOnParameters(formal),
            formal.opaqueIndices.isEmpty,
            let explicit = try binding.explicitValueType(actual)
        {
            return explicit
        }
        func prepare<Value>(_ type: Value.Type) throws -> CValueType {
            if !binding.dependsOnParameters(formal), formal.opaqueIndices.isEmpty {
                return try SwiftValueCodec<Value>().type
            }
            if try binding.isClassBound(formal) { return try CValueType(scalar: ABIValuePointer) }
            switch formal {
            case .associated:
                return try storage(of: actual)
            case .named(let name, let arguments), .nominal(let name, let arguments):
                if !arguments.isEmpty && actual is AnyClass {
                    return try CValueType(scalar: ABIValuePointer)
                }
                if ["Swift.Array", "Swift.Dictionary", "Swift.Set"].contains(name) {
                    return try CValueType(scalar: ABIValuePointer)
                }
                if name == "Swift.Optional", let wrapped = arguments.first {
                    if try binding.isClassBound(wrapped) {
                        return try CValueType(scalar: ABIValuePointer)
                    }
                    let wrappedType = try binding.types(wrapped)[0]
                    if case .metatype(let instance) = wrapped,
                        let metatype = SwiftMetatypeMetadata(wrappedType)
                    {
                        return try !metatype.isExistential
                            && singletonMetatype(instance, binding: binding)
                            ? CValueType(swiftOptionalSingleton: ())
                            : metatype.valueType(for: Value.self, thin: false)
                    }
                    let wrappedLayout = try Self.layout(
                        wrapped,
                        actual: wrappedType,
                        binding: binding
                    )
                    if withExtendedLifetime(
                        wrappedLayout,
                        { ABISwiftValueIsIndirect(wrappedLayout.handle) }
                    ) {
                        return try storage(of: actual)
                    }
                    return try SwiftValueCodec<Value>().type
                }
                let isArchetype: Bool
                if case .named = formal {
                    isArchetype =
                        arguments.isEmpty
                        && binding.arguments[String(name.prefix { $0 != "." })] != nil
                } else {
                    isArchetype = false
                }
                if try isArchetype
                    || isIndirect(
                        actual,
                        arguments: arguments,
                        binding: binding
                    )
                {
                    return try storage(of: actual)
                }
            case .reference(_, let arguments):
                if actual is AnyClass { return try CValueType(scalar: ABIValuePointer) }
                if try isIndirect(
                    actual,
                    arguments: arguments,
                    binding: binding
                ) {
                    return try storage(of: actual)
                }
            case .nested:
                if actual is AnyClass { return try CValueType(scalar: ABIValuePointer) }
                if try isIndirect(
                    actual,
                    arguments: formal.nominalDeclaration!.arguments,
                    binding: binding
                ) {
                    return try storage(of: actual)
                }
            case .metatype(let instance):
                guard let metatype = SwiftMetatypeMetadata(actual) else {
                    throw ABIResolutionError.signatureMismatch(
                        .init(expected: formal.spelling, found: [String(reflecting: actual)])
                    )
                }
                return try metatype.valueType(
                    for: Value.self,
                    thin: !metatype.isExistential && singletonMetatype(instance, binding: binding)
                )
            case .existentialMetatype, .constrainedExistential:
                return try SwiftValueCodec<Value>().type
            case .tuple(let fields, _):
                return try tupleLayout(fields, actual: actual, binding: binding)
            case .opaqueResult:
                throw ABIResolutionError.metadataUnavailable(
                    "The opaque result ABI has not been resolved."
                )
            case .pack, .packValue:
                preconditionFailure("A pack expands within the containing parameter list or tuple.")
            case .function:
                let pointer = try CValueType(scalar: ABIValuePointer)
                return try CValueType(fields: [pointer, pointer])
            case .foreignFunction, .objectiveCClass:
                return try CValueType(scalar: ABIValuePointer)
            case .borrowing, .consuming, .inoutValue:
                throw ABIResolutionError.unsupportedDeclaration(
                    "Generic ownership arguments require their underlying value convention."
                )
            }
            if formal.nominalDeclaration != nil, formal.opaqueIndices.isEmpty,
                let explicit = try binding.explicitValueType(actual)
            {
                return explicit
            }
            return try SwiftValueCodec<Value>().type
        }
        return try _openExistential(actual, do: prepare)
    }

    /// The native tuple layout of `fields`, with packs as address vectors.
    static func tupleLayout(
        _ fields: [SwiftFormalType],
        actual: Any.Type,
        binding: SwiftGenericBinding
    ) throws -> CValueType {
        let elements = try SwiftGenericCallPlan.tupleElements(fields, actual: actual, binding: binding)
        let native = ABISwiftGetValueLayout(unsafeBitCast(actual, to: UnsafeRawPointer.self))
        var types: [CValueType] = [], offsets: [Int] = []
        var index = 0
        for field in fields {
            let offset = index < elements.count ? elements[index].offset : native.size
            offsets.append(offset)
            if case .pack(let pattern, let shape) = field {
                let count = try binding.packCount(in: shape ?? pattern)
                let selected = elements[index..<(index + count)]
                let layouts = try selected.map { try storage(of: $0.type) }
                let positions = selected.map { $0.offset - offset }
                let size = zip(positions, layouts).map { $0.0 + $0.1.size }.max() ?? 0
                types.append(
                    try CValueType(
                        swiftTuple: layouts,
                        offsets: positions,
                        size: size,
                        alignment: layouts.map(\.alignment).max() ?? 1,
                        isPack: true
                    )
                )
                index += count
            } else {
                types.append(try layout(field, actual: elements[index].type, binding: binding))
                index += 1
            }
        }
        return try CValueType(
            swiftTuple: types,
            offsets: offsets,
            size: native.size,
            alignment: native.alignment
        )
    }

    private static func singletonMetatype(
        _ type: SwiftFormalType,
        binding: SwiftGenericBinding
    ) throws -> Bool {
        let type = try binding.canonicalType(of: type)
        if case .metatype(let instance) = type {
            return try singletonMetatype(instance, binding: binding)
        }
        if binding.isArchetype(type) { return false }
        return try !(binding.types(type)[0] is AnyClass)
    }

    /// The storage of an enum with payload cases, such as an Optional. Swift
    /// passes the whole value as integer data, whatever its payload types,
    /// and coalesces the bytes into pointer-sized chunks.
    /// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/IRGen/EnumPayload.cpp
    static func enumStorage(of metadata: Any.Type) throws -> CValueType {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
        let byte = try CValueType(scalar: ABIValueUInt8)
        return try CValueType(
            swiftComponents: CValueType(fields: Array(repeating: byte, count: layout.size)),
            size: layout.size,
            alignment: layout.alignment
        )
    }

    /// Indirect storage for a value of `type`, which native code addresses through its metadata.
    static func storage(of type: Any.Type) throws -> CValueType {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
        return try CValueType(indirectSwiftSize: layout.size, alignment: layout.alignment)
    }

    /// The storage `abi` describes for a Swift value of `metadata`.
    static func explicitLayout(of metadata: Any.Type, abi: NativeType) throws -> CValueType {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
        if let components = abi.cType {
            guard (layout.size...layout.stride).contains(components.size) else {
                throw ABIResolutionError.unsupportedDeclaration("Swift ABI components must cover the native value without exceeding its stride.")
            }
            return try CValueType(swiftComponents: components, size: layout.size, alignment: layout.alignment)
        }
        return try CValueType(indirectSwiftSize: layout.size, alignment: layout.alignment)
    }

    /// An inline field whose size remains an unbound archetype makes the containing value formally indirect, independently of the nominal type's resilience. Other values keep the existing explicit ABI contract: reflection metadata does not record whether a public value declaration is frozen.
    static func isIndirect(_ metadata: Any.Type, arguments: [SwiftFormalType],
                           binding: SwiftGenericBinding) throws -> Bool {
        let context = try SwiftGenericTypeContext(metadata: metadata)
        guard context.parameters.count == arguments.count else { return false }
        let substitutions = Dictionary(uniqueKeysWithValues: zip(context.parameters.map(\.name), arguments))
        func hasUnboundStorage(_ type: SwiftFormalType) throws -> Bool {
            let type = try binding.canonicalType(of: type)
            switch type {
            case .associated:
                return try !binding.isClassBound(type)
            case .opaqueResult(let index):
                guard let value = binding.opaqueResults[index] else {
                    throw ABIResolutionError.metadataUnavailable("The opaque field ABI has not been resolved.")
                }
                return ABISwiftValueIsIndirect(value.type.handle)
            case .named(let name, let arguments), .nominal(let name, let arguments):
                if case .named = type, arguments.isEmpty, binding.arguments[String(name.prefix { $0 != "." })] != nil {
                    return try !binding.isClassBound(type)
                }
                if name == "Swift.Optional", let wrapped = arguments.first { return try hasUnboundStorage(wrapped) }
                if arguments.isEmpty || (!binding.dependsOnParameters(type) && type.opaqueIndices.isEmpty) { return false }
                let metadata = try binding.types(type)[0]
                if metadata is AnyClass { return false }
                return try isIndirect(metadata, arguments: arguments, binding: binding)
            case .reference(_, let arguments):
                if arguments.isEmpty || (!binding.dependsOnParameters(type) && type.opaqueIndices.isEmpty) { return false }
                let metadata = try binding.types(type)[0]
                if metadata is AnyClass { return false }
                return try isIndirect(metadata, arguments: arguments, binding: binding)
            case .nested:
                guard let declaration = type.nominalDeclaration, binding.dependsOnParameters(type) || !type.opaqueIndices.isEmpty else { return false }
                let metadata = try binding.types(type)[0]
                if metadata is AnyClass { return false }
                return try isIndirect(metadata, arguments: declaration.arguments, binding: binding)
            case .tuple(let elements, _): return try elements.contains(where: hasUnboundStorage)
            case .pack: return true
            default: return false
            }
        }

        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        for index in 0..<ABISwiftTypeFieldCount(pointer) {
            guard let handle = ABICopySwiftTypeFieldSyntax(pointer, index) else { continue }
            let type = try SwiftFormalType(SwiftSyntax(adopting: handle).root)
                .qualifyingAssociatedTypes(using: context.conformances)
            if try hasUnboundStorage(type.substituting(substitutions)) { return true }
        }
        return false
    }
}
