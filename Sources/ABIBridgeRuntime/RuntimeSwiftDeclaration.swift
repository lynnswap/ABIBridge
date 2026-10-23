import ABIBridgeCore

/// What a Swift symbol declares, read from the structure of its mangled name.
///
/// Member selection compares these records instead of demangled spellings, so
/// a dispatch thunk, an extension member, and a protocol requirement are told
/// apart without matching text such as `dispatch thunk of`.
package struct RuntimeSwiftDeclaration: Hashable, Sendable {
    package enum Role: Hashable, Sendable {
        /// The declaration's own code.
        case implementation
        /// A thunk that dispatches the declaration through its owner's table.
        case dispatchThunk
        /// A conformance's witness of a protocol requirement: a thunk that
        /// runs the conformance's implementation with the requirement's
        /// calling convention. `conformanceDescriptor` is the mangled name of
        /// the descriptor of the conformance it serves.
        case witness(conformanceDescriptor: String)
    }

    package enum Accessor: Hashable, Sendable { case getter, setter }

    /// The kind of declaration, which says how calls reach it.
    package enum Kind: String, Hashable, Sendable {
        case function = "Function"
        /// An allocating initializer, which calls allocate the instance.
        case allocator = "Allocator"
        /// An initializing initializer of an allocated class instance.
        case constructor = "Constructor"
        case destructor = "Destructor"
        case deallocator = "Deallocator"
        case variable = "Variable"
        case `subscript` = "Subscript"
    }

    package enum Context: Hashable, Sendable {
        /// Declared in its nominal type, or at module scope.
        case nominal
        /// Declared in an extension of a nominal type in `module`.
        case `extension`(module: String, constrained: Bool)
        /// A protocol requirement.
        case protocolRequirement
        /// Declared in an extension of a protocol in `module`.
        case protocolExtension(module: String)

        package var isExtension: Bool {
            switch self {
            case .extension, .protocolExtension: true
            case .nominal, .protocolRequirement: false
            }
        }
    }

    package let role: Role
    package let kind: Kind
    package let accessor: Accessor?
    /// Whether a call can run the symbol's own code: a declaration's code, a
    /// protocol requirement's thunk, which selects the conformance's witness,
    /// or a conformance's witness, which applies to that conformance only. A
    /// class member's thunk instead redispatches on the receiver.
    package var runsOwnCode: Bool {
        switch role {
        case .implementation, .witness: true
        case .dispatchThunk: context == .protocolRequirement
        }
    }
    package let isStatic: Bool
    package let context: Context
    /// The mangled name of the declaration itself. A declaration's code and
    /// its dispatch thunk share this identity; a witness is its own.
    package let identity: String
    /// For a protocol requirement's dispatch thunk, witness, or own symbol,
    /// the requirement's mangled name, which the remangler produces from the
    /// symbol's tree so that every record of one requirement spells it alike.
    package let requirement: String?

    /// Returns nil for names that are not Swift declarations, such as
    /// metadata and descriptors.
    package init?(linkageName: String) {
        let name = linkageName.hasPrefix("_") ? String(linkageName.dropFirst()) : linkageName
        guard
            let syntax = name.utf8CString.withUnsafeBufferPointer({
                ABICopySwiftSymbolSyntax($0.baseAddress, $0.count - 1)
            })
        else { return nil }
        defer { ABIReleaseSwiftSyntax(syntax) }
        guard var node = ABISwiftSyntaxRoot(syntax).map(Node.init) else { return nil }
        if node.kind == "Global", let child = node.child(0) { node = child }
        var isStatic = false
        if node.kind == "Static", let child = node.child(0) {
            isStatic = true
            node = child
        }
        if node.kind == "DispatchThunk", let child = node.child(0) {
            role = .dispatchThunk
            identity = name.hasSuffix("Tj") ? String(name.dropLast(2)) : name
            node = child
        } else if node.kind == "ProtocolWitness", let conformance = node.child(0),
            let entity = node.child(1),
            let descriptor = Self.copy(
                ABICopySwiftConformanceDescriptorSymbolName(conformance.pointer)
            )
        {
            role = .witness(conformanceDescriptor: descriptor)
            identity = name
            node = entity
        } else {
            role = .implementation
            identity = name
        }
        // The declaration, with its static and accessor wrappers.
        let entity = node
        if node.kind == "Static", let child = node.child(0) {
            isStatic = true
            node = child
        }
        switch node.kind {
        case "Getter", "Setter":
            accessor = node.kind == "Getter" ? .getter : .setter
            guard let child = node.child(0) else { return nil }
            node = child
        default:
            accessor = nil
        }
        guard let kind = Kind(rawValue: node.kind), let owner = node.child(0) else { return nil }
        // A witness serves a requirement, which a protocol declares.
        if case .witness = role, owner.kind != "Protocol" { return nil }
        self.kind = kind
        self.isStatic = isStatic
        requirement =
            owner.kind == "Protocol" ? Self.copy(ABICopySwiftEntitySymbolName(entity.pointer)) : nil
        switch owner.kind {
        case "Protocol":
            context = .protocolRequirement
        case "Extension":
            guard let module = owner.child(0).flatMap({ $0.kind == "Module" ? $0.text : nil }),
                let extended = owner.child(1)
            else { return nil }
            context =
                extended.kind == "Protocol"
                ? .protocolExtension(module: module)
                : .extension(
                    module: module,
                    constrained: owner.children.contains { $0.kind == "DependentGenericSignature" }
                )
        default:
            context = .nominal
        }
    }

    /// The mangled name of the dispatch thunk of this declaration's own code,
    /// through which other images call a class member, as the remangler
    /// produces it. Nil for a thunk, a witness, or an extension member,
    /// which have none.
    package var dispatchThunk: String? {
        guard role == .implementation, context == .nominal else { return nil }
        return Self.child(of: "Global", in: identity, unwrapping: false) {
            Self.copy(ABICopySwiftDispatchThunkSymbolName($0.pointer))
        }
    }

    /// The mangled name of the requirement that a method descriptor symbol
    /// describes, which the remangler produces from the symbol's tree.
    package static func methodDescriptorRequirement(linkageName: String) -> String? {
        child(of: "MethodDescriptor", in: linkageName) {
            copy(ABICopySwiftEntitySymbolName($0.pointer))
        }
    }

    /// The mangled name of a protocol conformance descriptor symbol, as the
    /// remangler produces it from the symbol's tree.
    package static func conformanceDescriptor(linkageName: String) -> String? {
        child(of: "ProtocolConformanceDescriptor", in: linkageName) {
            copy(ABICopySwiftConformanceDescriptorSymbolName($0.pointer))
        }
    }

    /// Applies `body` to the only child of a symbol's top-level `kind` node.
    ///
    /// - Parameter unwrapping: Whether `kind` names the node under the
    ///   symbol's `Global` root rather than the root itself.
    private static func child(
        of kind: String,
        in linkageName: String,
        unwrapping: Bool = true,
        _ body: (Node) -> String?
    ) -> String? {
        let name = linkageName.hasPrefix("_") ? String(linkageName.dropFirst()) : linkageName
        guard
            let syntax = name.utf8CString.withUnsafeBufferPointer({
                ABICopySwiftSymbolSyntax($0.baseAddress, $0.count - 1)
            })
        else { return nil }
        defer { ABIReleaseSwiftSyntax(syntax) }
        guard var node = ABISwiftSyntaxRoot(syntax).map(Node.init) else { return nil }
        if unwrapping, node.kind == "Global", let child = node.child(0) { node = child }
        guard node.kind == kind, let child = node.child(0) else { return nil }
        return body(child)
    }

    private static func copy(_ name: UnsafeMutablePointer<CChar>?) -> String? {
        guard let name else { return nil }
        defer { ABIFreeString(name) }
        return String(cString: name)
    }

    private struct Node {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        var kind: String { String(cString: ABISwiftSyntaxNodeKind(pointer)) }
        var children: [Node] {
            (0..<ABISwiftSyntaxNodeChildCount(pointer)).compactMap(child)
        }
        func child(_ index: Int) -> Node? {
            guard index < ABISwiftSyntaxNodeChildCount(pointer) else { return nil }
            return ABISwiftSyntaxNodeChild(pointer, index).map(Node.init)
        }
        var text: String? {
            var length = 0
            guard let text = ABISwiftSyntaxNodeText(pointer, &length) else { return nil }
            return String(
                decoding: UnsafeRawBufferPointer(start: text, count: length),
                as: UTF8.self
            )
        }
    }
}

/// A Swift symbol found for a member lookup, with what it declares.
package struct RuntimeSwiftCandidate: Sendable {
    /// The symbol itself, named by its own demangled spelling.
    package let symbol: RuntimeSymbol
    package let record: RuntimeSwiftDeclaration
    /// The declaration the symbol defines or dispatches.
    package let declaration: RuntimeDeclaration
    /// The declaration's name without the module of an extension that declares it.
    package let memberName: String
}
