import ABIBridgeCore
import Foundation

extension SwiftGenericDeclaration {
    init(linkageName: String, enclosing context: SwiftGenericTypeContext? = nil,
         declaredSignature: SwiftDeclaredSignature? = nil, caller: SwiftFunctionSignature? = nil) throws {
        let syntax = try SwiftSyntax(symbol: linkageName)
        var entry = syntax.root
        while ["Global", "Static"].contains(entry.kind) {
            entry = try entry.requiredChild()
        }
        var requirements = context?.requirements ?? []
        func collectContext(_ node: SwiftSyntax.Node) throws {
            for child in node.children() {
                if child.kind == "DependentGenericSignature" {
                    requirements += try Self.requirements(child)
                } else if child.kind != "Type" {
                    try collectContext(child)
                }
            }
        }
        let declaration: SwiftSyntax.Node
        let accessor: String?
        if ["Getter", "Setter"].contains(entry.kind) {
            accessor = entry.kind
            declaration = try entry.requiredChild()
        } else {
            accessor = nil
            declaration = entry
        }
        guard ["Function", "Allocator", "Constructor", "Variable", "Subscript"].contains(declaration.kind),
              let type = declaration.child(kind: "Type") else {
            throw ABIResolutionError.unsupportedDeclaration("The Swift symbol does not describe a callable declaration: " + linkageName)
        }
        for child in declaration.children() where child.kind != "Type" { try collectContext(child) }
        var value = try type.requiredChild()
        var parameters = context?.parameters ?? []
        if value.kind == "DependentGenericType" {
            let signature = try value.requiredChild(kind: "DependentGenericSignature")
            requirements += try Self.requirements(signature)
            let firstDepth = (parameters.map { Int($0.name.drop(while: { $0.isLetter })) ?? 0 }.max() ?? -1) + 1
            let packs = try Set(signature.children().filter { $0.kind == "DependentGenericParamPackMarker" }
                .map { try SwiftFormalType($0.requiredChild()).spelling })
            let counts = signature.children().filter { $0.kind == "DependentGenericParamCount" }
            for (offset, count) in counts.enumerated() {
                for index in 0..<Int(count.index!) {
                    let name = SwiftFormalType.parameterName(depth: firstDepth + offset, index: index)
                    parameters.append(.init(name: name, isPack: packs.contains(name)))
                }
            }
            value = try value.requiredChild(kind: "Type").requiredChild()
        }
        self.parameters = parameters
        consumesArguments = accessor == "Setter" || ["Allocator", "Constructor"].contains(declaration.kind)
        self.requirements = requirements.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        if let accessor {
            let property = try SwiftFormalType(value)
            arguments = accessor == "Setter" ? [property] : []
            result = accessor == "Setter" ? .tuple([]) : property
            if accessor == "Getter" {
                if let getterSignature = declaredSignature?.function {
                    guard case .function(let parameters, _, let failure, let isAsync) = getterSignature, parameters.isEmpty else {
                        throw ABIResolutionError.signatureMismatch(.init(expected: "A zero-argument declared getter signature", found: [getterSignature.spelling]))
                    }
                    self.failure = failure
                    self.isAsync = isAsync
                } else {
                    if let caller, caller.failure != Never.self {
                        throw ABIResolutionError.unsupportedDeclaration("A throwing generic getter requires declaredAs: with its source function type; its symbol does not encode the formal error type.")
                    }
                    failure = nil
                    isAsync = caller?.isAsync ?? false
                }
            } else {
                failure = nil
                isAsync = false
            }
        } else {
            guard case .function(let arguments, let result, let failure, let isAsync) = try SwiftFormalType(value) else {
                throw ABIResolutionError.unsupportedDeclaration("The Swift declaration is missing its function type.")
            }
            self.arguments = arguments
            self.result = result
            self.failure = failure
            self.isAsync = isAsync
        }
        implicitRequirements = context?.requirements ?? []
        abiRequirements = try declaredSignature?.requirements(for: self)
        if let abiRequirements {
            self.requirements += abiRequirements.filter { !self.requirements.contains($0) }
        }
    }

    static func requirements(_ signature: SwiftSyntax.Node) throws -> [Requirement] {
        try signature.children().compactMap { node in
            switch node.kind {
            case "DependentGenericConformanceRequirement":
                let children = node.children()
                let subject = try SwiftFormalType(children[0])
                let constraint = try SwiftFormalType(children[1])
                let target = try children[1].requiredChild()
                if ["Class", "BoundGenericClass"].contains(target.kind) { return .superclass(subject, constraint) }
                return .conformance(subject, constraint.spelling)
            case "DependentGenericSameTypeRequirement", "DependentGenericSameShapeRequirement":
                let children = node.children()
                let left = try SwiftFormalType(children[0]), right = try SwiftFormalType(children[1])
                return node.kind == "DependentGenericSameTypeRequirement" ? .sameType(left, right) : .sameShape(left, right)
            case "DependentGenericLayoutRequirement":
                let children = node.children()
                guard children[1].text() == "C" else {
                    throw ABIResolutionError.unsupportedDeclaration("The Swift generic layout requirement is not a class constraint.")
                }
                return .conformance(try SwiftFormalType(children[0]), "Swift.AnyObject")
            case "DependentGenericParamCount", "DependentGenericParamPackMarker",
                 "DependentGenericInverseConformanceRequirement":
                return nil
            default:
                throw ABIResolutionError.unsupportedDeclaration("Cannot decode the Swift " + node.kind + " requirement.")
            }
        }
    }
}

extension SwiftFormalType {
    static func parameterName(depth: Int, index: Int) -> String {
        var position = index, name = ""
        repeat {
            name.append(Character(UnicodeScalar(65 + position % 26)!))
            position /= 26
        } while position != 0
        if depth != 0 { name += String(depth) }
        return name
    }

    init(_ node: SwiftSyntax.Node) throws {
        let children = node.children()
        switch node.kind {
        case "Type", "ArgumentTuple", "ReturnType", "TupleElement", "PackElement", "DynamicSelf":
            self = try Self(node.requiredChild(kind: "Type", fallingBackToFirst: true))
        case "DependentGenericParamType":
            self = .named(Self.parameterName(depth: Int(children[0].index!), index: Int(children[1].index!)), [])
        case "DependentMemberType":
            let base = try Self(children[0])
            let member = try children[1].requiredChild(kind: "Identifier").requiredText()
            let qualifier = try children[1].children().first {
                $0.kind == "Protocol" || $0.kind == "ProtocolSymbolicReference"
            }.map { try Self($0).spelling }
            self = .associated(base, member, protocolName: qualifier)
        case "Structure", "Enum", "Class", "Protocol", "TypeAlias":
            let nameNode = children[1]
            let name = try nameNode.kind == "Identifier" ? nameNode.requiredText() : nameNode.name()
            var context = children[0]
            if context.kind == "Extension" { context = context.children()[1] }
            if context.kind == "Module" {
                self = .nominal(try context.requiredText() + "." + name, [])
            } else {
                self = .nested(try Self(context), name, [])
            }
        case "BoundGenericStructure", "BoundGenericEnum", "BoundGenericClass", "BoundGenericTypeAlias", "BoundGenericOtherNominalType":
            let base = try Self(children[0])
            let arguments = try children[1].children().map(Self.init)
            switch base {
            case .reference(let descriptor, _): self = .reference(descriptor, arguments)
            case .nominal(let name, _): self = .nominal(name, arguments)
            case .nested(let parent, let name, _): self = .nested(parent, name, arguments)
            default: throw ABIResolutionError.unsupportedDeclaration("The bound Swift nominal type has no declaration.")
            }
        case "TypeSymbolicReference":
            self = .reference(try SwiftNominalDescriptor(address: UnsafeRawPointer(bitPattern: UInt(node.index!))!), [])
        case "ProtocolSymbolicReference":
            let descriptor = try SwiftProtocolDescriptor(address: UnsafeRawPointer(bitPattern: UInt(node.index!))!)
            self = .nominal(try descriptor.name(), [])
        case "Tuple":
            self = .tuple(try children.map(Self.init))
        case "PackExpansion":
            self = .pack(try Self(children[0]), shape: try Self(children[1]))
        case "Pack":
            self = .packValue(try children.map(Self.init))
        case "Metatype":
            self = .metatype(try Self(node.requiredChild(kind: "Type", fallingBackToFirst: true)))
        case "ExistentialMetatype":
            self = .existentialMetatype(try Self(node.requiredChild(kind: "Type", fallingBackToFirst: true)))
        case "InOut": self = .inoutValue(try Self(node.requiredChild()))
        case "Shared": self = .borrowing(try Self(node.requiredChild()))
        case "Owned": self = .consuming(try Self(node.requiredChild()))
        case "FunctionType", "NoEscapeFunctionType", "UncurriedFunctionType", "CFunctionPointer", "ObjCBlock":
            let input = try Self(node.requiredChild(kind: "ArgumentTuple"))
            let arguments: [Self]
            if case .tuple(let elements) = input { arguments = elements } else { arguments = [input] }
            let failure: Self?
            if let typed = node.child(kind: "TypedThrowsAnnotation") {
                failure = try Self(typed.requiredChild())
            } else {
                failure = node.child(kind: "ThrowsAnnotation") == nil ? nil : .nominal("Swift.Error", [])
            }
            self = .function(arguments, try Self(node.requiredChild(kind: "ReturnType")),
                failure: failure, isAsync: node.child(kind: "AsyncAnnotation") != nil)
        case "ProtocolList", "ProtocolListWithAnyObject", "ProtocolListWithClass", "BuiltinTypeName":
            self = .nominal(try node.name(), [])
        case "SugaredOptional": self = .nominal("Swift.Optional", [try Self(node.requiredChild())])
        case "SugaredArray": self = .nominal("Swift.Array", [try Self(node.requiredChild())])
        case "SugaredDictionary": self = .nominal("Swift.Dictionary", try children.map(Self.init))
        default:
            throw ABIResolutionError.unsupportedDeclaration("Cannot decode the Swift " + node.kind + " formal type.")
        }
    }

    var nominalDeclaration: (name: String, arguments: [Self])? {
        switch self {
        case .nominal(let name, let arguments): return (name, arguments)
        case .nested(let parent, let name, let arguments):
            guard let context = parent.nominalDeclaration else { return nil }
            return (context.name + "." + name, context.arguments + arguments)
        default: return nil
        }
    }
}

extension SwiftSyntax.Node {
    func requiredChild(kind: String? = nil, fallingBackToFirst: Bool = false) throws -> Self {
        if let kind, let child = child(kind: kind) { return child }
        if (kind == nil || fallingBackToFirst), let child = children().first { return child }
        throw ABIResolutionError.unsupportedDeclaration("The Swift " + self.kind + " node is missing " + (kind ?? "its type") + ".")
    }

    func requiredText() throws -> String {
        guard let value = text() else {
            throw ABIResolutionError.unsupportedDeclaration("The Swift " + kind + " node is missing its name.")
        }
        return value
    }
}
