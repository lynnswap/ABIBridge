import Foundation

package enum SwiftMemberLookup {
    /// The owner that qualifies a declaration, such as a type or a protocol.
    package static func owner(of declaration: String) -> String? {
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

    /// The member that a qualified declaration names after its owner, with
    /// its generic parameters and signature, read from the declaration without
    /// an extension's module or `static`. Nil when no owner qualifies it.
    package static func member(of declaration: String) -> String? {
        var text = SymbolIndex.extensionMemberName(declaration) ?? declaration
        if text.hasPrefix("static ") { text = String(text.dropFirst(7)) }
        guard owner(of: text) != nil else { return nil }
        let accessor = [".getter : ", ".setter : "].compactMap { text.range(of: $0)?.lowerBound }
            .first
        let opening = accessor ?? SwiftFormalSyntax.parameterOpening(in: text) ?? text.endIndex
        // The owner ends at the last dot outside generic clauses, or, as in
        // `owner(of:)`, before an operator, whose name can contain dots.
        let groups = SwiftGenericSyntax.groups(in: text).map(\.range)
        var separator: String.Index?
        var operation: String.Index?
        var index = text.startIndex
        while index < opening {
            if let group = groups.first(where: { $0.lowerBound == index }) {
                index = group.upperBound
                continue
            }
            let character = text[index]
            // A fixity, such as ` infix`, follows an operator's name.
            if character.isWhitespace, operation != nil { break }
            operation = SwiftGenericSyntax.isOperatorHead(character) ? operation ?? index : nil
            if character == "." { separator = index }
            index = text.index(after: index)
        }
        return (operation ?? separator).map { String(text[text.index(after: $0)...]) }
    }

    /// Whether a declaration spells everything that selects it: a function
    /// type, an accessor's value type, or a destructor, which has no parameters.
    package static func hasSignature(_ declaration: String) -> Bool {
        SwiftFormalSyntax.topLevelArrow(in: declaration) != nil || isAccessor(declaration)
            || isDestructor(declaration)
    }

    static func isDestructor(_ declaration: String) -> Bool {
        let name = SymbolIndex.extensionMemberName(declaration) ?? declaration
        return !name.contains("(")
            && (name == "deinit" || name.hasSuffix(".deinit")
                || name.hasSuffix(".__deallocating_deinit") || name == "__deallocating_deinit")
    }

    package static func isAccessor(_ declaration: String) -> Bool {
        declaration.contains(".getter : ") || declaration.contains(".setter : ")
    }

    /// The key of what a complete declaration spells after its name: its
    /// parameters, effects, and result, or its accessor and value type. Nil
    /// when it spells neither, as a destructor does.
    ///
    /// The key leaves out the name and the context's requirements, which
    /// lookup and binding check.
    package static func signatureKey(_ declaration: String) -> [UInt8]? {
        let opening =
            [".getter : ", ".setter : "].compactMap { declaration.range(of: $0)?.lowerBound }.first
            ?? SwiftFormalSyntax.parameterOpening(in: declaration)
        guard let opening else { return nil }
        return DeclarationKey.make(String(declaration[opening...]), language: .swift)
    }

    package static func belongs(_ declaration: String, to owner: String) -> Bool {
        Self.owner(of: declaration).map(ownerKey) == ownerKey(owner)
    }

    /// The lookup key of a member's owner: a type, a protocol, or a module,
    /// named as the demangler spells it.
    ///
    /// The key leaves out the generic clauses and the extension contexts
    /// that the spelling can lead with, such as the `(extension in M):` of a
    /// type nested in an extension, which a member's name leaves out of its
    /// owner.
    static func ownerKey(_ owner: String) -> [UInt8] {
        var name = removingGenerics(owner)
        while let declared = SymbolIndex.extensionMemberName(name) { name = declared }
        return DeclarationKey.make(name)
    }

    /// The text of `source` without its generic parameter clauses.
    static func removingGenerics(_ source: String) -> String {
        var result = source
        for group in SwiftGenericSyntax.groups(in: source).reversed() {
            result.removeSubrange(group.range)
        }
        return result
    }

    /// The lookup key of a member named relative to its owner: its base name
    /// and argument labels.
    ///
    /// - Parameter member: A relative name, such as `start()`, `init(text:)`,
    ///   `text`, or `subscript`, or a complete relative declaration, such as
    ///   `text.getter : Swift.String` or `scale(for: CoreGraphics.CGSize) ->
    ///   CoreGraphics.CGFloat`. An accessor's key is its property's or
    ///   subscript's; the accessor itself is the record's to state.
    static func memberKey(_ member: String) -> [UInt8]? {
        let text = member.hasPrefix("static ") ? String(member.dropFirst(7)) : member
        for accessor in [".getter : ", ".setter : "] {
            if let offset = SymbolIndex.byteOffset(of: accessor, in: text) {
                return DeclarationKey.make(
                    removingGenerics(String(decoding: text.utf8.prefix(offset), as: UTF8.self))
                )
            }
        }
        if isDestructor(text) { return DeclarationKey.make(removingGenerics(text)) }
        guard let opening = SwiftFormalSyntax.parameterOpening(in: text) else {
            // A property or subscript named without its type.
            guard !text.contains(":"), !text.isEmpty else { return nil }
            return DeclarationKey.make(removingGenerics(text))
        }
        guard let closing = SwiftFormalSyntax.matchingClose(in: text, opening: opening)
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
        var base = removingGenerics(String(text[..<opening]))
        // The demangler spells a class's allocating initializer this way;
        // records state which initializer entry a symbol is.
        if base == "__allocating_init" { base = "init" }
        return DeclarationKey.make(base + "(" + labels.map { $0 + ":" }.joined() + ")")
    }
}

/// What a Swift member's name states about it: its owner, its base name, and
/// its argument labels, as lookup keys.
///
/// The path leaves out what a declaration's records state: whether the
/// member is an accessor, a static member, or an allocating initializer.
/// ``SwiftMemberMatch`` compares those with the records.
package struct SwiftMemberPath: Hashable, Sendable {
    package let owner: [UInt8]
    package let member: [UInt8]

    /// - Parameters:
    ///   - owner: The declaration name of the member's owner: a type, a
    ///     protocol, or a module.
    ///   - member: The member relative to its owner, as
    ///     `SwiftMemberLookup.memberKey(_:)` reads it.
    package init?(owner: String, member: String) {
        guard let key = SwiftMemberLookup.memberKey(member) else { return nil }
        self.init(ownerKey: SwiftMemberLookup.ownerKey(owner), memberKey: key)
    }

    private init(ownerKey: [UInt8], memberKey: [UInt8]) {
        owner = ownerKey
        member = memberKey
    }

    /// The path of a declaration, such as a demangled symbol name or a
    /// complete or qualified name a caller spells.
    ///
    /// A declaration that no owner qualifies, such as a local function,
    /// whose name ends with its context after ` in `, has a path without an
    /// owner.
    package init?(declaration: String) {
        var text = SymbolIndex.extensionMemberName(declaration) ?? declaration
        if text.hasPrefix("static ") { text = String(text.dropFirst(7)) }
        guard let owner = SwiftMemberLookup.owner(of: text),
            let member = SwiftMemberLookup.member(of: text)
        else {
            guard let key = SwiftMemberLookup.memberKey(text) else { return nil }
            self.init(ownerKey: [], memberKey: key)
            return
        }
        self.init(owner: owner, member: member)
    }
}

/// The Swift member that a lookup selects: its path, and what its records
/// must state.
package struct SwiftMemberMatch: Hashable, Sendable {
    /// Which initializer entries the lookup accepts.
    package enum Initializer: Hashable, Sendable {
        /// Only an allocating initializer, which constructs an instance.
        case allocating
        /// Anything but an allocating initializer.
        case excluded
        /// Whether the entry is a class's allocating initializer, which a
        /// demangled name spells `__allocating_init`; it spells any other
        /// initializer `init`.
        case classAllocator(Bool)
    }

    /// What a lookup selects of a member.
    package enum Entry: Hashable, Sendable {
        /// Its code: an implementation, a dispatch thunk, or a witness.
        case code
        /// A property's or subscript's descriptor, which key paths use.
        case propertyDescriptor
    }

    package let path: SwiftMemberPath
    package let accessor: RuntimeSwiftDeclaration.Accessor?
    package let isStatic: Bool
    package let initializer: Initializer
    package let entry: Entry

    package init(
        path: SwiftMemberPath,
        accessor: RuntimeSwiftDeclaration.Accessor?,
        isStatic: Bool,
        initializer: Initializer,
        entry: Entry = .code
    ) {
        self.path = path
        self.accessor = accessor
        self.isStatic = isStatic
        self.initializer = initializer
        self.entry = entry
    }

    /// The member that a complete or qualified declaration spells,
    /// including its accessor, static-ness, and whether it is a class's
    /// allocating initializer, as a demangled name spells them.
    package init?(declaration: String) {
        let text = SymbolIndex.extensionMemberName(declaration) ?? declaration
        guard let path = SwiftMemberPath(declaration: text) else { return nil }
        let member = SwiftMemberLookup.member(of: text) ?? text
        accessor =
            SymbolIndex.byteOffset(of: ".getter : ", in: text) != nil
            ? .getter : SymbolIndex.byteOffset(of: ".setter : ", in: text) != nil ? .setter : nil
        isStatic = text.hasPrefix("static ")
        initializer = .classAllocator(
            member.hasPrefix("__allocating_init(") || member.hasPrefix("__allocating_init<")
        )
        entry = .code
        self.path = path
    }

    /// Whether a symbol with `record` declares this member.
    package func accepts(_ record: RuntimeSwiftDeclaration) -> Bool {
        guard (record.role == .propertyDescriptor) == (entry == .propertyDescriptor),
            record.accessor == accessor, record.isStatic == isStatic
        else { return false }
        switch initializer {
        case .allocating: return record.kind == .allocator
        case .excluded: return record.kind != .allocator
        case .classAllocator(let allocates):
            return (record.kind == .allocator && record.isClassMember) == allocates
        }
    }
}
