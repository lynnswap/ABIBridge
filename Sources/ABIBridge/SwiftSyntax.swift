import ABIBridgeRuntime
import ABIBridgeCore

/// The upstream Swift parser owns the immutable tree and copied identifier
/// bytes. A node retains that tree, including when it outlives its parent view.
final class SwiftSyntax: @unchecked Sendable {
    private let handle: OpaquePointer

    init(symbol: String) throws {
        guard
            let handle = symbol.utf8CString.withUnsafeBufferPointer({
                ABICopySwiftSymbolSyntax($0.baseAddress, $0.count - 1)
            })
        else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Cannot decode the Swift symbol " + symbol + "."
            )
        }
        self.handle = handle
    }

    @unsafe init(typeReference: UnsafePointer<CChar>, length: Int) throws {
        guard let handle = ABICopySwiftTypeSyntax(typeReference, length) else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Cannot decode the Swift metadata type reference."
            )
        }
        self.handle = handle
    }

    init(adopting handle: OpaquePointer) { self.handle = handle }

    deinit { ABIReleaseSwiftSyntax(handle) }

    var root: Node { Node(ABISwiftSyntaxRoot(handle)!, owner: self) }

    static func metadataType(_ type: Any.Type) throws -> Node {
        if let syntax = try extendedMetadataType(type) { return syntax }
        guard let name = _mangledTypeName(type) else {
            throw ABIResolutionError.metadataUnavailable(
                "The metadata's mangled type name is unavailable."
            )
        }
        return try name.utf8CString.withUnsafeBufferPointer {
            try unsafe SwiftSyntax(typeReference: $0.baseAddress!, length: $0.count - 1).root
        }
    }

    static func extendedMetadataType(_ type: Any.Type) throws -> Node? {
        let pointer = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let kind = pointer.load(as: UInt.self)
        if kind == 0x307 {
            guard let handle = ABICopySwiftExtendedExistentialTypeSyntax(pointer) else {
                throw ABIResolutionError.metadataUnavailable(
                    "The extended existential's type expression is unavailable."
                )
            }
            let source = SwiftSyntax(adopting: handle).root
            let arguments = try SwiftGenericTypeMetadata(metadata: type).arguments.map { argument in
                guard case .type(let value, _) = argument.storage else {
                    throw ABIResolutionError.metadataUnavailable(
                        "The extended existential has a non-scalar generalization parameter."
                    )
                }
                return try metadataType(value)
            }
            return try source.substitutingTypeArguments(arguments)
        }
        if let optional = type as? any NativeOptionalValue.Type,
            let wrapped = try extendedMetadataType(optional.wrappedType)
        {
            return try containerType(kind: 0x202, elements: [wrapped])
        }
        if let metatype = SwiftMetatypeMetadata(type), let instance = metatype.instance,
            let wrapped = try extendedMetadataType(instance)
        {
            return try containerType(kind: UInt32(kind), elements: [wrapped])
        }
        if let tuple = SwiftTupleMetadata(type) {
            let extended = try tuple.elements.map { try extendedMetadataType($0.type) }
            guard extended.contains(where: { $0 != nil }) else { return nil }
            let elements = try tuple.elements.enumerated().map { index, element in
                try extended[index] ?? metadataType(element.type)
            }
            return try containerType(kind: 0x301, elements: elements, labels: tuple.labels)
        }
        if kind == 0x302 {
            let info = try SwiftFunctionMetadata(type)
            let types = [info.result] + info.parameters
            let extended = try types.map(extendedMetadataType)
            guard extended.contains(where: { $0 != nil }) else { return nil }
            let elements = try types.enumerated().map { index, type in
                try extended[index] ?? metadataType(type)
            }
            let failure = try info.extendedFlags & 1 != 0 ? metadataType(info.failure) : nil
            let actor = try info.globalActor.map(metadataType)
            return try withExtendedLifetime((elements, failure, actor)) {
                let handle = elements.dropFirst().map { Optional($0.pointer) }
                    .withUnsafeBufferPointer { parameters in
                        info.parameterFlags.withUnsafeBufferPointer {
                            ABICopySwiftFunctionTypeSyntax(
                                info.flags,
                                info.extendedFlags,
                                parameters.baseAddress,
                                $0.baseAddress,
                                elements[0].pointer,
                                failure?.pointer,
                                actor?.pointer,
                                info.attributes.differentiability.rawValue
                            )
                        }
                    }
                guard let handle else {
                    throw ABIResolutionError.metadataUnavailable(
                        "Cannot describe the function metadata's type expression."
                    )
                }
                return SwiftSyntax(adopting: handle).root
            }
        }
        return nil
    }

    private static func containerType(
        kind: UInt32,
        elements: [Node],
        labels: [String] = []
    ) throws -> Node {
        let strings = labels.map { Array($0.utf8CString) }
        var pointers: [UnsafePointer<CChar>?] = []
        func append(_ index: Int) throws -> Node {
            if index < strings.count {
                return try strings[index].withUnsafeBufferPointer {
                    pointers.append($0.baseAddress)
                    defer { pointers.removeLast() }
                    return try append(index + 1)
                }
            }
            return try withExtendedLifetime(elements) {
                let handle = elements.map { Optional($0.pointer) }.withUnsafeBufferPointer {
                    elements in
                    pointers.withUnsafeBufferPointer {
                        ABICopySwiftContainerTypeSyntax(
                            kind,
                            elements.baseAddress,
                            elements.count,
                            $0.baseAddress
                        )
                    }
                }
                guard let handle else {
                    throw ABIResolutionError.metadataUnavailable(
                        "Cannot describe the container metadata's type expression."
                    )
                }
                return SwiftSyntax(adopting: handle).root
            }
        }
        return try append(0)
    }

    struct Node: Sendable {
        private let address: UInt
        private let owner: SwiftSyntax
        fileprivate var pointer: OpaquePointer { OpaquePointer(bitPattern: address)! }

        fileprivate init(_ pointer: OpaquePointer, owner: SwiftSyntax) {
            address = UInt(bitPattern: pointer)
            self.owner = owner
        }

        var kind: String {
            withExtendedLifetime(owner) { String(cString: ABISwiftSyntaxNodeKind(pointer)) }
        }
        var index: UInt64? {
            withExtendedLifetime(owner) {
                ABISwiftSyntaxNodeHasIndex(pointer) ? ABISwiftSyntaxNodeIndex(pointer) : nil
            }
        }

        func text() -> String? {
            withExtendedLifetime(owner) {
                var count = 0
                guard let text = ABISwiftSyntaxNodeText(pointer, &count) else { return nil }
                return String(
                    decoding: UnsafeBufferPointer(
                        start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self),
                        count: count
                    ),
                    as: UTF8.self
                )
            }
        }

        func children() -> [Node] {
            withExtendedLifetime(owner) {
                (0..<ABISwiftSyntaxNodeChildCount(pointer)).map {
                    Node(ABISwiftSyntaxNodeChild(pointer, $0)!, owner: owner)
                }
            }
        }

        func child(kind: String) -> Node? { children().first { $0.kind == kind } }

        func mangledName() throws -> String {
            try withExtendedLifetime(owner) {
                guard let name = ABICopySwiftSyntaxNodeMangledName(pointer) else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "Cannot remangle the Swift " + kind + " type node."
                    )
                }
                defer { ABIFreeString(name) }
                return String(cString: name)
            }
        }

        func substitutingTypeArguments(_ arguments: [Node]) throws -> Node {
            try withExtendedLifetime((self, arguments)) {
                let handle = arguments.map { Optional($0.pointer) }.withUnsafeBufferPointer {
                    ABICopySwiftSubstitutedTypeSyntax(pointer, $0.baseAddress, $0.count)
                }
                guard let handle else {
                    throw ABIResolutionError.metadataUnavailable(
                        "Cannot substitute the metadata's type expression."
                    )
                }
                return SwiftSyntax(adopting: handle).root
            }
        }

        func constrainedExistentialShapeName(metatypeDepth: Int = 0) throws -> String {
            try withExtendedLifetime(owner) {
                guard let name = ABICopySwiftConstrainedExistentialShapeName(pointer, metatypeDepth)
                else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "Cannot generalize the constrained existential requirements."
                    )
                }
                defer { ABIFreeString(name) }
                return String(cString: name)
            }
        }

        func makeExtendedExistentialShape(
            protocols: [UnsafeRawPointer?],
            written: [String],
            declaring: [String],
            classBound: Bool,
            superclass: Any.Type?
        ) throws -> UnsafeMutableRawPointer {
            let writtenStrings = written.map { Array($0.utf8CString) }
            let declaringStrings = declaring.map { Array($0.utf8CString) }
            func pointers<Result>(
                _ strings: [[CChar]],
                _ body: ([UnsafePointer<CChar>?]) throws -> Result
            ) rethrows -> Result {
                var values: [UnsafePointer<CChar>?] = []
                func append(_ index: Int) throws -> Result {
                    if index == strings.count { return try body(values) }
                    return try strings[index].withUnsafeBufferPointer {
                        values.append($0.baseAddress)
                        defer { values.removeLast() }
                        return try append(index + 1)
                    }
                }
                return try append(0)
            }
            return try withExtendedLifetime(owner) {
                try pointers(writtenStrings) { written in
                    try pointers(declaringStrings) { declaring in
                        try protocols.withUnsafeBufferPointer { protocols in
                            try written.withUnsafeBufferPointer { written in
                                try declaring.withUnsafeBufferPointer { declaring in
                                    guard
                                        let value = ABICreateSwiftExtendedExistentialShape(
                                            pointer,
                                            protocols.baseAddress,
                                            protocols.count,
                                            written.baseAddress,
                                            declaring.baseAddress,
                                            written.count,
                                            classBound,
                                            superclass.map {
                                                unsafeBitCast($0, to: UnsafeRawPointer.self)
                                            }
                                        )
                                    else {
                                        throw ABIResolutionError.metadataUnavailable(
                                            "Cannot form the extended existential shape."
                                        )
                                    }
                                    return value
                                }
                            }
                        }
                    }
                }
            }
        }

        func name() throws -> String {
            let mangled = try mangledName()
            guard
                let name = DeclarationKey.demangle(
                    mangled.hasPrefix("$s") ? mangled : "$s" + mangled,
                    language: .swift
                )
            else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Cannot display the Swift " + kind + " type node."
                )
            }
            return name
        }
    }
}
