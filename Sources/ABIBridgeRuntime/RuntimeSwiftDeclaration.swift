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
        /// calling convention.
        case witness(Witness)
    }

    /// The requirement and the conformance that a protocol witness serves.
    package struct Witness: Hashable, Sendable {
        /// The mangled name of the protocol requirement.
        package let requirement: String
        /// The mangled name of the conformance's descriptor.
        package let conformanceDescriptor: String
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
            let requirement = Self.copy(ABICopySwiftEntitySymbolName(entity.pointer)),
            let descriptor = Self.copy(
                ABICopySwiftConformanceDescriptorSymbolName(conformance.pointer)
            )
        {
            role = .witness(.init(requirement: requirement, conformanceDescriptor: descriptor))
            identity = name
            node = entity
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
        guard
            [
                "Function", "Allocator", "Constructor", "Destructor", "Deallocator", "Variable",
                "Subscript",
            ].contains(node.kind),
            let owner = node.child(0)
        else { return nil }
        // A witness serves a requirement, which a protocol declares.
        if case .witness = role, owner.kind != "Protocol" { return nil }
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
