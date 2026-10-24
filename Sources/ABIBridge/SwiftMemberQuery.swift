import ABIBridgeRuntime
import Foundation

/// A member request read once from its name: the owner and member the name
/// spells, and what lookup matches against declaration records.
///
/// The request's role and static-ness decide which records a member's
/// symbols must have. The name contributes only the owner, base name, and
/// argument labels, and, for a complete declaration, the spelling that
/// selects one overload.
struct SwiftMemberQuery {
    let request: SwiftMemberRequest
    /// The owner that the name spells: a protocol, the type itself, or the
    /// type an extension extends. Nil for a name relative to the type.
    let qualifier: String?
    /// The member relative to its owner, as the name spells it.
    let member: String
    /// The module of the extension that the name spells.
    let extensionModule: String?
    /// Whether the name spells a complete declaration, which selects the
    /// candidates it spells.
    let isComplete: Bool

    init(_ request: SwiftMemberRequest) throws {
        self.request = request
        let name = request.name
        let spellsStatic = name.hasPrefix("static ")
        guard request.isStatic || !spellsStatic else {
            throw ABIResolutionError.unsupportedDeclaration(
                "A static declaration requires a static member request."
            )
        }
        // The role states which accessor, if any, the request resolves.
        if SwiftMemberLookup.isAccessor(name) {
            let getter = name.contains(".getter : ")
            guard request.role == (getter ? .getter : .setter) else {
                let accessor = getter ? "getter" : "setter"
                throw ABIResolutionError.unsupportedDeclaration(
                    "\(name) names a \(accessor); resolve it with a \(accessor) request."
                )
            }
        }
        qualifier = SwiftMemberLookup.owner(of: name)
        member =
            SwiftMemberLookup.member(of: name)
            ?? (spellsStatic ? String(name.dropFirst(7)) : name)
        extensionModule = Self.extensionModule(of: name)
        // An accessor's name is complete when it spells the accessor and its
        // value type; a property can be named like a destructor.
        isComplete =
            request.role == .getter || request.role == .setter
            ? SwiftMemberLookup.isAccessor(name) : SwiftMemberLookup.hasSignature(name)
        if request.role == .initializer {
            guard member.hasPrefix("init(") || member.hasPrefix("init<") else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "An initializer name must start with init( or init<, after a protocol that qualifies it."
                )
            }
        }
    }

    var role: SwiftMemberRequest.Role { request.role }
    var isStatic: Bool { request.isStatic }

    var accessor: RuntimeSwiftDeclaration.Accessor? {
        switch request.role {
        case .getter: .getter
        case .setter: .setter
        case .method, .initializer: nil
        }
    }

    /// Whether the member is a subscript, whose getter takes its indices.
    var namesSubscript: Bool {
        guard member.hasPrefix("subscript") else { return false }
        let rest = member.dropFirst("subscript".count)
        return rest.isEmpty || rest.first == "." || rest.first == "(" || rest.first == "<"
    }

    /// The owner whose members lookup searches when the type `owner` is the
    /// lookup type: the owner the name spells, or else that type.
    func owner(in owner: String) -> String { qualifier ?? owner }

    /// What the symbols of the member of `owner` must state.
    func match(in owner: String) throws -> SwiftMemberMatch {
        guard let path = SwiftMemberPath(owner: self.owner(in: owner), member: member) else {
            throw ABIResolutionError.unsupportedDeclaration(
                "The member name \(request.name) does not name a Swift member."
            )
        }
        return SwiftMemberMatch(
            path: path,
            accessor: accessor,
            isStatic: isStatic,
            initializer: role == .initializer ? .allocating : .excluded
        )
    }

    /// Whether `candidate` is the declaration that a complete name spells.
    ///
    /// A name qualified by its owner is compared in full. Lookup selected a
    /// relative name's candidates by their owner, base name, and labels, so
    /// only the rest of its spelling is compared, and binding checks the
    /// requirements of the candidate's context. Records decide static-ness
    /// and which initializer entry a symbol is, so neither spelling's
    /// `static` or `__allocating_init` takes part.
    func spells(_ candidate: SwiftCandidate, ignoringOwner: Bool = false) -> Bool {
        let names = [candidate.declaration.name, candidate.memberName]
        let spellings = names + names.compactMap(SymbolIndex.operatorAlias)
        guard qualifier == nil || ignoringOwner else {
            let key = DeclarationKey.make(Self.withoutStatic(request.name), language: .swift)
            return spellings.contains {
                DeclarationKey.make(Self.withoutStatic($0), language: .swift) == key
            }
        }
        return spellings.contains { spellsMember($0) }
    }

    /// Whether a declaration spells this member's signature independently of
    /// its owner, as a requirement inherited from another protocol does.
    func spellsMember(_ declaration: String) -> Bool {
        // A destructor spells nothing after its name.
        guard let key = SwiftMemberLookup.signatureKey(member) else { return true }
        return SwiftMemberLookup.member(of: declaration).flatMap(SwiftMemberLookup.signatureKey)
            == key
    }

    /// Whether `record` declares the member in the extension that the name
    /// spells, when it spells one.
    func isDeclared(by record: RuntimeSwiftDeclaration) -> Bool {
        guard let extensionModule else { return true }
        switch record.context {
        case .extension(let module, _), .protocolExtension(let module):
            return module == extensionModule
        case .nominal, .protocolRequirement:
            return false
        }
    }

    /// The member's spelling in diagnostics, with `owner` as its owner when
    /// the name is relative. Lookup never reads it.
    func display(in owner: String) -> NativeDeclaration {
        guard qualifier == nil else {
            return NativeDeclaration(name: request.name, language: .swift)
        }
        var spelling = (isStatic ? "static " : "") + owner + "." + member
        if let accessor, !SwiftMemberLookup.isAccessor(member) {
            spelling += accessor == .getter ? ".getter" : ".setter"
        }
        return NativeDeclaration(name: spelling, language: .swift)
    }

    private static func withoutStatic(_ name: String) -> String {
        name.hasPrefix("static ") ? String(name.dropFirst(7)) : name
    }

    /// The module of the `(extension in Module):` context that a name spells.
    private static func extensionModule(of name: String) -> String? {
        let declaration = withoutStatic(name)
        let marker = "(extension in "
        guard declaration.hasPrefix(marker), let end = declaration.range(of: "):") else {
            return nil
        }
        let start = declaration.index(declaration.startIndex, offsetBy: marker.count)
        return String(declaration[start..<end.lowerBound])
    }
}
