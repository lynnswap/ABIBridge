import ABIBridgeCore

/// An inline field whose size remains an unbound archetype makes the containing
/// value formally indirect, independently of the nominal type's resilience.
/// Other values keep the existing explicit ABI contract: reflection metadata
/// does not record whether a public value declaration is frozen.
enum SwiftGenericValueLayout {
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
            case .named(let name, let arguments), .nominal(let name, let arguments):
                if case .named = type, arguments.isEmpty, binding.arguments[String(name.prefix { $0 != "." })] != nil {
                    return try !binding.isClassBound(type)
                }
                if name == "Swift.Optional", let wrapped = arguments.first { return try hasUnboundStorage(wrapped) }
                if arguments.isEmpty || !binding.dependsOnParameters(type) { return false }
                let metadata = try binding.types(type)[0]
                if metadata is AnyClass { return false }
                return try isIndirect(metadata, arguments: arguments, binding: binding)
            case .reference(_, let arguments):
                if arguments.isEmpty || !binding.dependsOnParameters(type) { return false }
                let metadata = try binding.types(type)[0]
                if metadata is AnyClass { return false }
                return try isIndirect(metadata, arguments: arguments, binding: binding)
            case .nested:
                guard let declaration = type.nominalDeclaration, binding.dependsOnParameters(type) else { return false }
                let metadata = try binding.types(type)[0]
                if metadata is AnyClass { return false }
                return try isIndirect(metadata, arguments: declaration.arguments, binding: binding)
            case .tuple(let elements): return try elements.contains(where: hasUnboundStorage)
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

extension SwiftFormalType {
    func qualifyingAssociatedTypes(using conformances: [SwiftGenericBinding.Conformance]) throws -> Self {
        func qualify(_ type: Self) throws -> Self { try type.qualifyingAssociatedTypes(using: conformances) }
        switch self {
        case .associated(let base, let member, let protocolName):
            var names: Set<String> = []
            if let protocolName { names.insert(protocolName) }
            else {
                for conformance in conformances where conformance.subject == base {
                    for descriptor in try conformance.descriptor?.protocolsDeclaring(member) ?? [] {
                        names.insert(try descriptor.name())
                    }
                }
            }
            guard names.count == 1 else {
                throw ABIResolutionError.metadataUnavailable("Cannot identify the declaring protocol for " + spelling + ".")
            }
            return .associated(try qualify(base), member, protocolName: names.first!)
        case .named(let name, let values): return .named(name, try values.map(qualify))
        case .nominal(let name, let values): return .nominal(name, try values.map(qualify))
        case .reference(let descriptor, let values): return .reference(descriptor, try values.map(qualify))
        case .nested(let parent, let name, let values): return .nested(try qualify(parent), name, try values.map(qualify))
        case .tuple(let values): return .tuple(try values.map(qualify))
        case .packValue(let values): return .packValue(try values.map(qualify))
        case .pack(let value, let shape): return .pack(try qualify(value), shape: try shape.map(qualify))
        case .metatype(let value): return .metatype(try qualify(value))
        case .existentialMetatype(let value): return .existentialMetatype(try qualify(value))
        case .borrowing(let value): return .borrowing(try qualify(value))
        case .consuming(let value): return .consuming(try qualify(value))
        case .inoutValue(let value): return .inoutValue(try qualify(value))
        case .function(let values, let result, let failure, let isAsync):
            return .function(try values.map(qualify), try qualify(result), failure: try failure.map(qualify), isAsync: isAsync)
        }
    }
}
