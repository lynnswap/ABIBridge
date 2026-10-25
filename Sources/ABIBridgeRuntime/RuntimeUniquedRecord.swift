import ABIBridgeCore
import ABIBridgeCore.Backend
import Darwin

/// A kind of record that every module using it defines for itself, and that
/// the Swift runtime identifies by its contents instead of its address.
///
/// The compiler emits the non-unique shape (`…Mq`) of an extended existential
/// type, and the descriptor of an imported type, into each module that uses
/// them. Linking several modules into one image, or loading several such
/// images, leaves several definitions under one symbol. The runtime takes the
/// definitions it identifies as one record for each other, so any of them
/// stands for the rest.
package enum RuntimeUniquedRecord: Hashable {
    /// A non-unique extended existential type shape, which the runtime
    /// uniques by the mangling of its existential type.
    case extendedExistentialShape
    /// A nominal type descriptor. The runtime identifies a descriptor whose
    /// flags do not mark it unique, such as an imported type's, by its kind,
    /// parents, and name.
    case typeDescriptor

    /// Returns nil for the symbols of other records.
    package init?(linkageName: String) {
        let name = linkageName.hasPrefix("_") ? String(linkageName.dropFirst()) : linkageName
        guard
            let syntax = name.utf8CString.withUnsafeBufferPointer({
                ABICopySwiftSymbolSyntax($0.baseAddress, $0.count - 1)
            })
        else { return nil }
        defer { ABIReleaseSwiftSyntax(syntax) }
        func kind(_ node: OpaquePointer) -> String { String(cString: ABISwiftSyntaxNodeKind(node)) }
        guard let root = ABISwiftSyntaxRoot(syntax), kind(root) == "Global",
            ABISwiftSyntaxNodeChildCount(root) == 1, let record = ABISwiftSyntaxNodeChild(root, 0)
        else { return nil }
        switch kind(record) {
        // The compiler marks a non-unique shape's symbol as uniquable.
        case "Uniquable":
            guard ABISwiftSyntaxNodeChildCount(record) == 1,
                let shape = ABISwiftSyntaxNodeChild(record, 0),
                kind(shape) == "ExtendedExistentialTypeShape"
            else { return nil }
            self = .extendedExistentialShape
        case "NominalTypeDescriptor":
            self = .typeDescriptor
        default:
            return nil
        }
    }

    /// The first of `definitions` of one symbol, when the runtime identifies
    /// them all as one record.
    ///
    /// - Returns: Nil when the definitions are not all records of one kind
    ///   that the runtime identifies by their contents. Competing definitions
    ///   also return nil when their storage is too short for comparison; their
    ///   symbol alone leaves them ambiguous.
    /// - Throws: `RuntimeResolutionError.ambiguousDeclaration`, naming each
    ///   definition, when the runtime tells the records apart.
    package static func representative(of definitions: [RuntimeSymbol]) throws -> RuntimeSymbol? {
        let records = Set(definitions.map(\.linkageName)).map(Self.init(linkageName:))
        guard let first = definitions.first, let record = records.first ?? nil,
            records.allSatisfy({ $0 == record })
        else { return nil }
        var identified = true
        for definition in definitions.dropFirst() {
            guard let same = record.identifies(first, definition) else { return nil }
            identified = identified && same
        }
        guard !identified else { return first }
        throw RuntimeResolutionError.ambiguousDeclaration(
            first.declaration,
            candidates: definitions.map(record.description(of:))
        )
    }

    // Both records start with three 32-bit fields: a non-unique shape with
    // its cache, flags, and existential type; a context descriptor with its
    // flags, parent, and name.
    // https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/include/swift/ABI/Metadata.h
    private static let headerSize: UInt64 = 12

    private func identifies(_ lhs: RuntimeSymbol, _ rhs: RuntimeSymbol) -> Bool? {
        guard Self.holdsHeader(lhs), Self.holdsHeader(rhs) else { return nil }
        return unsafe lhs.withUnsafeAddress { first in
            unsafe rhs.withUnsafeAddress { second in
                switch self {
                case .extendedExistentialShape:
                    guard
                        let firstType = RuntimeExtendedExistentialShapeLayout.existentialType(
                            nonUniqueDescriptor: first
                        ),
                        let secondType = RuntimeExtendedExistentialShapeLayout.existentialType(
                            nonUniqueDescriptor: second
                        )
                    else { return nil }
                    return strcmp(firstType, secondType) == 0
                case .typeDescriptor:
                    return ABISwiftContextDescriptorsEqual(first, second)
                }
            }
        }
    }

    private static func holdsHeader(_ definition: RuntimeSymbol) -> Bool {
        definition.sectionRange.contains(definition.address)
            && definition.sectionRange.upperBound - definition.address >= headerSize
    }

    private func description(of definition: RuntimeSymbol) -> String {
        let location = definition.image.path + " at 0x" + String(definition.address, radix: 16)
        guard self == .extendedExistentialShape, Self.holdsHeader(definition),
            let type = unsafe definition.withUnsafeAddress({
                RuntimeExtendedExistentialShapeLayout.existentialType(nonUniqueDescriptor: $0)
                    .map { String(cString: $0) }
            })
        else { return location }
        return location + " (" + type + ")"
    }
}
