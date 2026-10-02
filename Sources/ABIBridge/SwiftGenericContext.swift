import Foundation

struct SwiftGenericContext: Hashable, Sendable {
    let identity: ObjectIdentifier
    let owner: String
    private let arguments: [String: String]

    init?(_ type: AnyClass, owner: String) throws {
        let name = try swiftFunctionTypeName(type)
        let groups = SwiftGenericSyntax.groups(in: name)
        guard !groups.isEmpty else { return nil }
        identity = ObjectIdentifier(type)
        self.owner = owner
        var arguments: [String: String] = [:]
        for (depth, group) in groups.enumerated() {
            for (index, argument) in SwiftGenericSyntax.split(group.contents).enumerated() {
                // Swift's demangler names parameters by index, then context depth.
                // lib/Demangling/NodePrinter.cpp: genericParameterName.
                var number = index
                var parameter = ""
                repeat {
                    parameter.append(Character(UnicodeScalar(65 + number % 26)!))
                    number /= 26
                } while number != 0
                if depth != 0 { parameter += String(depth) }
                arguments[parameter] = argument.trimmingCharacters(in: .whitespaces)
            }
        }
        self.arguments = arguments
    }

    func satisfies(_ extensionMember: SwiftConstrainedExtension,
                   isDependentType: (String, String) -> Bool) throws(ABIResolutionError) -> Bool {
        guard extensionMember.owner == owner else { return false }
        var unsupported: String?
        for requirement in extensionMember.requirements {
            let terms = requirement.components(separatedBy: "==").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard terms.count == 2, let actual = arguments[terms[0]] else {
                unsupported = requirement
                continue
            }
            let expected: String
            if let argument = arguments[terms[1]] {
                expected = argument
            } else {
                let names = SwiftGenericSyntax.names(in: terms[1])
                guard !names.contains(where: { name in
                    guard arguments[String(name.prefix { $0 != "." })] != nil else { return false }
                    guard !SwiftGenericSyntax.isTupleLabel(name, in: terms[1]) else { return false }
                    return !name.contains(".") || isDependentType(String(name), requirement)
                }) else {
                    unsupported = requirement
                    continue
                }
                expected = terms[1]
            }
            if DeclarationKey.make(actual, language: .swift) != DeclarationKey.make(expected, language: .swift) { return false }
        }
        if let unsupported {
            throw ABIResolutionError.unsupportedDeclaration(
                "Constrained Swift member requires a native adapter for \(unsupported)."
            )
        }
        return true
    }
}

struct SwiftConstrainedExtension {
    let owner: String
    let memberName: String
    let requirements: [String]

    init?(_ unqualified: String) {
        guard let group = SwiftGenericSyntax.groups(in: unqualified).first,
              let clause = group.contents.range(of: " where "),
              unqualified[group.range.upperBound...].first == "." else { return nil }
        let prefix = String(unqualified[..<group.range.lowerBound])
        owner = prefix.hasPrefix("static ") ? String(prefix.dropFirst(7)) : prefix
        memberName = prefix + unqualified[group.range.upperBound...]
        requirements = SwiftGenericSyntax.split(group.contents[clause.upperBound...])
        guard !requirements.isEmpty else { return nil }
    }
}

enum SwiftGenericSyntax {
    static func names(in type: String) -> [Substring] {
        type.split { $0.isWhitespace || "<>()[],:?!@&-=".contains($0) }
    }

    static func isTupleLabel(_ name: Substring, in type: String) -> Bool {
        guard type[name.endIndex...].drop(while: \.isWhitespace).first == ":" else { return false }
        var groups: [Character] = []
        var previous: Character?
        for character in type[..<name.startIndex] {
            if character == "(" || character == "[" || character == "<" { groups.append(character) }
            else if character == ")", groups.last == "(" { groups.removeLast() }
            else if character == "]", groups.last == "[" { groups.removeLast() }
            else if character == ">", previous != "-", groups.last == "<" { groups.removeLast() }
            previous = character
        }
        return groups.last == "("
    }

    struct Group {
        let range: Range<String.Index>
        let contents: Substring
    }

    static func groups(in text: String) -> [Group] {
        var result: [Group] = []
        var depth = 0
        var opening: String.Index?
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character == "<" {
                if depth == 0 { opening = index }
                depth += 1
            } else if character == ">", previous != "-", depth > 0 {
                depth -= 1
                if depth == 0, let start = opening {
                    result.append(Group(range: start..<text.index(after: index),
                                        contents: text[text.index(after: start)..<index]))
                }
            }
            previous = character
        }
        return result
    }

    static func split(_ text: Substring) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        var angle = 0, parentheses = 0, brackets = 0, braces = 0
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            switch character {
            case "<": angle += 1
            case ">" where previous != "-": angle -= 1
            case "(": parentheses += 1
            case ")": parentheses -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            case "{": braces += 1
            case "}": braces -= 1
            case "," where angle == 0 && parentheses == 0 && brackets == 0 && braces == 0:
                result.append(String(text[start..<index]))
                start = text.index(after: index)
            default: break
            }
            previous = character
        }
        result.append(String(text[start...]))
        return result
    }
}
