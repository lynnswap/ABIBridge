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
            let type = binding.canonicalType(of: type)
            switch type {
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
            if try hasUnboundStorage(type.substituting(substitutions)) { return true }
        }
        return false
    }
}
