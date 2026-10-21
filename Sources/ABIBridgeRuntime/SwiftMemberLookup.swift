import Foundation

package enum SwiftMemberLookup {
    private static func owner(of declaration: String) -> String? {
        var text = SymbolIndex.extensionMemberName(declaration) ?? declaration
        text = SymbolIndex.operatorAlias(text) ?? text
        if text.hasPrefix("static ") { text = String(text.dropFirst(7)) }
        let accessor = [".getter : ", ".setter : "].compactMap { text.range(of: $0)?.lowerBound }
            .first
        let opening = accessor ?? SwiftFormalSyntax.parameterOpening(in: text) ?? text.endIndex
        var head = String(text[..<opening])
        for group in SwiftGenericSyntax.groups(in: head).reversed() {
            head.removeSubrange(group.range)
        }
        let operation = head.reversed().prefix(while: SwiftGenericSyntax.isOperatorHead)
        if !operation.isEmpty {
            let owner = head.dropLast(operation.count)
            return owner.isEmpty ? nil : String(owner)
        }
        return head.lastIndex(of: ".").map { String(head[..<$0]) }
    }

    package static func isQualified(_ declaration: String) -> Bool { owner(of: declaration) != nil }

    /// Whether a declaration spells everything that selects it: a function
    /// type, an accessor's value type, or a destructor, which has no parameters.
    package static func hasSignature(_ declaration: String) -> Bool {
        SwiftFormalSyntax.topLevelArrow(in: declaration) != nil || isAccessor(declaration)
            || isDestructor(declaration)
    }

    static func isDestructor(_ declaration: String) -> Bool {
        let name = SymbolIndex.extensionMemberName(declaration) ?? declaration
        return !name.contains("(") && (name == "deinit" || name.hasSuffix(".deinit")
            || name.hasSuffix(".__deallocating_deinit") || name == "__deallocating_deinit")
    }

    package static func isAccessor(_ declaration: String) -> Bool {
        declaration.contains(".getter : ") || declaration.contains(".setter : ")
    }

    /// Compare an explicitly supplied function/property signature independently of the context requirements, which the generic binding validates.
    package static func signatureKey(_ declaration: String) -> [UInt8]? {
        let text = SymbolIndex.extensionMemberName(declaration) ?? declaration
        let opening =
            [".getter : ", ".setter : "].compactMap { text.range(of: $0)?.lowerBound }.first
            ?? SwiftFormalSyntax.parameterOpening(in: text)
        guard let opening else { return nil }
        var head = String(text[..<opening])
        for group in SwiftGenericSyntax.groups(in: head).reversed() {
            head.removeSubrange(group.range)
        }
        return DeclarationKey.make(head + text[opening...], language: .swift)
    }

    package static func belongs(_ declaration: String, to owner: String) -> Bool {
        var nominal = owner
        for group in SwiftGenericSyntax.groups(in: nominal).reversed() {
            nominal.removeSubrange(group.range)
        }
        return Self.owner(of: declaration) == nominal
    }

    package static func key(_ declaration: String) -> [UInt8]? {
        let text = SymbolIndex.extensionMemberName(declaration) ?? declaration
        func head(_ source: String) -> String {
            var result = source
            for group in SwiftGenericSyntax.groups(in: source).reversed() {
                result.removeSubrange(group.range)
            }
            return result
        }
        for accessor in [".getter : ", ".setter : "] {
            if let offset = SymbolIndex.byteOffset(of: accessor, in: text) {
                return DeclarationKey.make(
                    head(String(decoding: text.utf8.prefix(offset), as: UTF8.self))
                        + accessor.components(separatedBy: " : ")[0]
                )
            }
        }
        if isDestructor(text) { return DeclarationKey.make(head(text)) }
        guard let opening = SwiftFormalSyntax.parameterOpening(in: text),
            let closing = SwiftFormalSyntax.matchingClose(in: text, opening: opening)
        else { return nil }
        let fields = text[text.index(after: opening)..<closing]
        let labels: [String]
        let possibleLabels = fields.split(separator: ":")
        if fields.last == ":",
            possibleLabels.allSatisfy({ field in
                !field.isEmpty && field.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            })
        {
            labels = possibleLabels.map(String.init)
        } else {
            labels = SwiftFormalSyntax.fields(fields).map { field in
                SwiftFormalSyntax.topLevelColon(in: field).map {
                    field[..<$0].trimmingCharacters(in: .whitespaces)
                } ?? "_"
            }
        }
        return DeclarationKey.make(
            head(String(text[..<opening])) + "(" + labels.map { $0 + ":" }.joined() + ")"
        )
    }
}
