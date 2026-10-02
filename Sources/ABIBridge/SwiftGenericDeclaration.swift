import Foundation

/// The canonical demangled declaration is the source of formal types. Concrete
/// function metadata alone loses generic indirection and tuple/pack expansion.
struct SwiftGenericDeclaration: Sendable {
    struct Parameter: Sendable {
        let name: String
        let isPack: Bool
    }
    enum Requirement: Sendable, Equatable {
        case conformance(SwiftFormalType, String)
        case sameType(SwiftFormalType, SwiftFormalType)
        case sameShape(SwiftFormalType, SwiftFormalType)
    }
    let parameters: [Parameter]
    let requirements: [Requirement]
    let arguments: [SwiftFormalType]
    let result: SwiftFormalType
    let failure: SwiftFormalType?
    let isAsync: Bool
    let head: String

    init(_ declaration: String, linkageName: String, enclosing context: SwiftGenericTypeContext? = nil) throws {
        var parsed = try Self(declaration)
        if let context { parsed = Self(parsed, enclosing: context) }
        let packs = try parsed.packParameters(in: linkageName, enclosing: context)
        parameters = parsed.parameters.map { parameter in
            Parameter(name: parameter.name, isPack: context?.parameters.first {
                $0.name == parameter.name
            }?.isPack ?? packs.contains(parameter.name))
        }
        var requirements = parsed.requirements
        arguments = parsed.arguments
        result = parsed.result
        failure = parsed.failure
        isAsync = parsed.isAsync
        head = parsed.head
        if let member = SwiftConstrainedExtension(SymbolIndex.extensionMemberName(declaration) ?? declaration) {
            let names = Set(parsed.parameters.map(\.name))
            for requirement in member.requirements {
                guard let equality = requirement.range(of: "==") else { continue }
                let lhs = try SwiftFormalType(String(requirement[..<equality.lowerBound]))
                let rhs = String(requirement[equality.upperBound...])
                let type = try SwiftFormalType(rhs)
                guard let index = requirements.firstIndex(of: .sameType(lhs, type)) else { continue }
                var references: [String: [Bool]] = [:]
                for (occurrence, reference) in SwiftGenericSyntax.names(in: rhs).enumerated() where reference.contains(".") {
                    guard let root = reference.split(separator: ".").first, names.contains(String(root)),
                          !SwiftGenericSyntax.isTupleLabel(reference, in: rhs) else { continue }
                    references[String(reference), default: []].append(SymbolIndex.dependentType(String(reference),
                        requirement: requirement, in: linkageName, extensionMember: member, occurrence: occurrence))
                }
                requirements[index] = .sameType(lhs, type.classifyingReferences(&references))
            }
        }
        self.requirements = requirements
    }

    init(_ declaration: Self, enclosing context: SwiftGenericTypeContext) {
        // NodePrinter prints a method's local generic parameters starting at
        // depth zero even inside a generic nominal context. Its actual formal
        // types and requirements retain the enclosing depth.
        let nextDepth = (context.parameters.map {
            Int($0.name.drop(while: { $0.isLetter })) ?? 0
        }.max() ?? -1) + 1
        var own: [Parameter] = []
        var depth = nextDepth
        for group in SwiftGenericSyntax.groups(in: declaration.head) {
            if declaration.head[group.range.upperBound...].first == "." { continue }
            let fields = SwiftGenericSyntax.split(Substring(group.contents.components(separatedBy: " where ")[0]))
            for (index, field) in fields.enumerated() where !field.trimmingCharacters(in: .whitespaces).isEmpty {
                var position = index, name = ""
                repeat {
                    name.append(Character(UnicodeScalar(65 + position % 26)!))
                    position /= 26
                } while position != 0
                if depth != 0 { name += String(depth) }
                own.append(.init(name: name, isPack: field.trimmingCharacters(in: .whitespaces).hasPrefix("each ")))
            }
            depth += 1
        }
        parameters = context.parameters + own
        requirements = declaration.requirements
        arguments = declaration.arguments
        result = declaration.result
        failure = declaration.failure
        isAsync = declaration.isAsync
        head = declaration.head
    }

    private func packParameters(in linkageName: String, enclosing nominal: SwiftGenericTypeContext? = nil) throws -> Set<String> {
        // Swift 6.3's NodePrinter swaps depth/index when printing `each`, so the
        // displayed signature can omit or misplace it. Read the ABI marker's
        // depth/index, then vary only that index to distinguish the operator
        // from identical bytes in an identifier. The native demangler must
        // preserve the entire declaration apart from pack annotations.
        // Demangler.cpp: demangleGenericRequirement / demangleGenericParamIndex.
        let expression = try NSRegularExpression(pattern: #"Rv(z|d(?:_|[0-9]+_)(?:_|[0-9]+_)|_|[0-9]+_)"#)
        func context(_ head: String) -> String {
            var value = head
            for group in SwiftGenericSyntax.groups(in: head).reversed() { value.removeSubrange(group.range) }
            return value
        }
        var packs: Set<String> = []
        for match in expression.matches(in: linkageName, range: NSRange(linkageName.startIndex..., in: linkageName)) {
            guard let range = Range(match.range, in: linkageName) else { continue }
            let marker = linkageName[range].dropFirst(2)
            let probe = linkageName.replacingCharacters(in: range, with: marker == "d__" ? "Rvz" : "Rvd__")
            guard let name = DeclarationKey.demangle(probe, language: .swift), var candidate = try? Self(name) else { continue }
            if let nominal { candidate = Self(candidate, enclosing: nominal) }
            guard context(candidate.head) == context(head), candidate.parameters.map(\.name) == parameters.map(\.name),
                  candidate.arguments == arguments, candidate.result == result,
                  candidate.failure == failure, candidate.isAsync == isAsync,
                  candidate.requirements == requirements else { continue }
            var remainder = marker[...]
            func encodedIndex() -> Int? {
                guard let separator = remainder.firstIndex(of: "_") else { return nil }
                let value = remainder[..<separator]
                remainder = remainder[remainder.index(after: separator)...]
                if value.isEmpty { return 0 }
                guard let index = Int(value), index < Int.max - 1 else { return nil }
                return index + 1
            }
            let depth: Int, index: Int
            if remainder == "z" { depth = 0; index = 0 }
            else if remainder.first == "d" {
                remainder = remainder.dropFirst()
                guard let context = encodedIndex(), let position = encodedIndex() else { continue }
                depth = context + 1; index = position
            } else {
                guard let position = encodedIndex() else { continue }
                depth = 0; index = position + 1
            }
            var position = index, parameter = ""
            repeat {
                parameter.append(Character(UnicodeScalar(65 + position % 26)!))
                position /= 26
            } while position != 0
            if depth != 0 { parameter += String(depth) }
            if parameters.contains(where: { $0.name == parameter }) { packs.insert(parameter) }
        }
        return packs
    }

    init(_ declaration: String) throws {
        let text = declaration.trimmingCharacters(in: .whitespaces)
        guard let arrow = SwiftFormalSyntax.topLevelArrow(in: text) else {
            throw ABIResolutionError.unsupportedDeclaration("A generic call requires a complete Swift declaration: " + declaration)
        }
        let input = String(text[..<arrow.lowerBound])
        guard let opening = SwiftFormalSyntax.parameterOpening(in: input),
              let closing = SwiftFormalSyntax.matchingClose(in: input, opening: opening) else {
            throw ABIResolutionError.unsupportedDeclaration("Missing Swift parameter list: " + declaration)
        }
        head = String(input[..<opening]).trimmingCharacters(in: .whitespaces)
        var parameters: [Parameter] = []
        var requirements: [Requirement] = []
        for group in SwiftGenericSyntax.groups(in: head) {
            let pieces = group.contents.components(separatedBy: " where ")
            for raw in SwiftGenericSyntax.split(Substring(pieces[0])) {
                let name = raw.trimmingCharacters(in: .whitespaces)
                parameters.append(Parameter(name: name.hasPrefix("each ") ? String(name.dropFirst(5)) : name,
                                            isPack: name.hasPrefix("each ")))
            }
            if pieces.count > 1 {
                for raw in SwiftGenericSyntax.split(Substring(pieces[1])) {
                    if let equality = raw.range(of: "==") {
                        let left = raw[..<equality.lowerBound].trimmingCharacters(in: .whitespaces)
                        let right = raw[equality.upperBound...].trimmingCharacters(in: .whitespaces)
                        if left.hasSuffix(".shape"), right.hasSuffix(".shape") {
                            requirements.append(.sameShape(try SwiftFormalType(String(left.dropLast(6))),
                                try SwiftFormalType(String(right.dropLast(6)))))
                        } else {
                            requirements.append(.sameType(try SwiftFormalType(left), try SwiftFormalType(right)))
                        }
                    } else if let shape = raw.range(of: " ~ ") {
                        requirements.append(.sameShape(try SwiftFormalType(String(raw[..<shape.lowerBound])),
                            try SwiftFormalType(String(raw[shape.upperBound...]))))
                    } else if let colon = raw.firstIndex(of: ":") {
                        let subject = try SwiftFormalType(String(raw[..<colon]))
                        let protocols = raw[raw.index(after: colon)...].split(separator: "&")
                        for name in protocols {
                            requirements.append(.conformance(subject, name.trimmingCharacters(in: .whitespaces)))
                        }
                    } else {
                        throw ABIResolutionError.unsupportedDeclaration("Unrecognized Swift generic requirement: " + raw)
                    }
                }
            }
        }
        let shapeParameters = Set(requirements.flatMap { requirement -> [String] in
            if case .sameShape(let left, let right) = requirement { return [left.spelling, right.spelling] }
            return []
        })
        self.parameters = parameters.map {
            Parameter(name: $0.name, isPack: $0.isPack || shapeParameters.contains($0.name))
        }
        self.requirements = requirements
        let fields = input[input.index(after: opening)..<closing]
        arguments = try SwiftFormalSyntax.fields(fields).map { try SwiftFormalType($0) }
        result = try SwiftFormalType(String(text[arrow.upperBound...]))
        let effects = input[input.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        isAsync = effects.split(whereSeparator: \.isWhitespace).contains("async")
        failure = try SwiftFormalSyntax.failure(in: effects)
    }
}

indirect enum SwiftFormalType: Sendable, Equatable {
    case named(String, [SwiftFormalType])
    case nominal(String, [SwiftFormalType])
    case tuple([SwiftFormalType])
    case function([SwiftFormalType], SwiftFormalType, failure: SwiftFormalType?, isAsync: Bool)
    case pack(SwiftFormalType)
    case inoutValue(SwiftFormalType)
    case borrowing(SwiftFormalType)
    case consuming(SwiftFormalType)
    case metatype(SwiftFormalType)

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

    /// Classification belongs to this occurrence, not to an identifier-wide map:
    /// a module and a generic parameter can have the same demangled spelling.
    fileprivate func classifyingReferences(_ references: inout [String: [Bool]]) -> Self {
        func next(_ name: String) -> Bool? {
            guard let values = references[name], !values.isEmpty else { return nil }
            references[name] = Array(values.dropFirst())
            return values[0]
        }
        switch self {
        case .named(let name, let arguments), .nominal(let name, let arguments):
            let dependent = next(name)
            let arguments = arguments.map { $0.classifyingReferences(&references) }
            return dependent == false ? .nominal(name, arguments) : .named(name, arguments)
        case .metatype(let value):
            if let dependent = next(spelling) { return dependent ? self : .nominal(spelling, []) }
            return .metatype(value.classifyingReferences(&references))
        case .tuple(let fields): return .tuple(fields.map { $0.classifyingReferences(&references) })
        case .function(let arguments, let result, let failure, let isAsync):
            let arguments = arguments.map { $0.classifyingReferences(&references) }
            let failure = failure?.classifyingReferences(&references)
            return .function(arguments, result.classifyingReferences(&references), failure: failure, isAsync: isAsync)
        case .pack(let type): return .pack(type.classifyingReferences(&references))
        case .inoutValue(let type): return .inoutValue(type.classifyingReferences(&references))
        case .borrowing(let type): return .borrowing(type.classifyingReferences(&references))
        case .consuming(let type): return .consuming(type.classifyingReferences(&references))
        }
    }

    var spelling: String {
        switch self {
        case .named(let name, let arguments), .nominal(let name, let arguments):
            name + (arguments.isEmpty ? "" : "<" + arguments.map(\.spelling).joined(separator: ", ") + ">")
        case .tuple(let values): "(" + values.map(\.spelling).joined(separator: ", ") + ")"
        case .function(let arguments, let result, let failure, let isAsync):
            "(" + arguments.map(\.spelling).joined(separator: ", ") + ")"
                + (isAsync ? " async" : "")
                + (failure.map { $0.spelling == "Swift.Error" ? " throws" : " throws(" + $0.spelling + ")" } ?? "")
                + " -> " + result.spelling
        case .pack(let value): "repeat " + value.spelling
        case .inoutValue(let value): "inout " + value.spelling
        case .borrowing(let value): "__shared " + value.spelling
        case .consuming(let value): "__owned " + value.spelling
        case .metatype(let value): value.spelling + ".Type"
        }
    }
}

/// A lookup key preserves the member and labels while its bound signature is
/// checked separately. This lets ordinary member names select generic entries.
enum SwiftMemberLookup {
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
            if "(<[".contains(character) { depth += 1 }
            else if ")]".contains(character) || (character == ">" && previous != "-") { depth -= 1 }
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
