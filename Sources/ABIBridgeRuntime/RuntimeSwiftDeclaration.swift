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
    }

    package enum Accessor: Hashable, Sendable { case getter, setter }

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
    package let accessor: Accessor?
    package let isStatic: Bool
    package let context: Context
    /// The mangled name of the declaration itself. A declaration's code and
    /// its dispatch thunk share this identity.
    package let identity: String

    /// Returns nil for names that are not Swift declarations, such as
    /// metadata, descriptors, and witnesses.
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
        } else {
            role = .implementation
            identity = name
        }
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
        guard ["Function", "Allocator", "Constructor", "Variable", "Subscript"].contains(node.kind),
            let owner = node.child(0)
        else { return nil }
        self.isStatic = isStatic
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
