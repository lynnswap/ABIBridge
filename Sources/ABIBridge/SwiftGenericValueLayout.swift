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
        var qualifiers: Set<String> = []
        for conformance in context.conformances {
            if let descriptor = conformance.descriptor { qualifiers.formUnion(try descriptor.qualifiedNames()) }
        }

        func replace(_ type: SwiftFormalType) -> SwiftFormalType {
            switch type {
            case .named(let name, let arguments):
                if arguments.isEmpty {
                    if let value = substitutions[name] { return value }
                    if let dot = name.firstIndex(of: "."), let value = substitutions[String(name[..<dot])] {
                        return .named(value.spelling + name[dot...], [])
                    }
                }
                return .named(name, arguments.map(replace))
            case .nominal(let name, let arguments): return .nominal(name, arguments.map(replace))
            case .tuple(let elements): return .tuple(elements.map(replace))
            case .pack(let value): return .pack(replace(value))
            case .borrowing(let value): return .borrowing(replace(value))
            case .consuming(let value): return .consuming(replace(value))
            case .inoutValue(let value): return .inoutValue(replace(value))
            case .metatype(let value): return .metatype(replace(value))
            case .function(let parameters, let result, let failure, let isAsync):
                return .function(parameters.map(replace), replace(result), failure: failure.map(replace), isAsync: isAsync)
            }
        }

        func hasUnboundStorage(_ type: SwiftFormalType) throws -> Bool {
            if binding.concreteEquivalent(of: type) != nil { return false }
            switch type {
            case .named(let name, let arguments):
                if arguments.isEmpty, binding.arguments[String(name.prefix { $0 != "." })] != nil {
                    return try !binding.isClassBound(type)
                }
                if name == "Swift.Optional", let wrapped = arguments.first { return try hasUnboundStorage(wrapped) }
                return false
            case .tuple(let elements): return try elements.contains(where: hasUnboundStorage)
            case .pack: return true
            default: return false
            }
        }

        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        for index in 0..<ABISwiftTypeFieldCount(pointer) {
            guard let reference = ABICopySwiftTypeFieldReference(pointer, index) else { continue }
            defer { ABIFreeString(reference) }
            guard let subject = DeclarationKey.demangle(String(cString: reference), language: .swift) else { continue }
            let type = try SwiftFormalType(swiftGenericRequirementSubject(subject, qualifiers: qualifiers))
            if try hasUnboundStorage(replace(type)) { return true }
        }
        return false
    }
}
