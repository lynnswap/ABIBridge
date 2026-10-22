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
    /// Whether the image exports the descriptor of a type that the module
    /// declares, so the absence of another public type's descriptor is
    /// meaningful. A link that hides the module's symbols exports none.
    package let exportsTypeDescriptors: Bool
    /// Whether the image is a dylib or bundle. An executable need not export
    /// the public declarations of the modules linked into it.
    package let isLibrary: Bool

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
        let header = UnsafeRawPointer(bitPattern: UInt(image.identity.headerAddress))
        let fileType = header?.load(fromByteOffset: 12, as: UInt32.self)
        isLibrary = fileType == UInt32(MH_DYLIB) || fileType == UInt32(MH_BUNDLE)
        let symbols = resolver.exportedSymbols(withPrefix: "_$s" + module, in: image)
        var exportsTypeDescriptors = false
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
            if name.hasSuffix("Mn") {
                if !exportsTypeDescriptors {
                    exportsTypeDescriptors = declaredByModule(name) == true
                }
                continue
            }
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
        self.exportsTypeDescriptors = exportsTypeDescriptors
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

    // A property descriptor names its owner with the owner's generic
    // parameters; the owner's nominal descriptor names it without them.
    private static func describesStoredField(
        _ symbol: String,
        ofModule module: String,
        structures: [String: UInt64]
    ) -> Bool {
        let marker = "property descriptor for "
        guard let name = DeclarationKey.demangle(symbol, language: .swift),
            name.hasPrefix(marker), isDeclared(byModule: module, name) == true,
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
