import Foundation

/// Formal declaration types preserve generic indirection and pack expansion
/// that concrete function metadata cannot describe.
struct SwiftGenericDeclaration: Sendable {
    struct Parameter: Sendable {
        let name: String
        let isPack: Bool
    }
    enum Requirement: Sendable, Equatable {
        case conformance(SwiftFormalType, String)
        case sameType(SwiftFormalType, SwiftFormalType)
        case sameShape(SwiftFormalType, SwiftFormalType)
        case superclass(SwiftFormalType, SwiftFormalType)
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

}

/// Source-level information omitted from a callable's mangling, supplied by
/// the caller using the provider's canonical generic signature.
struct SwiftDeclaredSignature {
    let function: SwiftFormalType
    let genericClause: String?

    init(_ source: String) throws {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<") {
            guard let group = SwiftGenericSyntax.groups(in: text).first,
                  group.range.lowerBound == text.startIndex else {
                throw ABIResolutionError.unsupportedDeclaration("Incomplete declaredAs: generic signature: " + source)
            }
            genericClause = String(group.contents)
            function = try SwiftFormalType(String(text[group.range.upperBound...]))
        } else {
            genericClause = nil
            function = try SwiftFormalType(text)
        }
        guard case .function = function else {
            throw ABIResolutionError.unsupportedDeclaration("declaredAs: requires a Swift function type: " + source)
        }
    }

    func requirements(for declaration: SwiftGenericDeclaration) throws -> [SwiftGenericDeclaration.Requirement]? {
        guard let genericClause else { return nil }
        let clause = genericClause.range(of: " where ")
        let parameterText = clause.map { String(genericClause[..<$0.lowerBound]) } ?? genericClause
        let names = SwiftFormalSyntax.fields(parameterText[...]).map { $0.trimmingCharacters(in: .whitespaces) }
        let expected = declaration.parameters.map { ($0.isPack ? "each " : "") + $0.name }
        guard names == expected else {
            throw ABIResolutionError.signatureMismatch(.init(expected: "Generic parameters " + expected.joined(separator: ", "), found: names))
        }
        guard let clause else { return [] }
        func type(_ text: String) throws -> SwiftFormalType {
            let value = try SwiftFormalType(text)
            if case .named(let name, []) = value {
                let parts = name.split(separator: ".").map(String.init)
                if let root = parts.first, declaration.parameters.contains(where: { $0.name == root }) {
                    return parts.dropFirst().reduce(.named(root, [])) { .associated($0, $1) }
                }
            }
            return value
        }
        return try SwiftFormalSyntax.fields(genericClause[clause.upperBound...]).map { field in
            for separator in ["==", "~"] {
                if let range = field.range(of: separator) {
                    let left = try type(String(field[..<range.lowerBound]))
                    let right = try type(String(field[range.upperBound...]))
                    return separator == "==" ? .sameType(left, right) : .sameShape(left, right)
                }
            }
            guard let colon = SwiftFormalSyntax.topLevelColon(in: field) else {
                throw ABIResolutionError.unsupportedDeclaration("Invalid declaredAs: generic requirement: " + field)
            }
            let subject = try type(String(field[..<colon]))
            let constraint = try type(String(field[field.index(after: colon)...]))
            // Superclass requirements are encoded in the declaration. Reuse
            // that classification rather than infer it from current conformances.
            if declaration.requirements.contains(where: {
                guard case .superclass(_, let known) = $0 else { return false }
                return DeclarationKey.make(known.spelling, language: .swift) == DeclarationKey.make(constraint.spelling, language: .swift)
            }) { return .superclass(subject, constraint) }
            return .conformance(subject, constraint.spelling)
        }
    }
}

indirect enum SwiftFormalType: Sendable, Equatable {
    case named(String, [SwiftFormalType])
    case nominal(String, [SwiftFormalType])
    case nested(SwiftFormalType, String, [SwiftFormalType])
    case reference(SwiftNominalDescriptor, [SwiftFormalType])
    case associated(SwiftFormalType, String, protocolName: String? = nil)
    case tuple([SwiftFormalType])
    case function([SwiftFormalType], SwiftFormalType, failure: SwiftFormalType?, isAsync: Bool)
    case pack(SwiftFormalType, shape: SwiftFormalType? = nil)
    case packValue([SwiftFormalType])
    case inoutValue(SwiftFormalType)
    case borrowing(SwiftFormalType)
    case consuming(SwiftFormalType)
    case metatype(SwiftFormalType)
    case existentialMetatype(SwiftFormalType)

    init(_ source: String) throws {
        var text = source.trimmingCharacters(in: .whitespaces)
        // Labels are outside the type grammar, including labeled tuple fields.
        if let colon = SwiftFormalSyntax.topLevelColon(in: text) {
            text = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("repeat ") {
            self = .pack(try Self(String(text.dropFirst(7))))
            return
        }
        if text.hasPrefix("Pack{"), text.hasSuffix("}") {
            self = .packValue(try SwiftFormalSyntax.fields(text.dropFirst(5).dropLast()).map { try Self($0) })
            return
        }
        if text.hasPrefix("each ") { text = String(text.dropFirst(5)) }
        for (prefix, wrap) in [
            ("inout ", Self.inoutValue), ("__shared ", Self.borrowing),
            ("borrowing ", Self.borrowing), ("__owned ", Self.consuming),
            ("consuming ", Self.consuming)
        ] where text.hasPrefix(prefix) {
            self = wrap(try Self(String(text.dropFirst(prefix.count))))
            return
        }
        // These source qualifiers do not change the value storage convention.
        let qualifiers = ["@escaping ", "@noescape ", "@Sendable ", "@concurrent ", "nonisolated(nonsending) "]
        while let prefix = qualifiers.first(where: { text.hasPrefix($0) }) {
            text = String(text.dropFirst(prefix.count))
        }
        if let arrow = SwiftFormalSyntax.topLevelArrow(in: text) {
            let input = String(text[..<arrow.lowerBound])
            guard let opening = SwiftFormalSyntax.parameterOpening(in: input),
                  let closing = SwiftFormalSyntax.matchingClose(in: input, opening: opening) else {
                throw ABIResolutionError.unsupportedDeclaration("Missing callback parameter list: " + source)
            }
            let fields = input[input.index(after: opening)..<closing]
            let effects = input[input.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            self = .function(try SwiftFormalSyntax.fields(fields).map { try Self($0) },
                try Self(String(text[arrow.upperBound...])), failure: try SwiftFormalSyntax.failure(in: effects),
                isAsync: effects.split(whereSeparator: \.isWhitespace).contains("async"))
            return
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
                self = .named("Swift.Dictionary", [try Self(String(contents[..<colon])),
                    try Self(String(contents[contents.index(after: colon)...]))])
            } else {
                self = .named("Swift.Array", [try Self(contents)])
            }
            return
        }
        if text.first == "(", let closing = SwiftFormalSyntax.matchingClose(in: text, opening: text.startIndex),
           closing == text.index(before: text.endIndex) {
            let fields = SwiftFormalSyntax.fields(text.dropFirst().dropLast())
            let values = try fields.map { try Self($0) }
            if values.count == 1, case .pack = values[0] {
                self = .tuple(values)
            } else if values.count == 1 {
                self = values[0]
            } else {
                self = .tuple(values)
            }
            return
        }
        if let group = SwiftGenericSyntax.groups(in: text).last, group.range.upperBound == text.endIndex {
            self = .named(String(text[..<group.range.lowerBound]),
                try SwiftFormalSyntax.fields(group.contents).map { try Self($0) })
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
            name + (arguments.isEmpty ? "" : "<" + arguments.map(\.spelling).joined(separator: ", ") + ">")
        case .reference(let descriptor, let arguments):
            descriptor.name + (arguments.isEmpty ? "" : "<" + arguments.map(\.spelling).joined(separator: ", ") + ">")
        case .nested(let parent, let name, let arguments):
            parent.spelling + "." + name + (arguments.isEmpty ? "" : "<" + arguments.map(\.spelling).joined(separator: ", ") + ">")
        case .associated(let base, let name, let protocolName):
            base.spelling + "." + (protocolName.map { $0 + "." } ?? "") + name
        case .tuple(let values): "(" + values.map(\.spelling).joined(separator: ", ") + ")"
        case .function(let arguments, let result, let failure, let isAsync):
            "(" + arguments.map(\.spelling).joined(separator: ", ") + ")"
                + (isAsync ? " async" : "")
                + (failure.map { $0.spelling == "Swift.Error" ? " throws" : " throws(" + $0.spelling + ")" } ?? "")
                + " -> " + result.spelling
        case .pack(let value, _): "repeat " + value.spelling
        case .packValue(let elements): "Pack{" + elements.map(\.spelling).joined(separator: ", ") + "}"
        case .inoutValue(let value): "inout " + value.spelling
        case .borrowing(let value): "__shared " + value.spelling
        case .consuming(let value): "__owned " + value.spelling
        case .metatype(let value): value.spelling + ".Type"
        case .existentialMetatype(let value): value.spelling + ".Type"
        }
    }
}

/// A lookup key preserves the member and labels while its bound signature is
/// checked separately. This lets ordinary member names select generic entries.
enum SwiftMemberLookup {
    private static func owner(of declaration: String) -> String? {
        var text = SymbolIndex.extensionMemberName(declaration) ?? declaration
        if text.hasPrefix("static ") { text = String(text.dropFirst(7)) }
        let accessor = [".getter : ", ".setter : "].compactMap { text.range(of: $0)?.lowerBound }.first
        let opening = accessor ?? SwiftFormalSyntax.parameterOpening(in: text) ?? text.endIndex
        var head = String(text[..<opening])
        for group in SwiftGenericSyntax.groups(in: head).reversed() { head.removeSubrange(group.range) }
        return head.lastIndex(of: ".").map { String(head[..<$0]) }
    }

    static func isQualified(_ declaration: String) -> Bool { owner(of: declaration) != nil }

    static func hasSignature(_ declaration: String) -> Bool {
        SwiftFormalSyntax.topLevelArrow(in: declaration) != nil
            || declaration.contains(".getter : ") || declaration.contains(".setter : ")
    }

    /// Compare an explicitly supplied function/property signature independently
    /// of the context requirements, which the generic binding validates.
    static func signatureKey(_ declaration: String) -> [UInt8]? {
        let text = SymbolIndex.extensionMemberName(declaration) ?? declaration
        let opening = [".getter : ", ".setter : "].compactMap { text.range(of: $0)?.lowerBound }.first
            ?? SwiftFormalSyntax.parameterOpening(in: text)
        guard let opening else { return nil }
        var head = String(text[..<opening])
        for group in SwiftGenericSyntax.groups(in: head).reversed() { head.removeSubrange(group.range) }
        return DeclarationKey.make(head + text[opening...], language: .swift)
    }

    static func belongs(_ declaration: String, to owner: String) -> Bool {
        var nominal = owner
        for group in SwiftGenericSyntax.groups(in: nominal).reversed() { nominal.removeSubrange(group.range) }
        return Self.owner(of: declaration) == nominal
    }

    static func qualifiedName(_ member: String, owner: String, isStatic: Bool = false) throws -> String {
        guard isStatic || !member.hasPrefix("static ") else {
            throw ABIResolutionError.unsupportedDeclaration("A static declaration requires a static member lookup.")
        }
        let name = isQualified(member) ? member : owner + "." + member
        return isStatic && !name.hasPrefix("static ") ? "static " + name : name
    }

    static func key(_ declaration: String) -> [UInt8]? {
        let text = SymbolIndex.extensionMemberName(declaration) ?? declaration
        func head(_ source: String) -> String {
            var result = source
            for group in SwiftGenericSyntax.groups(in: source).reversed() { result.removeSubrange(group.range) }
            return result
        }
        for accessor in [".getter : ", ".setter : "] {
            if let range = text.range(of: accessor) {
                return DeclarationKey.make(head(String(text[..<range.lowerBound])) + accessor.components(separatedBy: " : ")[0])
            }
        }
        let input = SwiftFormalSyntax.topLevelArrow(in: text).map { String(text[..<$0.lowerBound]) } ?? text
        guard let opening = SwiftFormalSyntax.parameterOpening(in: input),
              let closing = SwiftFormalSyntax.matchingClose(in: input, opening: opening) else { return nil }
        let fields = input[input.index(after: opening)..<closing]
        let labels: [String]
        let possibleLabels = fields.split(separator: ":")
        if fields.last == ":", possibleLabels.allSatisfy({ field in
            !field.isEmpty && field.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }) {
            labels = possibleLabels.map(String.init)
        } else {
            labels = SwiftFormalSyntax.fields(fields).map { field in
                SwiftFormalSyntax.topLevelColon(in: field).map {
                    field[..<$0].trimmingCharacters(in: .whitespaces)
                } ?? "_"
            }
        }
        return DeclarationKey.make(head(String(input[..<opening])) + "(" + labels.map { $0 + ":" }.joined() + ")")
    }
}

enum SwiftFormalSyntax {
    static func fields(_ text: Substring) -> [String] {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : SwiftGenericSyntax.split(text)
    }

    static func parameterOpening(in text: String) -> String.Index? {
        var generics = 0
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character == "<" { generics += 1 }
            else if character == ">", previous != "-", generics > 0 { generics -= 1 }
            else if character == "(", generics == 0 {
                if let closing = matchingClose(in: text, opening: index),
                   text[text.index(after: closing)...].first.map({ $0 == "." || $0 == "<" }) == true { continue }
                return index
            }
            previous = character
        }
        return nil
    }

    static func matchingClose(in text: String, opening: String.Index) -> String.Index? {
        var depth = 0
        for index in text[opening...].indices {
            if text[index] == "(" { depth += 1 }
            else if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    static func topLevelArrow(in text: String) -> Range<String.Index>? {
        var parentheses = 0, generics = 0, brackets = 0
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character == "(", generics == 0 { parentheses += 1 }
            else if character == ")", generics == 0 { parentheses -= 1 }
            else if character == "[" { brackets += 1 }
            else if character == "]" { brackets -= 1 }
            else if character == "<" { generics += 1 }
            else if character == ">", previous == "-", parentheses == 0, generics == 0, brackets == 0 {
                return text.index(before: index)..<text.index(after: index)
            } else if character == ">", previous != "-", generics > 0 { generics -= 1 }
            previous = character
        }
        return nil
    }

    static func topLevelColon(in text: String) -> String.Index? {
        var depth = 0
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if "(<[{".contains(character) { depth += 1 }
            else if ")]}".contains(character) || (character == ">" && previous != "-") { depth -= 1 }
            else if character == ":", depth == 0 { return index }
            previous = character
        }
        return nil
    }

    static func failure(in effects: String) throws -> SwiftFormalType? {
        if let range = effects.range(of: "throws(") {
            let opening = effects.index(before: range.upperBound)
            guard let closing = matchingClose(in: effects, opening: opening) else {
                throw ABIResolutionError.unsupportedDeclaration("Incomplete Swift error type: " + effects)
            }
            return try SwiftFormalType(String(effects[range.upperBound..<closing]))
        }
        if effects.split(whereSeparator: \.isWhitespace).contains(where: { $0 == "throws" || $0 == "rethrows" }) {
            return .named("Swift.Error", [])
        }
        return nil
    }
}
