import ABIBridgeRuntime
import Foundation

/// Formal declaration types preserve generic indirection and pack expansion that concrete function metadata cannot describe.
struct SwiftGenericDeclaration: Sendable, Equatable {
    struct Parameter: Sendable, Equatable {
        let name: String
        let isPack: Bool
    }
    enum Requirement: Sendable, Equatable {
        case conformance(SwiftFormalType, String)
        case sameType(SwiftFormalType, SwiftFormalType)
        case sameShape(SwiftFormalType, SwiftFormalType)
        case superclass(SwiftFormalType, SwiftFormalType)
        case invertedProtocols(SwiftFormalType, UInt16)
    }
    let parameters: [Parameter]
    var requirements: [Requirement]
    let arguments: [SwiftFormalType]
    let result: SwiftFormalType
    let failure: SwiftFormalType?
    let isAsync: Bool
    let consumesArguments: Bool
    // An explicit canonical signature describes physical generic arguments.
    // The full requirements above remain available for constraint validation.
    var abiRequirements: [Requirement]? = nil
    var implicitRequirements: [Requirement] = []
    var protocolSelf: SwiftFormalType? = nil
    var dispatchProtocol: String? = nil
    var borrowedInputs: Set<SwiftBorrowedInputs.Input>? = nil

}

/// Source-level information omitted from a callable's mangling, supplied by the caller using the provider's canonical generic signature.
struct SwiftDeclaredSignature {
    let function: SwiftFormalType
    let genericClause: String?

    init(_ source: String) throws {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<") {
            guard let group = SwiftGenericSyntax.groups(in: text).first,
                group.range.lowerBound == text.startIndex
            else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Incomplete declaredAs: generic signature: " + source
                )
            }
            genericClause = String(group.contents)
            function = try SwiftFormalType(String(text[group.range.upperBound...]))
        } else {
            genericClause = nil
            function = try SwiftFormalType(text)
        }
        guard case .function = function else {
            throw ABIResolutionError.unsupportedDeclaration(
                "declaredAs: requires a Swift function type: " + source
            )
        }
    }

    func requirements(
        for declaration: SwiftGenericDeclaration
    ) throws -> [SwiftGenericDeclaration.Requirement]? {
        guard let genericClause else { return nil }
        let clause = genericClause.range(of: " where ")
        let parameterText = clause.map { String(genericClause[..<$0.lowerBound]) } ?? genericClause
        let names = SwiftFormalSyntax.fields(parameterText[...]).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let expected = declaration.parameters.map { ($0.isPack ? "each " : "") + $0.name }
        guard names == expected else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    expected: "Generic parameters " + expected.joined(separator: ", "),
                    found: names
                )
            )
        }
        guard let clause else { return [] }
        func type(_ text: String) throws -> SwiftFormalType {
            let value = try SwiftFormalType(text)
            if case .named(let name, []) = value {
                let parts = name.split(separator: ".").map(String.init)
                if let root = parts.first,
                    declaration.parameters.contains(where: { $0.name == root })
                {
                    return parts.dropFirst().reduce(.named(root, [])) { .associated($0, $1) }
                }
            }
            return value
        }
        return try SwiftFormalSyntax.fields(genericClause[clause.upperBound...]).map { field in
            let colon = SwiftFormalSyntax.topLevelColon(in: field)
            for separator in ["==", "~"] where separator == "==" || colon == nil {
                if let range = field.range(of: separator) {
                    let left = try type(String(field[..<range.lowerBound]))
                    let right = try type(String(field[range.upperBound...]))
                    return separator == "==" ? .sameType(left, right) : .sameShape(left, right)
                }
            }
            guard let colon else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Invalid declaredAs: generic requirement: " + field
                )
            }
            let subject = try type(String(field[..<colon]))
            let constraintText = field[field.index(after: colon)...].trimmingCharacters(
                in: .whitespaces
            )
            if constraintText.hasPrefix("~") {
                switch constraintText.dropFirst().trimmingCharacters(in: .whitespaces) {
                case "Copyable", "Swift.Copyable": return .invertedProtocols(subject, 1)
                case "Escapable", "Swift.Escapable": return .invertedProtocols(subject, 2)
                default:
                    throw ABIResolutionError.unsupportedDeclaration(
                        "Unknown inverted protocol: " + constraintText
                    )
                }
            }
            let constraint = try type(constraintText)
            // Superclass requirements are encoded in the declaration. Reuse
            // that classification rather than infer it from current conformances.
            if let requirement = declaration.requirements.first(where: {
                guard case .superclass(_, let known) = $0 else { return false }
                return DeclarationKey.make(known.spelling, language: .swift)
                    == DeclarationKey.make(constraint.spelling, language: .swift)
            }), case .superclass(_, let known) = requirement {
                return .superclass(subject, known)
            }
            return .conformance(subject, constraint.spelling)
        }
    }
}

struct SwiftFunctionAttributes: Sendable, Equatable {
    typealias Isolation = RuntimeFunctionMetadata.Isolation
    typealias Differentiability = RuntimeFunctionMetadata.Differentiability
    var isAsync = false
    var isEscaping = false
    var isSendable = false
    var isolation: Isolation = .none
    var globalActor: SwiftFormalType?
    var differentiability: Differentiability = .none
    var hasSendingResult = false
    // Ownership remains on each formal parameter; these are its other ABI flags.
    var parameterFlags: [UInt32] = []
    /// Nil means no declaration states the dependencies; an empty set states no borrows.
    var borrowedInputs: Set<SwiftBorrowedInputs.Input>?
    var lifetimeUsesReceiver = false

    func loweredParameters(_ parameters: [SwiftFormalType]) -> [SwiftFormalType] {
        guard !parameterFlags.isEmpty else { return parameters }
        // Function metadata keeps the variadic element type; calls pass one Array.
        return parameters.enumerated().map { index, type in
            parameterFlags[index] & 0x80 != 0 ? .nominal("Swift.Array", [type]) : type
        }
    }

    var spelling: String {
        var result = isEscaping ? "@escaping " : "@noescape "
        if isSendable { result += "@Sendable " }
        switch isolation {
        case .none: break
        case .isolatedAny: result += "@isolated(any) "
        case .caller: result += "nonisolated(nonsending) "
        }
        if let globalActor { result += "@" + globalActor.spelling + " " }
        if differentiability != .none { result += "@differentiable(\(differentiability)) " }
        return result
    }
}

indirect enum SwiftFormalType: Sendable, Equatable {
    enum ForeignConvention: String, Sendable { case c, block }
    case named(String, [SwiftFormalType])
    case nominal(String, [SwiftFormalType])
    struct ExistentialConstraint: Sendable, Equatable {
        let subject: String
        let value: SwiftFormalType
    }
    case constrainedExistential(
        base: String,
        superclass: SwiftFormalType?,
        constraints: [ExistentialConstraint],
        shape: String?
    )
    case objectiveCClass(String)
    case opaqueResult(index: Int)
    case nested(SwiftFormalType, String, [SwiftFormalType])
    case reference(SwiftNominalDescriptor, [SwiftFormalType])
    case associated(SwiftFormalType, String, protocolName: String? = nil)
    case tuple([SwiftFormalType], labels: [String]? = nil)
    case function(
        [SwiftFormalType],
        SwiftFormalType,
        failure: SwiftFormalType?,
        attributes: SwiftFunctionAttributes = .init()
    )
    case foreignFunction(ForeignConvention, [SwiftFormalType], SwiftFormalType)
    case pack(SwiftFormalType, shape: SwiftFormalType? = nil)
    case packValue([SwiftFormalType])
    case inoutValue(SwiftFormalType)
    case borrowing(SwiftFormalType)
    case consuming(SwiftFormalType)
    case metatype(SwiftFormalType)
    case existentialMetatype(SwiftFormalType)

    var opaqueIndex: Int? {
        if case .opaqueResult(let index) = self { return index }
        return nil
    }

    var opaqueIndices: Set<Int> {
        switch self {
        case .opaqueResult(let index): [index]
        case .constrainedExistential(_, let superclass, let constraints, _):
            constraints.reduce(into: superclass?.opaqueIndices ?? []) {
                $0.formUnion($1.value.opaqueIndices)
            }
        case .named(_, let values), .nominal(_, let values), .reference(_, let values),
            .tuple(let values, _), .packValue(let values):
            values.reduce(into: []) { $0.formUnion($1.opaqueIndices) }
        case .nested(let parent, _, let values):
            values.reduce(into: parent.opaqueIndices) { $0.formUnion($1.opaqueIndices) }
        case .associated(let parent, _, _), .inoutValue(let parent), .borrowing(let parent),
            .consuming(let parent), .metatype(let parent), .existentialMetatype(let parent):
            parent.opaqueIndices
        case .function(let values, let result, let failure, _):
            values.reduce(into: result.opaqueIndices.union(failure?.opaqueIndices ?? [])) {
                $0.formUnion($1.opaqueIndices)
            }
        case .foreignFunction(_, let values, let result):
            values.reduce(into: result.opaqueIndices) { $0.formUnion($1.opaqueIndices) }
        case .pack(let value, let shape): value.opaqueIndices.union(shape?.opaqueIndices ?? [])
        case .objectiveCClass: []
        }
    }

    init(_ source: String, isFunctionParameter: Bool = false) throws {
        var text = source.trimmingCharacters(in: .whitespaces)
        if text == "some" { self = .opaqueResult(index: 0); return }
        // Labels are outside the type grammar, including labeled tuple fields.
        if let colon = SwiftFormalSyntax.topLevelColon(in: text) {
            text = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("repeat ") {
            self = .pack(try Self(String(text.dropFirst(7))))
            return
        }
        if text.hasPrefix("Pack{"), text.hasSuffix("}") {
            self = .packValue(
                try SwiftFormalSyntax.fields(text.dropFirst(5).dropLast()).map { try Self($0) }
            )
            return
        }
        if text.hasPrefix("each ") { text = String(text.dropFirst(5)) }
        for (prefix, wrap) in [
            ("inout ", Self.inoutValue), ("__shared ", Self.borrowing),
            ("borrowing ", Self.borrowing), ("__owned ", Self.consuming),
            ("consuming ", Self.consuming),
        ] where text.hasPrefix(prefix) {
            self = wrap(try Self(String(text.dropFirst(prefix.count))))
            return
        }
        var attributes = SwiftFunctionAttributes(isEscaping: !isFunctionParameter)
        var lifetimes: [String] = []
        while true {
            let qualifiers = [
                "@escaping ", "@noescape ", "@Sendable ", "@concurrent ",
                "nonisolated(nonsending) ", "@isolated(any) ",
            ]
            if let prefix = qualifiers.first(where: { text.hasPrefix($0) }) {
                switch prefix {
                case "@escaping ": attributes.isEscaping = true
                case "@noescape ": attributes.isEscaping = false
                case "@Sendable ": attributes.isSendable = true
                case "nonisolated(nonsending) ": attributes.isolation = .caller
                case "@isolated(any) ": attributes.isolation = .isolatedAny
                default: attributes.isolation = .none
                }
                text = String(text.dropFirst(prefix.count))
            } else if text.prefix(while: { $0 != "(" && !$0.isWhitespace }) == "@_lifetime" {
                guard text.hasPrefix("@_lifetime("),
                    let closing = SwiftFormalSyntax.matchingClose(
                        in: text,
                        opening: text.index(text.startIndex, offsetBy: 10)
                    )
                else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "Incomplete @_lifetime in declaredAs: " + source
                    )
                }
                lifetimes.append(String(text[text.index(text.startIndex, offsetBy: 11)..<closing]))
                text = text[text.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            } else if text.hasPrefix("@differentiable("), let end = text.firstIndex(of: ")") {
                let kind = String(text[text.index(text.startIndex, offsetBy: 16)..<end])
                switch kind {
                case "forward": attributes.differentiability = .forward
                case "reverse": attributes.differentiability = .reverse
                case "normal": attributes.differentiability = .normal
                case "linear", "_linear": attributes.differentiability = .linear
                default:
                    throw ABIResolutionError.unsupportedDeclaration(
                        "Unknown Swift differentiability: " + kind
                    )
                }
                text = text[text.index(after: end)...].trimmingCharacters(in: .whitespaces)
            } else if text.first == "@", !text.hasPrefix("@convention("),
                let end = text.firstIndex(where: \.isWhitespace)
            {
                let name = String(text[text.index(after: text.startIndex)..<end])
                attributes.globalActor = try Self(name == "MainActor" ? "Swift.MainActor" : name)
                attributes.isSendable = true
                text = text[end...].trimmingCharacters(in: .whitespaces)
            } else {
                break
            }
        }
        for convention in [ForeignConvention.c, .block] {
            let prefix = "@convention(" + convention.rawValue + ") "
            if text.hasPrefix(prefix) {
                guard
                    case .function(let arguments, let result, nil, let attributes) = try Self(
                        String(text.dropFirst(prefix.count))
                    ),
                    !attributes.isAsync
                else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "A C or block function requires a synchronous nonthrowing signature."
                    )
                }
                self = .foreignFunction(convention, arguments, result)
                return
            }
        }
        if let arrow = SwiftFormalSyntax.topLevelArrow(in: text) {
            let input = String(text[..<arrow.lowerBound])
            guard let opening = SwiftFormalSyntax.parameterOpening(in: input),
                let closing = SwiftFormalSyntax.matchingClose(in: input, opening: opening)
            else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Missing callback parameter list: " + source
                )
            }
            let fields = input[input.index(after: opening)..<closing]
            let effects = input[input.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            let parameterFields = SwiftFormalSyntax.fields(fields)
            if !lifetimes.isEmpty {
                let dependencies = try SwiftBorrowedInputs.parse(
                    lifetimes,
                    parameters: parameterFields
                )
                attributes.borrowedInputs = dependencies.borrowed
                attributes.lifetimeUsesReceiver = dependencies.requiresReceiver
            }
            let parameters = try parameterFields.map {
                try Self.functionParameter($0)
            }
            attributes.parameterFlags = parameters.map(\.flags)
            if attributes.parameterFlags.allSatisfy({ $0 == 0 }) { attributes.parameterFlags = [] }
            attributes.isAsync = effects.split(whereSeparator: \.isWhitespace).contains("async")
            var result = String(text[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            if result.hasPrefix("sending ") {
                attributes.hasSendingResult = true; result = String(result.dropFirst(8))
            }
            self = .function(
                parameters.map(\.type),
                try Self(result),
                failure: try SwiftFormalSyntax.failure(in: effects),
                attributes: attributes
            )
            return
        }
        guard lifetimes.isEmpty else {
            throw ABIResolutionError.unsupportedDeclaration(
                "@_lifetime in declaredAs: requires a function type."
            )
        }
        if text.hasSuffix(".Type") {
            self = .metatype(try Self(String(text.dropLast(5))))
            return
        }
        if text.hasSuffix(".Protocol") {
            self = .metatype(try Self(String(text.dropLast(9))))
            return
        }
        if text.hasSuffix("?") {
            self = .named("Swift.Optional", [try Self(String(text.dropLast()))])
            return
        }
        if text.first == "[", text.last == "]" {
            let contents = String(text.dropFirst().dropLast())
            if let colon = SwiftFormalSyntax.topLevelColon(in: contents) {
                self = .named(
                    "Swift.Dictionary",
                    [
                        try Self(String(contents[..<colon])),
                        try Self(String(contents[contents.index(after: colon)...])),
                    ]
                )
            } else {
                self = .named("Swift.Array", [try Self(contents)])
            }
            return
        }
        if text.first == "(",
            let closing = SwiftFormalSyntax.matchingClose(in: text, opening: text.startIndex),
            closing == text.index(before: text.endIndex)
        {
            let fields = SwiftFormalSyntax.fields(text.dropFirst().dropLast())
            let values = try fields.map { try Self($0) }
            let names = fields.map { field in
                SwiftFormalSyntax.topLevelColon(in: field).map {
                    field[..<$0].trimmingCharacters(in: .whitespaces)
                } ?? ""
            }
            let labels = names.contains(where: { !$0.isEmpty }) ? names : nil
            if values.count == 1, case .pack = values[0] {
                self = .tuple(values, labels: labels)
            } else if values.count == 1 {
                self = values[0]
            } else {
                self = .tuple(values, labels: labels)
            }
            return
        }
        if let group = SwiftGenericSyntax.groups(in: text).last,
            group.range.upperBound == text.endIndex
        {
            self = .named(
                String(text[..<group.range.lowerBound]),
                try SwiftFormalSyntax.fields(group.contents).map { try Self($0) }
            )
            return
        }
        guard !text.isEmpty else {
            throw ABIResolutionError.unsupportedDeclaration("Missing Swift type in " + source)
        }
        self = .named(text == "Void" || text == "Swift.Void" ? "()" : text, [])
    }

    var spelling: String {
        switch self {
        case .named(let name, let arguments), .nominal(let name, let arguments):
            name
                + (arguments.isEmpty
                    ? "" : "<" + arguments.map(\.spelling).joined(separator: ", ") + ">")
        case .constrainedExistential(let base, let superclass, let constraints, _):
            (superclass.map { "any " + $0.spelling + " & " + String(base.dropFirst(4)) } ?? base)
                + (constraints.isEmpty
                    ? ""
                    : "<"
                        + constraints.map { $0.subject + " == " + $0.value.spelling }.joined(
                            separator: ", "
                        ) + ">")
        case .objectiveCClass(let name): name
        case .opaqueResult: "some"
        case .reference(let descriptor, let arguments):
            descriptor.name
                + (arguments.isEmpty
                    ? "" : "<" + arguments.map(\.spelling).joined(separator: ", ") + ">")
        case .nested(let parent, let name, let arguments):
            parent.spelling + "." + name
                + (arguments.isEmpty
                    ? "" : "<" + arguments.map(\.spelling).joined(separator: ", ") + ">")
        case .associated(let base, let name, let protocolName):
            base.spelling + "." + (protocolName.map { $0 + "." } ?? "") + name
        case .tuple(let values, let labels):
            "("
                + values.enumerated().map { index, value in
                    (labels?[index].isEmpty == false ? labels![index] + ": " : "") + value.spelling
                }.joined(separator: ", ") + ")"
        case .function(let arguments, let result, let failure, let attributes):
            attributes.spelling + "("
                + arguments.enumerated().map { index, type in
                    Self.parameterSpelling(
                        type.spelling,
                        flags: attributes.parameterFlags.isEmpty
                            ? 0 : attributes.parameterFlags[index]
                    )
                }.joined(separator: ", ") + ")"
                + (attributes.isAsync ? " async" : "")
                + (failure.map {
                    $0.spelling == "Swift.Error" ? " throws" : " throws(" + $0.spelling + ")"
                } ?? "")
                + " -> " + (attributes.hasSendingResult ? "sending " : "") + result.spelling
        case .foreignFunction(let convention, let arguments, let result):
            "@convention(" + convention.rawValue + ") ("
                + arguments.map(\.spelling).joined(separator: ", ") + ") -> " + result.spelling
        case .pack(let value, _): "repeat " + value.spelling
        case .packValue(let elements):
            "Pack{" + elements.map(\.spelling).joined(separator: ", ") + "}"
        case .inoutValue(let value): "inout " + value.spelling
        case .borrowing(let value): "__shared " + value.spelling
        case .consuming(let value): "__owned " + value.spelling
        case .metatype(let value): value.spelling + ".Type"
        case .existentialMetatype(let value): value.spelling + ".Type"
        }
    }

    private static func functionParameter(_ source: String) throws -> (type: Self, flags: UInt32) {
        var text = source.trimmingCharacters(in: .whitespaces), flags: UInt32 = 0
        if let colon = SwiftFormalSyntax.topLevelColon(in: text) {
            text = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Source borrowing canonicalizes to default function ownership; the
        // compiler's __shared spelling keeps its explicit Shared metadata flag.
        let qualifiers: [(String, UInt32)] = [
            ("borrowing ", 0), ("isolated ", 0x400), ("sending ", 0x800),
            ("@autoclosure ", 0x100), ("@noDerivative ", 0x200),
        ]
        while let qualifier = qualifiers.first(where: { text.hasPrefix($0.0) }) {
            flags |= qualifier.1
            text = String(text.dropFirst(qualifier.0.count))
        }
        if text.hasSuffix("...") { flags |= 0x80; text = String(text.dropLast(3)) }
        var type = try Self(text, isFunctionParameter: true)
        if flags & 0x800 != 0, type.argumentConvention == nil { type = .consuming(type) }
        return (type, flags)
    }

    static func parameterSpelling(_ type: String, flags: UInt32) -> String {
        (flags & 0x400 != 0 ? "isolated " : "") + (flags & 0x800 != 0 ? "sending " : "")
            + (flags & 0x100 != 0 ? "@autoclosure " : "")
            + (flags & 0x200 != 0 ? "@noDerivative " : "")
            + type + (flags & 0x80 != 0 ? "..." : "")
    }
}

/// A lookup key preserves the member and labels while its bound signature is checked separately. This lets ordinary member names select generic entries.
extension SwiftMemberLookup {
    static func qualifiedName(
        _ member: String,
        owner: String,
        isStatic: Bool = false
    ) throws -> String {
        guard isStatic || !member.hasPrefix("static ") else {
            throw ABIResolutionError.unsupportedDeclaration(
                "A static declaration requires a static member lookup."
            )
        }
        let name = isQualified(member) ? member : owner + "." + member
        return isStatic && !name.hasPrefix("static ") ? "static " + name : name
    }

}

extension SwiftFormalSyntax {
    static func failure(in effects: String) throws -> SwiftFormalType? {
        if let range = effects.range(of: "throws(") {
            let opening = effects.index(before: range.upperBound)
            guard let closing = matchingClose(in: effects, opening: opening) else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Incomplete Swift error type: " + effects
                )
            }
            let name = effects[range.upperBound..<closing].trimmingCharacters(in: .whitespaces)
            return ["any Error", "any Swift.Error", "Error"].contains(name)
                ? .named("Swift.Error", []) : try SwiftFormalType(name)
        }
        if effects.split(whereSeparator: \.isWhitespace).contains(where: {
            $0 == "throws" || $0 == "rethrows"
        }) {
            return .named("Swift.Error", [])
        }
        return nil
    }
}

extension SwiftFormalType {
    func qualifyingAssociatedTypes(
        using conformances: [SwiftGenericBinding.Conformance],
        requiringKnownProtocols: Bool = true
    ) throws -> Self {
        func qualify(_ type: Self) throws -> Self {
            try type.qualifyingAssociatedTypes(
                using: conformances,
                requiringKnownProtocols: requiringKnownProtocols
            )
        }
        switch self {
        case .objectiveCClass, .opaqueResult: return self
        case .constrainedExistential(let base, let superclass, let constraints, let shape):
            return .constrainedExistential(base: base, superclass: try superclass.map(qualify), constraints: try constraints.map {
                .init(subject: $0.subject, value: try qualify($0.value))
            }, shape: shape)
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
            guard names.count == 1 || !requiringKnownProtocols else {
                throw ABIResolutionError.metadataUnavailable("Cannot identify the declaring protocol for " + spelling + ".")
            }
            return .associated(
                try qualify(base),
                member,
                protocolName: names.count == 1 ? names.first : nil
            )
        case .named(let name, let values): return .named(name, try values.map(qualify))
        case .nominal(let name, let values): return .nominal(name, try values.map(qualify))
        case .reference(let descriptor, let values): return .reference(descriptor, try values.map(qualify))
        case .nested(let parent, let name, let values): return .nested(try qualify(parent), name, try values.map(qualify))
        case .tuple(let values, let labels): return .tuple(try values.map(qualify), labels: labels)
        case .packValue(let values): return .packValue(try values.map(qualify))
        case .pack(let value, let shape): return .pack(try qualify(value), shape: try shape.map(qualify))
        case .metatype(let value): return .metatype(try qualify(value))
        case .existentialMetatype(let value): return .existentialMetatype(try qualify(value))
        case .borrowing(let value): return .borrowing(try qualify(value))
        case .consuming(let value): return .consuming(try qualify(value))
        case .inoutValue(let value): return .inoutValue(try qualify(value))
        case .function(let values, let result, let failure, let attributes):
            var attributes = attributes
            attributes.globalActor = try attributes.globalActor.map(qualify)
            return .function(try values.map(qualify), try qualify(result), failure: try failure.map(qualify), attributes: attributes)
        case .foreignFunction(let convention, let values, let result):
            return .foreignFunction(convention, try values.map(qualify), try qualify(result))
        }
    }
}

extension SwiftFormalType {
    var hasDeclaredLifetime: Bool {
        switch self {
        case .function(let arguments, let result, let failure, let attributes):
            attributes.borrowedInputs != nil || arguments.contains(where: \.hasDeclaredLifetime)
                || result.hasDeclaredLifetime || failure?.hasDeclaredLifetime == true
        case .named(_, let values), .nominal(_, let values), .reference(_, let values),
            .tuple(let values, _), .packValue(let values):
            values.contains(where: \.hasDeclaredLifetime)
        case .nested(let parent, _, let values):
            parent.hasDeclaredLifetime || values.contains(where: \.hasDeclaredLifetime)
        case .associated(let value, _, _), .inoutValue(let value), .borrowing(let value),
            .consuming(let value), .metatype(let value), .existentialMetatype(let value):
            value.hasDeclaredLifetime
        case .pack(let value, let shape):
            value.hasDeclaredLifetime || shape?.hasDeclaredLifetime == true
        case .foreignFunction(_, let values, let result):
            values.contains(where: \.hasDeclaredLifetime) || result.hasDeclaredLifetime
        case .constrainedExistential(_, let superclass, let constraints, _):
            superclass?.hasDeclaredLifetime == true
                || constraints.contains { $0.value.hasDeclaredLifetime }
        case .objectiveCClass, .opaqueResult: false
        }
    }
}
