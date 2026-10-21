import Foundation

package enum SwiftGenericSyntax {
    package struct Group {
        package let range: Range<String.Index>
        package let contents: Substring
    }

    package static func groups(in text: String) -> [Group] {
        var result: [Group] = []
        var depth = 0
        var opening: String.Index?
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character == "<", opensGeneric(in: text, at: index) {
                if depth == 0 { opening = index }
                depth += 1
            } else if character == ">", previous != "-", depth > 0 {
                depth -= 1
                if depth == 0, let start = opening {
                    result.append(
                        Group(
                            range: start..<text.index(after: index),
                            contents: text[text.index(after: start)..<index]
                        )
                    )
                }
            }
            previous = character
        }
        return result
    }

    package static func opensGeneric(in text: String, at index: String.Index) -> Bool {
        let remainder = text[text.index(after: index)...]
        guard let next = remainder.first, !isOperatorHead(next) else { return false }
        if next == "(" {
            guard index > text.startIndex else { return false }
            return !isOperatorHead(text[text.index(before: index)])
        }
        if next.isWhitespace {
            let word = remainder.drop(while: \.isWhitespace).prefix(while: \.isLetter)
            return !["infix", "prefix", "postfix"].contains(String(word))
        }
        return true
    }

    // Swift 6.3's operator-head scalar ranges: include/swift/AST/Identifier.h.
    package static func isOperatorHead(_ character: Character) -> Bool {
        let scalar = character.unicodeScalars.first!.value
        if scalar < 0x80 { return "/=-+*%<>!&|^~.?".unicodeScalars.contains { $0.value == scalar } }
        switch scalar {
        case 0xA1...0xA7, 0xA9, 0xAB, 0xAC, 0xAE, 0xB0, 0xB1, 0xB6, 0xBB,
            0xBF, 0xD7, 0xF7, 0x2016, 0x2017, 0x2020...0x2027, 0x2030...0x203E,
            0x2041...0x2053, 0x2055...0x205E, 0x2190...0x23FF, 0x2500...0x2775,
            0x2794...0x2BFF, 0x2E00...0x2E7F, 0x3001...0x3003, 0x3008...0x3030:
            return true
        default: return false
        }
    }

    package static func split(_ text: Substring) -> [String] {
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
