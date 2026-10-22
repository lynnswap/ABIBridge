import ABIBridgeCore
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
/// Symbols of another module's extension of the module's types share the
/// module's context, but they show how that other module was built, so only
/// the module's own declarations count. Absent symbols are evidence only
/// through the export trie, never through local symbols or `dladdr`, which
/// stripping removes.
package struct RuntimeSwiftModuleEvidence: Sendable {
    package enum LibraryEvolution: Sendable {
        case enabled, disabled
        /// No evidence either way, or evidence both ways.
        case unknown
    }

    package let libraryEvolution: LibraryEvolution

    private struct Key: Hashable {
        let image: RuntimeImageIdentity
        let module: String
    }
    private static let cache = Mutex<[Key: Self]>([:])

    /// - Parameters:
    ///   - module: The module's mangled context, such as `8ProbeLib` or `s`
    ///     for the standard library.
    ///   - name: The module's name, such as `ProbeLib` or `Swift`.
    package static func evidence(
        forModule module: String,
        named name: String,
        in image: RuntimeImage,
        resolver: RuntimeSymbolResolver = .shared
    ) -> Self {
        let key = Key(image: image.identity, module: module)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let evidence = Self(module: module, name: name, image: image, resolver: resolver)
        return cache.withLock { cache in
            if let cached = cache[key] { return cached }
            cache[key] = evidence
            return evidence
        }
    }

    private init(
        module: String,
        name moduleName: String,
        image: RuntimeImage,
        resolver: RuntimeSymbolResolver
    ) {
        let symbols = resolver.exportedSymbols(withPrefix: "_$s" + module, in: image)
        var resilient = false
        var fixed = false
        var structures: [String: UInt64]?
        // A symbol that cannot be demangled still counts as evidence of
        // library evolution, which only leaves the build undecided.
        func declaredByModule(_ symbol: String) -> Bool? {
            DeclarationKey.demangle(symbol, language: .swift).flatMap {
                Self.isDeclared(byModule: moduleName, $0)
            }
        }
        for symbol in symbols {
            let name = symbol.name
            if name.hasSuffix("WC") || name.hasSuffix("Tj") || name.hasSuffix("Mo")
                || name.hasSuffix("Mu")
            {
                if !resilient { resilient = declaredByModule(name) != false }
                continue
            }
            guard name.hasSuffix("vpMV"), !name.hasSuffix("vpZMV"),
                let descriptor = UnsafeRawPointer(bitPattern: UInt(symbol.address))
            else { continue }
            let component = descriptor.loadUnaligned(as: UInt32.self)
            switch (component & 0x7f00_0000) >> 24 {
            case 1, 3:
                if !resilient { resilient = declaredByModule(name) != false }
            case 0 where component == 0 && !fixed:
                if structures == nil {
                    structures = Self.structureDescriptors(in: symbols)
                }
                fixed = Self.describesStoredField(
                    name,
                    ofModule: moduleName,
                    structures: structures!
                )
            default:
                break
            }
        }
        libraryEvolution =
            resilient == fixed ? .unknown : resilient ? .enabled : .disabled
    }

    /// The demangled kinds of the symbols the evidence reads, each followed
    /// by the declaration the symbol belongs to.
    private static let symbolKinds = [
        "nominal type descriptor for ", "property descriptor for ", "enum case for ",
        "dispatch thunk of ", "class metadata base offset for ", "method lookup function for ",
    ]

    /// Whether a demangled symbol belongs to a declaration of the module, not
    /// to another module's extension, which demangles as `(extension in
    /// Other):`. Nil for another kind of symbol.
    private static func isDeclared(byModule module: String, _ symbol: String) -> Bool? {
        guard let kind = symbolKinds.first(where: { symbol.hasPrefix($0) }) else { return nil }
        var declaration = symbol.dropFirst(kind.count)
        if declaration.hasPrefix("static ") { declaration = declaration.dropFirst(7) }
        let marker = "(extension in "
        guard declaration.hasPrefix(marker) else { return true }
        return declaration.dropFirst(marker.count).hasPrefix(module + "):")
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

    private static func describesStoredField(
        _ symbol: String,
        ofModule module: String,
        structures: [String: UInt64]
    ) -> Bool {
        guard let name = DeclarationKey.demangle(symbol, language: .swift),
            isDeclared(byModule: module, name) == true,
            let property = PropertyDescriptor(demangled: name),
            let owner = structures[property.owner],
            let descriptor = UnsafeRawPointer(bitPattern: UInt(owner))
        else { return false }
        return ABISwiftStructDescriptorFieldHasStoredKeyPathComponent(descriptor, property.name)
    }
}

/// A demangled instance property descriptor, such as `property descriptor
/// for ProbeLib.Pair<A>.first : A`.
private struct PropertyDescriptor {
    /// The declaration that owns the property, without generic arguments,
    /// as the owner's nominal type descriptor names it.
    let owner: String
    let name: String
    let type: Substring

    init?(demangled symbol: String) {
        let marker = "property descriptor for "
        guard symbol.hasPrefix(marker), let typeMarker = symbol.range(of: " : ") else {
            return nil
        }
        var declaration = String(
            symbol[symbol.index(symbol.startIndex, offsetBy: marker.count)..<typeMarker.lowerBound]
        )
        guard !declaration.hasPrefix("static ") else { return nil }
        for group in SwiftGenericSyntax.groups(in: declaration).reversed() {
            declaration.removeSubrange(group.range)
        }
        guard let dot = declaration.lastIndex(of: ".") else { return nil }
        owner = String(declaration[..<dot])
        name = String(declaration[declaration.index(after: dot)...])
        type = symbol[typeMarker.upperBound...]
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

    /// The declared types of a Swift type's instance properties whose
    /// descriptors `image` exports, by property name, with each descriptor's
    /// symbol. Only a public property has an exported descriptor. The types
    /// are demangled, so the property's own opaque type reads `some`.
    ///
    /// - Parameter declaration: The type's mangled declaration as its
    ///   exported descriptor spells it.
    package func exportedSwiftPropertyTypes(
        declaration: String,
        in image: RuntimeImage
    ) -> [String: (type: String, symbol: String)] {
        let marker = "nominal type descriptor for "
        guard let descriptor = DeclarationKey.demangle("$s" + declaration + "Mn", language: .swift),
            descriptor.hasPrefix(marker)
        else { return [:] }
        var owner = String(descriptor.dropFirst(marker.count))
        for group in SwiftGenericSyntax.groups(in: owner).reversed() {
            owner.removeSubrange(group.range)
        }
        var types: [String: (type: String, symbol: String)] = [:]
        for symbol in exportedSymbols(withPrefix: "_$s" + declaration, in: image)
        where symbol.name.hasSuffix("vpMV") {
            // A nested type's property has another owner.
            guard let name = DeclarationKey.demangle(symbol.name, language: .swift),
                let property = PropertyDescriptor(demangled: name), property.owner == owner
            else { continue }
            types[property.name] = (String(property.type), symbol.name)
        }
        return types
    }
}
