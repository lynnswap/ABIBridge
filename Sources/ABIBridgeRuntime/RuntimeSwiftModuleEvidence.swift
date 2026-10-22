import Synchronization

/// What an image's export trie shows about how one of its Swift modules was
/// built. Nothing in a type's own metadata records `@frozen`; library
/// evolution instead exports symbols that only a resilient interface needs:
/// enum case symbols (`WC`), dispatch thunks (`Tj`), class metadata base
/// offsets (`Mo`), method lookup functions (`Mu`), and property descriptors
/// whose key-path component is a stored field (discriminator 1 or 3).
/// https://github.com/swiftlang/swift/blob/swift-6.3-RELEASE/lib/SILGen/SILGen.cpp
///
/// Only symbols that are present count. A module built without library
/// evolution, a link that hides symbols, and a module whose public types have
/// no such members all lack them, so their absence shows nothing. Symbols of
/// another module's extension of the module's types share the module's
/// context, but they show how that other module was built, so only the
/// module's own declarations count.
extension RuntimeSymbolResolver {
    private struct LibraryEvolutionKey: Hashable {
        let image: RuntimeImageIdentity
        let module: String
    }
    private static let libraryEvolutionSymbols = Mutex<[LibraryEvolutionKey: Bool]>([:])

    /// Whether `image` exports a symbol of one of the module's own
    /// declarations that only library evolution emits.
    ///
    /// - Parameters:
    ///   - module: The module's mangled context, such as `8ProbeLib` or `s`
    ///     for the standard library.
    ///   - name: The module's name, such as `ProbeLib` or `Swift`.
    package func exportsSwiftLibraryEvolutionSymbols(
        ofModule module: String,
        named name: String,
        in image: RuntimeImage
    ) -> Bool {
        let key = LibraryEvolutionKey(image: image.identity, module: module)
        if let cached = Self.libraryEvolutionSymbols.withLock({ $0[key] }) { return cached }
        let exports = exportedSymbols(withPrefix: "_$s" + module, in: image).contains { symbol in
            let symbolName = symbol.name
            if symbolName.hasSuffix("WC") || symbolName.hasSuffix("Tj")
                || symbolName.hasSuffix("Mo") || symbolName.hasSuffix("Mu")
            {
                return Self.isDeclared(symbolName, byModule: name)
            }
            guard symbolName.hasSuffix("vpMV"), !symbolName.hasSuffix("vpZMV"),
                let descriptor = UnsafeRawPointer(bitPattern: UInt(symbol.address))
            else { return false }
            let component = descriptor.loadUnaligned(as: UInt32.self)
            return [1, 3].contains((component & 0x7f00_0000) >> 24)
                && Self.isDeclared(symbolName, byModule: name)
        }
        return Self.libraryEvolutionSymbols.withLock { cache in
            cache[key] = cache[key] ?? exports
            return cache[key]!
        }
    }

    /// The demangled kinds of the symbols the evidence reads, each followed
    /// by the declaration the symbol belongs to.
    private static let symbolKinds = [
        "property descriptor for ", "enum case for ", "dispatch thunk of ",
        "class metadata base offset for ", "method lookup function for ",
    ]

    /// Whether a symbol demangles as one of these kinds for a declaration of
    /// the module, not of another module's extension, which demangles as
    /// `(extension in Other):`.
    private static func isDeclared(_ symbol: String, byModule module: String) -> Bool {
        guard let symbol = DeclarationKey.demangle(symbol, language: .swift),
            let kind = symbolKinds.first(where: { symbol.hasPrefix($0) })
        else { return false }
        var declaration = symbol.dropFirst(kind.count)
        if declaration.hasPrefix("static ") { declaration = declaration.dropFirst(7) }
        let marker = "(extension in "
        guard declaration.hasPrefix(marker) else { return true }
        return declaration.dropFirst(marker.count).hasPrefix(module + "):")
    }

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
