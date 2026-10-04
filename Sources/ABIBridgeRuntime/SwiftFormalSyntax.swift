import Foundation

package enum SwiftFormalSyntax {
    package static func isResultArrow(in text: String, at dash: String.Index) -> Bool {
        let end = text.index(after: dash)
        guard text[dash] == "-", end < text.endIndex, text[end] == ">" else { return false }
        if dash > text.startIndex, SwiftGenericSyntax.isOperatorHead(text[text.index(before: dash)])
        {
            return false
        }
        let next = text.index(after: end)
        return next == text.endIndex || !SwiftGenericSyntax.isOperatorHead(text[next])
    }

    package static func fields(_ text: Substring) -> [String] {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : SwiftGenericSyntax.split(text)
    }

    package static func parameterOpening(in text: String) -> String.Index? {
        var generics = 0
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character == "<", SwiftGenericSyntax.opensGeneric(in: text, at: index) {
                generics += 1
            } else if character == ">", previous != "-", generics > 0 {
                generics -= 1
            } else if character == "(", generics == 0 {
                if let closing = matchingClose(in: text, opening: index),
                    text[text.index(after: closing)...].first.map({ $0 == "." || $0 == "<" })
                        == true
                {
                    continue
                }
                return index
            }
            previous = character
        }
        return nil
    }

    package static func matchingClose(in text: String, opening: String.Index) -> String.Index? {
        var depth = 0
        for index in text[opening...].indices {
            if text[index] == "(" {
                depth += 1
            } else if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    package static func topLevelArrow(in text: String) -> Range<String.Index>? {
        var parentheses = 0, generics = 0, brackets = 0
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character == "(", generics == 0 {
                parentheses += 1
            } else if character == ")", generics == 0 {
                parentheses -= 1
            } else if character == "[" {
                brackets += 1
            } else if character == "]" {
                brackets -= 1
            } else if character == "<", SwiftGenericSyntax.opensGeneric(in: text, at: index) {
                generics += 1
            } else if character == ">", previous == "-", parentheses == 0, generics == 0,
                brackets == 0,
                isResultArrow(in: text, at: text.index(before: index))
            {
                return text.index(before: index)..<text.index(after: index)
            } else if character == ">", previous != "-", generics > 0 {
                generics -= 1
            }
            previous = character
        }
        return nil
    }

    package static func topLevelColon(in text: String) -> String.Index? {
        var depth = 0
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if "(<[{".contains(character) {
                depth += 1
            } else if ")]}".contains(character) || (character == ">" && previous != "-") {
                depth -= 1
            } else if character == ":", depth == 0 {
                return index
            }
            previous = character
        }
        return nil
    }

}
