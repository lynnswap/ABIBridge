import ABIBridgeCore
import Darwin
import Synchronization

/// What one image's export trie shows about how one of its Swift modules was
/// built. Nothing in a type's own metadata records `@frozen`; library
/// evolution instead leaves symbols that only a resilient interface needs.
///
/// Library evolution exports enum case symbols (`WC`), dispatch thunks
/// (`Tj`), class metadata base offsets (`Mo`), method lookup functions (`Mu`),
/// and property descriptors whose key-path component is a stored field
/// (discriminator 1 or 3). Without it, the descriptor of a stored field is
/// trivial (header 0). A library-evolution module also gives trivial
/// descriptors to computed, static, and reference-storage properties, and to
/// a `let` whose type a key path reabstracts, such as a function or a
/// metatype. Only an instance property backed by a struct's stored field that
/// a key path stores directly counts as evidence against library evolution.
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/SILGen/SILGen.cpp
///
/// Absent symbols are evidence only through the export trie, never through
/// local symbols or `dladdr`, which stripping removes.
package struct RuntimeSwiftModuleEvidence: Sendable {
    package enum LibraryEvolution: Sendable {
        case enabled, disabled
        /// No evidence either way, or evidence both ways.
        case unknown
    }

    package let libraryEvolution: LibraryEvolution
    /// Whether the image exports any symbol in the module's context, so the
    /// absence of a public declaration's descriptor is meaningful.
    package let exportsSymbols: Bool
    /// Whether the image is a dylib or bundle. An executable need not export
    /// the public declarations of the modules linked into it.
    package let isLibrary: Bool
    /// The exported nominal type descriptors in the module's context, by
    /// address, with their mangled declarations.
    private let descriptors: [UInt64: String]

    private struct Key: Hashable {
        let image: RuntimeImageIdentity
        let module: String
    }
    private static let cache = Mutex<[Key: Self]>([:])

    /// - Parameter module: The module's mangled context, such as `8ProbeLib`
    ///   or `s` for the standard library.
    package static func evidence(
        forModule module: String,
        in image: RuntimeImage,
        resolver: RuntimeSymbolResolver = .shared
    ) -> Self {
        let key = Key(image: image.identity, module: module)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let evidence = Self(module: module, image: image, resolver: resolver)
        return cache.withLock { cache in
            if let cached = cache[key] { return cached }
            cache[key] = evidence
            return evidence
        }
    }

    private init(module: String, image: RuntimeImage, resolver: RuntimeSymbolResolver) {
        let header = UnsafeRawPointer(bitPattern: UInt(image.identity.headerAddress))
        let fileType = header?.load(fromByteOffset: 12, as: UInt32.self)
        isLibrary = fileType == UInt32(MH_DYLIB) || fileType == UInt32(MH_BUNDLE)
        let symbols = resolver.exportedSymbols(withPrefix: "_$s" + module, in: image)
        exportsSymbols = !symbols.isEmpty
        var resilient = false
        var fixed = false
        var structures: [String: UInt64]?
        var descriptors: [UInt64: String] = [:]
        for symbol in symbols {
            let name = symbol.name
            if name.hasSuffix("Mn") {
                descriptors[symbol.address] = String(name.dropFirst(3).dropLast(2))
                continue
            }
            if name.hasSuffix("WC") || name.hasSuffix("Tj") || name.hasSuffix("Mo")
                || name.hasSuffix("Mu")
            {
                resilient = true
                continue
            }
            guard name.hasSuffix("vpMV"), !name.hasSuffix("vpZMV"),
                let descriptor = UnsafeRawPointer(bitPattern: UInt(symbol.address))
            else { continue }
            let component = descriptor.loadUnaligned(as: UInt32.self)
            switch (component & 0x7f00_0000) >> 24 {
            case 1, 3:
                resilient = true
            case 0 where component == 0 && !fixed:
                if structures == nil {
                    structures = Self.structureDescriptors(in: symbols)
                }
                fixed = Self.describesStoredField(name, structures: structures!)
            default:
                break
            }
        }
        libraryEvolution =
            resilient == fixed ? .unknown : resilient ? .enabled : .disabled
        self.descriptors = descriptors
    }

    /// The mangled declaration, such as `8ProbeLib5PointV`, under which the
    /// image exports the module's nominal type descriptor at `address`.
    ///
    /// A runtime type name can spell a declaration differently from its
    /// symbol: it omits the generic signature of a constrained extension.
    package func exportedDeclaration(at address: UInt64) -> String? {
        descriptors[address]
    }

    private static func structureDescriptors(in symbols: [IndexedSymbol]) -> [String: UInt64] {
        let marker = "nominal type descriptor for "
        var result: [String: UInt64] = [:]
        for symbol in symbols where symbol.name.hasSuffix("VMn") {
            guard let name = DeclarationKey.demangle(symbol.name, language: .swift),
                name.hasPrefix(marker)
            else { continue }
            result[String(name.dropFirst(marker.count))] = symbol.address
        }
        return result
    }

    // A property descriptor names its owner with the owner's generic
    // parameters; the owner's nominal descriptor names it without them.
    private static func describesStoredField(
        _ symbol: String,
        structures: [String: UInt64]
    ) -> Bool {
        let marker = "property descriptor for "
        guard let name = DeclarationKey.demangle(symbol, language: .swift),
            name.hasPrefix(marker),
            let typeMarker = name.range(of: " : ")
        else { return false }
        var declaration = String(
            name[name.index(name.startIndex, offsetBy: marker.count)..<typeMarker.lowerBound]
        )
        guard !declaration.hasPrefix("static "), let dot = declaration.lastIndex(of: ".") else {
            return false
        }
        let property = String(declaration[declaration.index(after: dot)...])
        declaration = String(declaration[..<dot])
        for group in SwiftGenericSyntax.groups(in: declaration).reversed() {
            declaration.removeSubrange(group.range)
        }
        guard let owner = structures[declaration],
            let descriptor = UnsafeRawPointer(bitPattern: UInt(owner))
        else { return false }
        return ABISwiftStructDescriptorFieldHasStoredKeyPathComponent(descriptor, property)
    }
}

extension RuntimeSymbolResolver {
    /// Whether `image` exports an enum case symbol (`WC`) for a case of the
    /// enum itself, not of a type nested in it.
    ///
    /// - Parameter declaration: The enum's mangled declaration as its
    ///   exported descriptor spells it.
    package func exportsSwiftEnumCases(declaration: String, in image: RuntimeImage) -> Bool {
        let marker = "nominal type descriptor for "
        guard let descriptor = DeclarationKey.demangle("$s" + declaration + "Mn", language: .swift),
            descriptor.hasPrefix(marker)
        else { return false }
        let prefix = "enum case for " + descriptor.dropFirst(marker.count) + "."
        return exportedSymbols(withPrefix: "_$s" + declaration, in: image).contains { symbol in
            guard symbol.name.hasSuffix("WC"),
                let name = DeclarationKey.demangle(symbol.name, language: .swift),
                name.hasPrefix(prefix)
            else { return false }
            // A nested type's case continues with another qualified component.
            let remainder = name.dropFirst(prefix.count)
            return !remainder.prefix { $0 != "(" && $0 != "<" }.contains(".")
        }
    }
}
