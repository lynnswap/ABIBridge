import ABIBridgeCore

/// The upstream Swift parser owns the immutable tree and copied identifier
/// bytes. A node retains that tree, including when it outlives its parent view.
final class SwiftSyntax: @unchecked Sendable {
    private let handle: OpaquePointer

    init(symbol: String) throws {
        guard let handle = symbol.utf8CString.withUnsafeBufferPointer({
            ABICopySwiftSymbolSyntax($0.baseAddress, $0.count - 1)
        }) else {
            throw ABIResolutionError.unsupportedDeclaration("Cannot decode the Swift symbol " + symbol + ".")
        }
        self.handle = handle
    }

    @unsafe init(typeReference: UnsafePointer<CChar>, length: Int) throws {
        guard let handle = ABICopySwiftTypeSyntax(typeReference, length) else {
            throw ABIResolutionError.unsupportedDeclaration("Cannot decode the Swift metadata type reference.")
        }
        self.handle = handle
    }

    init(adopting handle: OpaquePointer) { self.handle = handle }

    deinit { ABIReleaseSwiftSyntax(handle) }

    var root: Node { Node(ABISwiftSyntaxRoot(handle)!, owner: self) }

    struct Node: Sendable {
        private let address: UInt
        private let owner: SwiftSyntax
        private var pointer: OpaquePointer { OpaquePointer(bitPattern: address)! }

        fileprivate init(_ pointer: OpaquePointer, owner: SwiftSyntax) {
            address = UInt(bitPattern: pointer)
            self.owner = owner
        }

        var kind: String { withExtendedLifetime(owner) { String(cString: ABISwiftSyntaxNodeKind(pointer)) } }
        var index: UInt64? {
            withExtendedLifetime(owner) {
                ABISwiftSyntaxNodeHasIndex(pointer) ? ABISwiftSyntaxNodeIndex(pointer) : nil
            }
        }

        func text() -> String? {
            withExtendedLifetime(owner) {
                var count = 0
                guard let text = ABISwiftSyntaxNodeText(pointer, &count) else { return nil }
                return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self),
                                                            count: count), as: UTF8.self)
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
                    throw ABIResolutionError.unsupportedDeclaration("Cannot remangle the Swift " + kind + " type node.")
                }
                defer { ABIFreeString(name) }
                return String(cString: name)
            }
        }

        func constrainedExistentialShapeName() throws -> String {
            try withExtendedLifetime(owner) {
                guard let name = ABICopySwiftConstrainedExistentialShapeName(pointer) else {
                    throw ABIResolutionError.unsupportedDeclaration("Cannot generalize the constrained existential requirements.")
                }
                defer { ABIFreeString(name) }
                return String(cString: name)
            }
        }

        func makeExtendedExistentialShape(protocols: [UnsafeRawPointer?], written: [String],
                                           declaring: [String], classBound: Bool) throws -> UnsafeMutableRawPointer {
            let writtenStrings = written.map { Array($0.utf8CString) }
            let declaringStrings = declaring.map { Array($0.utf8CString) }
            func pointers<Result>(_ strings: [[CChar]], _ body: ([UnsafePointer<CChar>?]) throws -> Result) rethrows -> Result {
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
                                    guard let value = ABICreateSwiftExtendedExistentialShape(pointer, protocols.baseAddress,
                                        protocols.count, written.baseAddress, declaring.baseAddress, written.count, classBound) else {
                                        throw ABIResolutionError.metadataUnavailable("Cannot form the extended existential shape.")
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
            guard let name = DeclarationKey.demangle(mangled.hasPrefix("$s") ? mangled : "$s" + mangled, language: .swift) else {
                throw ABIResolutionError.unsupportedDeclaration("Cannot display the Swift " + kind + " type node.")
            }
            return name
        }
    }
}
