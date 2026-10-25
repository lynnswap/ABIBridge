import ABIBridgeCore
import ABIBridgeCore.Backend

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
        /// A property's or subscript's descriptor, which describes its
        /// accessors to key paths and is not code.
        case propertyDescriptor
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
    /// Whether the symbol supplies a definition for its declaration: its own
    /// code, a protocol requirement's dispatch thunk, a conformance's witness,
    /// or a property descriptor. A class member's dispatch thunk instead
    /// redispatches on the receiver and does not supply its implementation.
    package var runsOwnCode: Bool {
        switch role {
        case .implementation, .witness: true
        case .dispatchThunk: context == .protocolRequirement
        // A descriptor is its own definition, which no thunk stands in for.
        case .propertyDescriptor: true
        }
    }
    package let isStatic: Bool
    package let context: Context
    /// The declared type that owns this member, including the contexts that
    /// declare that type. An extension of that type does not change its identity.
    package let ownerIdentity: RuntimeSwiftTypeIdentity?
    /// Whether a class declares the declaration, rather than an extension of
    /// the class or another type.
    package let isClassMember: Bool
    /// For an instance property's or subscript's descriptor, the mangled
    /// name of the getter of the storage it describes. Lookup files the
    /// descriptor under the getter's spelling, with the storage's members.
    package let describedGetter: String?
    /// For a property's descriptor, the property's declared type, as the
    /// remangler mangles it.
    package let declaredType: String?
    /// The mangled name of the declaration itself. A declaration's code and
    /// its dispatch thunk share this identity; a witness is its own.
    package let identity: String
    /// For a protocol requirement's dispatch thunk, witness, or own symbol,
    /// the requirement's mangled name, which the remangler produces from the
    /// symbol's tree so that every record of one requirement spells it alike.
    package let requirement: String?

    /// Returns nil for names that are not Swift declarations or property
    /// descriptors, such as metadata and type descriptors.
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
        } else if node.kind == "PropertyDescriptor", let child = node.child(0) {
            role = .propertyDescriptor
            identity = name
            node = child
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
        ownerIdentity = RuntimeSwiftTypeIdentity(node: owner.pointer)
        isClassMember = owner.kind == "Class"
        if role == .propertyDescriptor {
            describedGetter =
                isStatic ? nil : Self.copy(ABICopySwiftGetterSymbolName(node.pointer))
            declaredType = node.children.first { $0.kind == "Type" }.flatMap {
                Self.copy(ABICopySwiftSyntaxNodeMangledName($0.pointer))
            }
        } else {
            describedGetter = nil
            declaredType = nil
        }
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

    fileprivate struct Node {
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

/// A nominal declaration's identity, as the remangler spells its type tree.
/// Instantiation arguments and an immediate member extension are not part of
/// the declaration; extension contexts within the nominal type's ancestry are.
package struct RuntimeSwiftTypeIdentity: Hashable, Sendable {
    private let mangled: String

    fileprivate init?(node: OpaquePointer) {
        var node = node
        while true {
            let kind = String(cString: ABISwiftSyntaxNodeKind(node))
            let child: Int
            switch kind {
            case "Type", "BoundGenericStructure", "BoundGenericEnum", "BoundGenericClass",
                "BoundGenericTypeAlias", "BoundGenericOtherNominalType":
                child = 0
            case "Extension": child = 1
            default:
                guard
                    ["Structure", "Enum", "Class", "Protocol", "TypeAlias", "OtherNominalType"]
                        .contains(kind),
                    let name = ABICopySwiftSyntaxNodeMangledName(node)
                else { return nil }
                defer { ABIFreeString(name) }
                mangled = String(cString: name)
                return
            }
            guard let next = ABISwiftSyntaxNodeChild(node, child) else { return nil }
            node = next
        }
    }

    package init(
        metadata: Any.Type,
        in image: RuntimeImage,
        resolver: RuntimeSymbolResolver
    ) throws {
        let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        let declared = ABISwiftTypeDescriptor(pointer).flatMap {
            resolver.swiftTypeDeclaration(at: UInt64(UInt(bitPattern: $0)), in: image)
        }
        guard let mangled = declared ?? _mangledTypeName(metadata),
            let syntax = mangled.utf8CString.withUnsafeBufferPointer({
                ABICopySwiftTypeSyntax($0.baseAddress, $0.count - 1)
            })
        else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The member owner's type declaration is unavailable."
            )
        }
        defer { ABIReleaseSwiftSyntax(syntax) }
        guard let root = ABISwiftSyntaxRoot(syntax), let identity = Self(node: root) else {
            throw RuntimeResolutionError.metadataUnavailable(
                "The member owner's type declaration cannot be decoded."
            )
        }
        self = identity
    }
}

/// What a symbol of a property states about it: a property descriptor, an
/// accessor, or a variable initializer, each of which spells the property's
/// declared type. A field record instead holds an opaque property's
/// underlying type.
package struct RuntimeSwiftPropertySymbol: Hashable, Sendable {
    /// The symbol of the nominal type descriptor of the struct, enum, or
    /// class that declares the property, as the remangler spells it from the
    /// property's context.
    package let typeDescriptor: String
    /// The module that declares the property's owning nominal type: the
    /// module of its innermost extension context, otherwise its root module.
    package let module: String
    /// The property's name, without a private discriminator.
    package let name: String
    package let isStatic: Bool
    /// Whether the symbol is the property's descriptor.
    package let isDescriptor: Bool
    /// Whether the declared type the symbol spells contains an opaque type.
    package let declaresOpaqueType: Bool

    // The kinds of symbols whose tree spells a property's declared type.
    private static let kinds: Set<String> = [
        "PropertyDescriptor", "Getter", "Setter", "ModifyAccessor", "Modify2Accessor",
        "ReadAccessor", "Read2Accessor", "Initializer", "InitAccessor",
    ]

    /// Returns nil for other symbols.
    package init?(linkageName: String) {
        let name = linkageName.hasPrefix("_") ? String(linkageName.dropFirst()) : linkageName
        guard
            let syntax = name.utf8CString.withUnsafeBufferPointer({
                ABICopySwiftSymbolSyntax($0.baseAddress, $0.count - 1)
            })
        else { return nil }
        defer { ABIReleaseSwiftSyntax(syntax) }
        guard var symbol = ABISwiftSyntaxRoot(syntax).map(Node.init) else { return nil }
        if symbol.kind == "Global" {
            // A suffix such as a dispatch thunk's wraps the accessor in another node.
            guard symbol.children.count == 1, let child = symbol.child(0) else { return nil }
            symbol = child
        }
        guard Self.kinds.contains(symbol.kind), var variable = symbol.child(0) else { return nil }
        isStatic = variable.kind == "Static"
        if isStatic, let child = variable.child(0) { variable = child }
        guard variable.kind == "Variable", let context = variable.child(0),
            let identifier = variable.child(1),
            let declared = variable.children.first(where: { $0.kind == "Type" }),
            let module = Self.declaringModule(of: context),
            let descriptor = Self.copy(ABICopySwiftNominalTypeDescriptorSymbolName(context.pointer))
        else { return nil }
        switch identifier.kind {
        case "Identifier":
            guard let text = identifier.text else { return nil }
            self.name = text
        case "PrivateDeclName":
            guard let text = identifier.children.last?.text else { return nil }
            self.name = text
        default:
            return nil
        }
        typeDescriptor = descriptor
        self.module = module
        isDescriptor = symbol.kind == "PropertyDescriptor"
        declaresOpaqueType = Self.containsOpaqueType(declared)
    }

    private static func declaringModule(of context: Node) -> String? {
        var node = context
        while true {
            switch node.kind {
            case "Module": return node.text
            case "Extension": return node.child(0).flatMap { $0.kind == "Module" ? $0.text : nil }
            default:
                guard let parent = node.child(0) else { return nil }
                node = parent
            }
        }
    }

    // `some P` spells as an opaque return type (`Qr`), another declaration's
    // opaque type (`Qo`), or one of their parts.
    private static func containsOpaqueType(_ node: Node) -> Bool {
        node.kind.hasPrefix("Opaque") || node.children.contains(where: containsOpaqueType)
    }

    private static func copy(_ name: UnsafeMutablePointer<CChar>?) -> String? {
        guard let name else { return nil }
        defer { ABIFreeString(name) }
        return String(cString: name)
    }

    private typealias Node = RuntimeSwiftDeclaration.Node
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

/// The coarse member keys of a symbol, read without preparing its declaration
/// record or its display name. A lookup validates the owner and declaration
/// against the candidates in the selected bucket.
package struct RuntimeSwiftMemberIndex {
    package let memberKeys: [[UInt8]]
    package let isPropertyDescriptor: Bool
    package let requiresDeclarationSpelling: Bool

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
        var descriptor = false
        while true {
            let child: Int
            switch node.kind {
            case "Static", "DispatchThunk", "Getter", "Setter": child = 0
            case "PropertyDescriptor":
                descriptor = true
                child = 0
            case "ProtocolWitness": child = 1
            default:
                guard let member = Self.memberIndex(of: node) else { return nil }
                memberKeys = member.keys
                requiresDeclarationSpelling = member.requiresSpelling
                isPropertyDescriptor = descriptor
                return
            }
            guard let next = node.child(child) else { return nil }
            node = next
        }
    }

    private static func memberIndex(of node: Node) -> (keys: [[UInt8]], requiresSpelling: Bool)? {
        switch node.kind {
        case "Variable":
            guard let identifier = node.child(1).flatMap(declarationName) else { return nil }
            return ([DeclarationKey.make(identifier)], false)
        case "Subscript": return ([DeclarationKey.make("subscript")], false)
        case "Destructor": return ([DeclarationKey.make("deinit")], false)
        case "Deallocator":
            return (
                [
                    DeclarationKey.make(
                        node.child(0)?.kind == "Class" ? "__deallocating_deinit" : "deinit"
                    )
                ], false
            )
        case "Function", "Allocator", "Constructor": break
        default: return nil
        }

        guard let type = functionType(of: node) else { return nil }
        if node.kind == "Function", let name = node.child(1), containsPrivateName(name) {
            return ([], true)
        }
        // These prefixes and private-name discriminators change the source
        // parser's member key. Keep its spelling for only those declarations.
        if hasPrefixAttributes(type) { return ([], true) }

        let names: [String]
        if node.kind == "Allocator", node.child(0)?.kind == "Class" {
            names = ["__allocating_init", "init"]
        } else if node.kind == "Allocator" || node.kind == "Constructor" {
            names = ["init"]
        } else {
            guard let identifier = node.child(1), let name = declarationName(identifier) else {
                return nil
            }
            switch identifier.kind {
            case "InfixOperator", "PrefixOperator", "PostfixOperator":
                guard let alias = identifier.text else { return nil }
                names = [name, alias]
            default: names = [name]
            }
        }
        guard let labels = argumentLabels(of: node, functionType: type) else { return nil }
        let parameters = "(" + labels.map { $0 + ":" }.joined() + ")"
        return (names.map { DeclarationKey.make($0 + parameters) }, false)
    }

    private static func functionType(of node: Node) -> Node? {
        guard var type = node.children.first(where: { $0.kind == "Type" })?.child(0) else {
            return nil
        }
        while type.kind == "DependentGenericType" {
            guard let function = type.child(1)?.child(0) else { return nil }
            type = function
        }
        return type
    }

    private static func hasPrefixAttributes(_ type: Node) -> Bool {
        guard ["FunctionType", "NoEscapeFunctionType", "UncurriedFunctionType"].contains(type.kind)
        else { return true }
        return type.children.contains {
            ![
                "ArgumentTuple", "ReturnType", "ThrowsAnnotation", "TypedThrowsAnnotation",
                "AsyncAnnotation", "SendingResultFunctionType",
            ].contains($0.kind)
        }
    }

    private static func containsPrivateName(_ node: Node) -> Bool {
        node.kind == "PrivateDeclName" || node.children.contains(where: containsPrivateName)
    }

    private static func declarationName(_ node: Node) -> String? {
        switch node.kind {
        case "Identifier": return node.text
        case "InfixOperator": return node.text.map { $0 + " infix" }
        case "PrefixOperator": return node.text.map { $0 + " prefix" }
        case "PostfixOperator": return node.text.map { $0 + " postfix" }
        case "PrivateDeclName":
            guard let discriminator = node.child(0)?.text else { return nil }
            if let name = node.child(1).flatMap(declarationName) {
                return "(" + name + " in " + discriminator + ")"
            }
            return "(in " + discriminator + ")"
        case "LocalDeclName":
            guard let name = node.child(1).flatMap(declarationName),
                let index = node.child(0), ABISwiftSyntaxNodeHasIndex(index.pointer)
            else { return nil }
            return name + " #" + String(ABISwiftSyntaxNodeIndex(index.pointer) &+ 1)
        case "RelatedEntityDeclName":
            guard let kind = node.child(0)?.text,
                let name = node.child(1).flatMap(declarationName)
            else { return nil }
            return "related decl '" + kind + "' for " + name
        default: return nil
        }
    }

    private static func argumentLabels(of node: Node, functionType: Node) -> [String]? {
        if let list = node.children.first(where: { $0.kind == "LabelList" }),
            !list.children.isEmpty
        {
            var labels: [String] = []
            for label in list.children {
                switch label.kind {
                case "Identifier":
                    guard let text = label.text else { return nil }
                    labels.append(text)
                case "FirstElementMarker": labels.append("_")
                default: return nil
                }
            }
            return labels
        }
        // An empty label list also represents a function whose parameters are
        // all unlabeled. Its argument tuple supplies their count.
        guard let argument = functionType.children.first(where: { $0.kind == "ArgumentTuple" }),
            let parameters = argument.child(0)?.child(0)
        else { return nil }
        let count = parameters.kind == "Tuple" ? parameters.children.count : 1
        return Array(repeating: "_", count: count)
    }

    private typealias Node = RuntimeSwiftDeclaration.Node
}
