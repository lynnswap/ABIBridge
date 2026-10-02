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
            isArchetype(type)
        }
        func superclass(_ type: SwiftFormalType) throws -> SwiftFormalType? {
            for candidate in try equivalentTypes(of: type) {
                for requirement in declaration.requirements {
                    if case .superclass(let subject, let constraint) = requirement, candidate == subject { return constraint }
                }
            }
            return nil
        }
        func expansion(_ type: SwiftFormalType) -> (pattern: SwiftFormalType, shape: SwiftFormalType)? {
            guard case .packValue(let elements) = type, elements.count == 1,
                  case .pack(let pattern, let shape) = elements[0] else { return nil }
            return (pattern, shape ?? pattern)
        }
        func searchType(_ type: SwiftFormalType, exact: Bool) throws {
            let type = try canonicalType(of: type)
            if exact && archetype(type) {
                if !result.types.contains(type) { result.types.append(type) }
            }
            if let base = try superclass(type) { try searchNominal(base) }
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
            for parameter in context.parameters {
                let argument = substitutions[parameter.name]!
                if parameter.isPack {
                    if let source = expansion(argument), archetype(source.pattern) {
                        result.shapes.insert(source.shape.spelling)
                        if context.keyParameters.contains(parameter.name),
                           !result.types.contains(source.pattern) { result.types.append(source.pattern) }
                    }
                } else if context.keyParameters.contains(parameter.name) { try searchType(argument, exact: true) }
            }
            for conformance in context.conformances {
                let substituted = conformance.subject.substituting(substitutions)
                let subject = expansion(substituted)?.pattern ?? substituted
                guard archetype(subject), let descriptor = conformance.descriptor else { continue }
                result.conformances.append((subject, try descriptor.qualifiedNames()))
            }
        }
        func consider(_ type: SwiftFormalType) throws {
            let type = try canonicalType(of: type)
            switch type {
            case .inoutValue, .pack: return
            case .borrowing(let value), .consuming(let value): try consider(value)
            case .tuple(let fields): try fields.forEach(consider)
            case .metatype(let instance):
                // A nominal value metatype is thin even when it contains
                // archetypes. A class metatype can supply nominal metadata.
                if let base = try superclass(instance) { try searchNominal(base) }
                else if !archetype(instance), try types(instance).first is AnyClass {
                    try searchType(instance, exact: false)
                }
            case .nominal, .nested, .reference:
                if try types(type).first is AnyClass { try searchType(type, exact: false) }
            case .named, .associated:
                if let base = try superclass(type) { try searchNominal(base) }
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
                    return name[name.index(after: dot)...].split(separator: ".").reduce(value) {
                        .associated($0, String($1))
                    }
                }
            }
            return .named(name, arguments.map { $0.substituting(substitutions) })
        case .nominal(let name, let arguments): return .nominal(name, arguments.map { $0.substituting(substitutions) })
        case .reference(let descriptor, let arguments): return .reference(descriptor, arguments.map { $0.substituting(substitutions) })
        case .nested(let parent, let name, let arguments):
            return .nested(parent.substituting(substitutions), name, arguments.map { $0.substituting(substitutions) })
        case .associated(let base, let name, let protocolName):
            return .associated(base.substituting(substitutions), name, protocolName: protocolName)
        case .tuple(let elements): return .tuple(elements.map { $0.substituting(substitutions) })
        case .pack(let value, let shape): return .pack(value.substituting(substitutions), shape: shape?.substituting(substitutions))
        case .packValue(let elements): return .packValue(elements.map { $0.substituting(substitutions) })
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
