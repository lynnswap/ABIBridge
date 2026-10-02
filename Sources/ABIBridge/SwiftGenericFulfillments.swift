import Foundation

/// Swift IRGen derives generic requirements from direct class arguments and
/// thick metatypes. An inexact source does not fulfill an archetype's own
/// metadata, but its nominal generic arguments are exact sources.
/// Swift 6.3: IRGen/GenProto.cpp and IRGen/Fulfillment.cpp.
extension SwiftGenericBinding {
    struct Fulfillments {
        var types: [SwiftFormalType] = []
        var conformances: [(SwiftFormalType, Set<String>)] = []
        var shapes: Set<String> = []
    }

    func argumentFulfillments() throws -> Fulfillments {
        var result = Fulfillments()
        func archetype(_ type: SwiftFormalType) -> Bool {
            guard case .named(let name, let parameters) = type, parameters.isEmpty else { return false }
            return arguments[String(name.prefix { $0 != "." })] != nil
        }
        func superclass(_ type: SwiftFormalType) -> SwiftFormalType? {
            for candidate in equivalentTypes(of: type) {
                for requirement in declaration.requirements {
                    if case .superclass(let subject, let constraint) = requirement, candidate == subject { return constraint }
                }
            }
            return nil
        }
        func searchType(_ type: SwiftFormalType, exact: Bool) throws {
            let type = canonicalType(of: type)
            if exact && archetype(type) {
                if !result.types.contains(type) { result.types.append(type) }
            }
            if let base = superclass(type) { try searchNominal(base) }
            else { try searchNominal(type) }
        }
        func searchNominal(_ type: SwiftFormalType) throws {
            let parameters: [SwiftFormalType]
            if case .reference(_, let arguments) = type { parameters = arguments }
            else if let declaration = type.nominalDeclaration { parameters = declaration.arguments }
            else { return }
            guard !parameters.isEmpty else { return }
            let metadata = try types(type)[0]
            let context = try SwiftGenericTypeContext(metadata: metadata)
            guard context.parameters.count == parameters.count else {
                throw ABIResolutionError.metadataUnavailable("The nominal metadata does not match its formal generic arguments.")
            }
            let substitutions = Dictionary(uniqueKeysWithValues: zip(context.parameters.map(\.name), parameters))
            for parameter in context.parameters where context.keyParameters.contains(parameter.name) {
                let argument = substitutions[parameter.name]!
                if parameter.isPack {
                    if case .pack(let pattern) = argument, archetype(pattern) {
                        if !result.types.contains(pattern) { result.types.append(pattern) }
                        result.shapes.insert(pattern.spelling)
                    }
                } else { try searchType(argument, exact: true) }
            }
            for conformance in context.conformances {
                let subject = conformance.subject.substituting(substitutions)
                guard archetype(subject), let descriptor = conformance.descriptor else { continue }
                result.conformances.append((subject, try descriptor.qualifiedNames()))
            }
        }
        func consider(_ type: SwiftFormalType) throws {
            let type = canonicalType(of: type)
            switch type {
            case .inoutValue, .pack: return
            case .borrowing(let value), .consuming(let value): try consider(value)
            case .tuple(let fields): try fields.forEach(consider)
            case .metatype(let instance):
                // A nominal value metatype is thin even when it contains
                // archetypes. A class metatype can supply nominal metadata.
                if let base = superclass(instance) { try searchNominal(base) }
                else if !archetype(instance), try types(instance).first is AnyClass {
                    try searchType(instance, exact: false)
                }
            case .nominal, .nested, .reference:
                if try types(type).first is AnyClass { try searchType(type, exact: false) }
            case .named:
                if let base = superclass(type) { try searchNominal(base) }
            default: return
            }
        }
        try declaration.arguments.forEach(consider)
        return result
    }
}

extension SwiftFormalType {
    func substituting(_ substitutions: [String: Self]) -> Self {
        switch self {
        case .named(let name, let arguments):
            if arguments.isEmpty {
                if let value = substitutions[name] { return value }
                if let dot = name.firstIndex(of: "."), let value = substitutions[String(name[..<dot])] {
                    return .named(value.spelling + name[dot...], [])
                }
            }
            return .named(name, arguments.map { $0.substituting(substitutions) })
        case .nominal(let name, let arguments): return .nominal(name, arguments.map { $0.substituting(substitutions) })
        case .reference(let descriptor, let arguments): return .reference(descriptor, arguments.map { $0.substituting(substitutions) })
        case .nested(let parent, let name, let arguments):
            return .nested(parent.substituting(substitutions), name, arguments.map { $0.substituting(substitutions) })
        case .tuple(let elements): return .tuple(elements.map { $0.substituting(substitutions) })
        case .pack(let value): return .pack(value.substituting(substitutions))
        case .borrowing(let value): return .borrowing(value.substituting(substitutions))
        case .consuming(let value): return .consuming(value.substituting(substitutions))
        case .inoutValue(let value): return .inoutValue(value.substituting(substitutions))
        case .metatype(let value): return .metatype(value.substituting(substitutions))
        case .function(let parameters, let result, let failure, let isAsync):
            return .function(parameters.map { $0.substituting(substitutions) }, result.substituting(substitutions),
                failure: failure?.substituting(substitutions), isAsync: isAsync)
        }
    }
}
