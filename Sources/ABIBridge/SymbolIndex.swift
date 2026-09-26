import ABIBridgeCore
import Foundation
import Darwin
import MachO
import MachOKit

struct IndexedSymbol: Hashable {
    let name: String
    let address: UInt64
    let source: ResolvedSymbol.Source

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.address == rhs.address && lhs.source == rhs.source && lhs.name.utf8.elementsEqual(rhs.name.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(address)
        hasher.combine(source)
    }
}

struct SymbolSection {
    let range: Range<UInt64>
    let code: Bool
    let vtable: Bool
    let threadLocal: Bool

    func accepts(_ kind: NativeSymbolKind) -> Bool {
        guard !threadLocal else { return false }
        switch kind {
        case .function: return code
        case .data: return !code
        case .vtable: return vtable
        }
    }
}

enum DeclarationKey {
    // These are exactly the prefixes accepted by the native demanglers.
    static func symbolPrefixes(for language: NativeLanguage) -> [String] {
        switch language {
        case .cxx: ["__Z", "_Z"]
        case .swift: ["_$s", "_$S", "$s", "$S"]
        default: []
        }
    }

    static func fingerprint(_ key: [UInt8]) -> Int {
        var hasher = Hasher()
        key.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    static func make(_ declaration: String) -> [UInt8] {
        var key: [UInt8] = []
        key.reserveCapacity(declaration.utf8.count * 2)
        var inIdentifier = false
        for byte in declaration.utf8 {
            if (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122) || byte == 95 {
                if !inIdentifier { key.append(0) }
                key.append(byte)
                inIdentifier = true
            } else if (byte >= 9 && byte <= 13) || byte == 32 {
                inIdentifier = false
            } else {
                key.append(0)
                key.append(byte)
                inIdentifier = false
            }
        }
        return key
    }

    static func demangle(_ raw: String, language: NativeLanguage) -> String? {
        switch language {
        case .c: return raw.hasPrefix("_") ? String(raw.dropFirst()) : raw
        case .cxx, .swift:
            let decoded = raw.withCString {
                language == .cxx ? ABICopyDemangledCXXName($0) : ABICopyDemangledSwiftName($0)
            }
            guard let decoded else { return nil }
            defer { ABIFreeString(decoded) }
            return String(cString: decoded)
        case .objectiveC: return nil
        }
    }
}

struct SymbolQuery {
    let declaration: NativeDeclaration
    let exactName: String?
    let key: [UInt8]
    let fingerprint: Int
    let filter: CXXSymbolFilter?

    init(_ declaration: NativeDeclaration) {
        self.declaration = declaration
        if declaration.nameForm != .source || declaration.language == .c {
            let name = declaration.nameForm == .machO ? declaration.name : "_" + declaration.name
            exactName = name
            key = Array(name.utf8)
            fingerprint = 0
            filter = nil
        } else {
            exactName = nil
            key = DeclarationKey.make(declaration.name)
            fingerprint = DeclarationKey.fingerprint(key)
            filter = declaration.language == .cxx ? CXXSymbolFilter(declaration.name) : nil
        }
    }
}

/// A conservative prefilter over Itanium names. Matching still uses the full
/// demangled declaration; complex spellings fall back to unfiltered lookup.
struct CXXSymbolFilter {
    let fragments: [String]
    private let needles: [[CChar]]

    init(_ declaration: String) {
        var prefix = String(declaration.prefix { $0 != "(" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s*::\\s*", with: "::", options: .regularExpression)
        // A leading return type can precede parentheses in anonymous namespaces
        // or decltype expressions. Keep the original unfiltered path unless a
        // qualified name is present; typeinfo spellings also remain unfiltered.
        let hasQualification = prefix.contains("::")
        var isTypeName = false
        if let marker = prefix.range(of: "^vtable\\s+for\\s+", options: .regularExpression) {
            prefix.removeSubrange(marker)
            isTypeName = true
        }
        // Operator spellings are encoded as ABI codes, not literal identifiers.
        // The enclosing ordinary class name can still narrow the candidates.
        if let operation = prefix.range(of: "::operator") {
            prefix = String(prefix[..<operation.lowerBound])
            isTypeName = true
        }
        guard hasQualification,
              prefix.range(of: "^(?:[A-Za-z_][A-Za-z0-9_]*::)*~?[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            fragments = []
            needles = []
            return
        }
        let substitutions: Set<String> = [
            "std", "__1", "allocator", "basic_string", "string",
            "basic_istream", "basic_ostream", "basic_iostream", "istream", "ostream", "iostream",
        ]
        var names = Array(prefix.replacingOccurrences(of: "~", with: "")
            .components(separatedBy: "::").suffix(2))
        // Group type metadata and operators with the class's ordinary members.
        if isTypeName { names.reverse() }
        var selected: [String] = []
        for name in names where !substitutions.contains(name) && !selected.contains(name) {
            selected.append(name)
        }
        fragments = selected
        needles = selected.map { Array($0.utf8CString) }
    }

    func matchesOwner(_ rawName: String) -> Bool {
        guard let needle = needles.first else { return true }
        return rawName.withCString { raw in
            needle.withUnsafeBufferPointer { strstr(raw, $0.baseAddress!) != nil }
        }
    }

    func matches(_ rawName: String) -> Bool {
        if needles.isEmpty { return true }
        return rawName.withCString { raw in
            needles.allSatisfy { needle in
                needle.withUnsafeBufferPointer { strstr(raw, $0.baseAddress!) != nil }
            }
        }
    }
}

final class SymbolIndex {
    let image: NativeImage
    let sections: [SymbolSection]
    private let macho: MachOImage
    private lazy var exportTrie = macho.exportTrie
    private var localSymbols: [IndexedSymbol] = []
    private var sourceSymbols: [NativeLanguage: [IndexedSymbol]] = [:]
    var sharedCacheLoaded = false
    private struct Scope: Hashable {
        let language: NativeLanguage
        let fragments: [String]
    }
    private var decoded: [Scope: [Int: [IndexedSymbol]]] = [:]
    private var cxxCandidates: [String: [IndexedSymbol]] = [:]
    private var linkerNames: [[UInt8]: [IndexedSymbol]] = [:]
    private var swiftExtensions: [Int: [IndexedSymbol]]?

    init(image: NativeImage) {
        self.image = image
        let macho = MachOImage(ptr: UnsafePointer<mach_header>(bitPattern: UInt(image.identity.headerAddress))!)
        self.macho = macho
        let slide = image.identity.slide
        sections = macho.sections.compactMap { section in
            guard section.address >= 0, section.size > 0,
                  let start = Self.slid(UInt64(section.address), by: slide),
                  UInt64(section.size) <= UInt64.max - start else { return nil }
            let threadLocal: Bool
            switch section.flags.type {
            case .some(.thread_local_regular), .some(.thread_local_zerofill),
                 .some(.thread_local_variables), .some(.thread_local_variable_pointers),
                 .some(.thread_local_init_function_pointers): threadLocal = true
            default: threadLocal = false
            }
            return SymbolSection(
                range: start..<(start + UInt64(section.size)),
                code: section.flags.attributes.contains(.pure_instructions) || section.flags.attributes.contains(.some_instructions),
                vtable: section.sectionName == "__const"
                    && (section.segmentName.hasPrefix("__DATA") || section.segmentName.hasPrefix("__AUTH")),
                threadLocal: threadLocal
            )
        }
    }

    func appendSharedCacheSymbols(_ more: [IndexedSymbol]) {
        sharedCacheLoaded = true
        guard !more.isEmpty else { return }
        localSymbols += more
        sourceSymbols.removeAll()
        decoded.removeAll()
        cxxCandidates.removeAll()
        swiftExtensions = nil
        linkerNames.removeAll()
    }

    private func imageSymbol(name: String, offset: Int) -> IndexedSymbol? {
        let base = image.identity.headerAddress
        guard offset >= 0, UInt64(offset) <= UInt64.max - base else { return nil }
        return IndexedSymbol(name: name, address: base + UInt64(offset), source: .image)
    }

    private func tableSymbols(matching predicate: (UnsafePointer<CChar>) -> Bool) -> [IndexedSymbol] {
        if let table = macho.symbols64 {
            var result: [IndexedSymbol] = []
            for index in 0..<table.numberOfSymbols {
                let entry = table.symbols[index]
                guard Int32(entry.n_type) & N_TYPE == N_SECT else { continue }
                let name = table.stringBase.advanced(by: Int(entry.n_un.n_strx))
                guard predicate(name) else { continue }
                if let symbol = imageSymbol(name: String(cString: name), offset: table.addressStart + Int(entry.n_value)) {
                    result.append(symbol)
                }
            }
            return result
        }
        func collect(_ symbols: some Sequence<MachOImage.Symbol>) -> [IndexedSymbol] {
            symbols.compactMap { symbol in
                guard symbol.nlist.flags?.type == .sect, predicate(symbol.nameC) else { return nil }
                return imageSymbol(name: symbol.name, offset: symbol.offset)
            }
        }
        if let symbols = macho.symbols32 { return collect(symbols) }
        return []
    }

    private func exactSymbols(named name: String, key: [UInt8]) -> [IndexedSymbol] {
        guard !key.contains(0) else { return [] }
        if let cached = linkerNames[key] { return cached }
        var matches = name.withCString { name in tableSymbols { strcmp($0, name) == 0 } }
        if let offset = exportedOffset(named: key), let symbol = imageSymbol(name: name, offset: offset) {
            matches.append(symbol)
        }
        matches += localSymbols.filter { $0.name.utf8.elementsEqual(key) }
        linkerNames[key] = matches
        return matches
    }

    // Export names are byte strings. String-based trie lookup would equate
    // canonically equivalent Unicode spellings that the linker keeps distinct.
    private func exportedOffset(named name: [UInt8]) -> Int? {
        guard let trie = exportTrie, !name.isEmpty else { return nil }
        var offset = 0
        var remaining = name[...]
        while offset < trie.exportSize {
            guard let node = TrieNode<ExportTrieNodeContent>.readNext(
                basePointer: trie.basePointer.assumingMemoryBound(to: UInt8.self),
                trieSize: trie.exportSize, nextOffset: &offset
            ) else { return nil }
            if remaining.isEmpty {
                return node.content?.symbolOffset.map { Int(bitPattern: $0) }
            }
            guard let child = node.children.first(where: {
                !$0.label.isEmpty && remaining.starts(with: $0.label.utf8)
            }), let childOffset = Int(exactly: child.offset) else { return nil }
            remaining = remaining.dropFirst(child.label.utf8.count)
            offset = childOffset
        }
        return nil
    }

    private func symbols(for language: NativeLanguage) -> [IndexedSymbol] {
        if let cached = sourceSymbols[language] { return cached }
        let prefixes = DeclarationKey.symbolPrefixes(for: language)
        let needles = prefixes.map { Array($0.utf8CString) }
        var symbols = tableSymbols { raw in
            needles.contains { needle in
                needle.withUnsafeBufferPointer { strncmp(raw, $0.baseAddress!, $0.count - 1) == 0 }
            }
        }
        if let trie = exportTrie {
            symbols += prefixes.flatMap { trie.search(byKeyPrefix: $0) }.compactMap { symbol in
                guard let offset = symbol.offset else { return nil }
                return imageSymbol(name: symbol.name, offset: offset)
            }
        }
        symbols += localSymbols.filter { symbol in prefixes.contains { symbol.name.hasPrefix($0) } }
        // Definitions commonly occur in both nlist and the export trie.
        // Demangle each distinct spelling/address/source only once.
        var seen = Set<IndexedSymbol>()
        symbols = symbols.filter { seen.insert($0).inserted }
        sourceSymbols[language] = symbols
        return symbols
    }

    func matches(_ declaration: NativeDeclaration, extensionsOnly: Bool = false) -> [IndexedSymbol] {
        matches(SymbolQuery(declaration), extensionsOnly: extensionsOnly)
    }

    private func matches(_ query: SymbolQuery, extensionsOnly: Bool) -> [IndexedSymbol] {
        let declaration = query.declaration
        if let name = query.exactName {
            return exactSymbols(named: name, key: query.key)
        }
        if extensionsOnly, let swiftExtensions {
            return Self.matching(swiftExtensions[query.fingerprint] ?? [], query: query, extensionsOnly: true)
        }
        let filter = query.filter
        let scope = Scope(language: declaration.language, fragments: filter?.fragments ?? [])
        if decoded[scope] == nil {
            let symbols = symbols(for: declaration.language)
            let candidates: [IndexedSymbol]
            if let filter, let owner = filter.fragments.first {
                if cxxCandidates[owner] == nil {
                    cxxCandidates[owner] = symbols.filter { filter.matchesOwner($0.name) }
                }
                candidates = cxxCandidates[owner]!
            } else {
                candidates = symbols
            }
            var index: [Int: [IndexedSymbol]] = [:]
            var extensions: [Int: [IndexedSymbol]] = [:]
            for symbol in candidates {
                guard filter?.matches(symbol.name) ?? true else { continue }
                guard let name = DeclarationKey.demangle(symbol.name, language: declaration.language) else { continue }
                // An extension fallback needs no index of ordinary declarations
                // in unrelated images. Reject those before alias/key creation.
                if extensionsOnly && Self.extensionMemberName(name) == nil { continue }
                var names = [name]
                if declaration.language == .swift, let alias = Self.operatorAlias(name) { names.append(alias) }
                for name in names {
                    if !extensionsOnly {
                        index[DeclarationKey.fingerprint(DeclarationKey.make(name)), default: []].append(symbol)
                    }
                    if declaration.language == .swift, let unqualified = Self.extensionMemberName(name) {
                        extensions[DeclarationKey.fingerprint(DeclarationKey.make(unqualified)), default: []].append(symbol)
                    }
                }
            }
            if !extensionsOnly { decoded[scope] = index }
            if declaration.language == .swift { swiftExtensions = extensions }
        }
        let candidates = extensionsOnly ? swiftExtensions?[query.fingerprint] ?? [] : decoded[scope]?[query.fingerprint] ?? []
        return Self.matching(candidates, query: query, extensionsOnly: extensionsOnly)
    }

    // Fingerprints keep the index compact; the full normalized spelling is
    // always checked before a candidate can affect resolution or ambiguity.
    static func matching(_ candidates: [IndexedSymbol], query: SymbolQuery, extensionsOnly: Bool) -> [IndexedSymbol] {
        candidates.filter { symbol in
            guard let name = DeclarationKey.demangle(symbol.name, language: query.declaration.language) else { return false }
            var names = [name]
            if query.declaration.language == .swift, let alias = operatorAlias(name) { names.append(alias) }
            return names.contains { name in
                if extensionsOnly {
                    guard let unqualified = extensionMemberName(name) else { return false }
                    return DeclarationKey.make(unqualified) == query.key
                }
                return DeclarationKey.make(name) == query.key
            }
        }
    }

    static func operatorAlias(_ name: String) -> String? {
        for token in [" infix(", " prefix(", " postfix("] {
            guard let offset = byteOffset(of: token, in: name) else { continue }
            return String(decoding: name.utf8.prefix(offset), as: UTF8.self) + "("
                + String(decoding: name.utf8.dropFirst(offset + token.utf8.count), as: UTF8.self)
        }
        return nil
    }

    private static func extensionMemberName(_ name: String) -> String? {
        let isStatic = name.hasPrefix("static ")
        let declaration = isStatic ? String(name.dropFirst(7)) : name
        guard declaration.hasPrefix("(extension in "),
              let offset = byteOffset(of: "):", in: declaration) else { return nil }
        return (isStatic ? "static " : "")
            + String(decoding: declaration.utf8.dropFirst(offset + 2), as: UTF8.self)
    }

    // Demangler markers are ASCII. Avoid locale-aware substring search on
    // every Swift symbol while retaining the spelling of Unicode identifiers.
    private static func byteOffset(of marker: String, in name: String) -> Int? {
        name.withCString { start in
            marker.withCString { marker in strstr(start, marker).map { start.distance(to: $0) } }
        }
    }

    func resolve(
        _ declaration: NativeDeclaration, source: ResolvedSymbol.Source, extensionsOnly: Bool = false
    ) throws -> ResolvedSymbol? {
        try resolve(SymbolQuery(declaration), source: source, extensionsOnly: extensionsOnly)
    }

    func resolve(
        _ query: SymbolQuery, source: ResolvedSymbol.Source, extensionsOnly: Bool = false
    ) throws -> ResolvedSymbol? {
        let declaration = query.declaration
        let candidates = matches(query, extensionsOnly: extensionsOnly).filter { $0.source == source }
        guard !candidates.isEmpty else { return nil }
        var addresses: [UInt64: (IndexedSymbol, SymbolSection)] = [:]
        for candidate in candidates {
            if candidate.address != 0,
               let section = sections.first(where: { $0.range.contains(candidate.address) }),
               section.accepts(declaration.kind) {
                addresses[candidate.address] = (candidate, section)
            }
        }
        guard !addresses.isEmpty else { throw ABIResolutionError.invalidAddress }
        guard addresses.count == 1, let match = addresses.first?.value else {
            throw ABIResolutionError.ambiguousDeclaration(declaration, candidates: candidates.map(\.name).sorted())
        }
        return ResolvedSymbol(declaration: declaration, image: image, sectionRange: match.1.range,
                              source: match.0.source, address: match.0.address)
    }

    static func slid(_ value: UInt64, by slide: Int64) -> UInt64? {
        if slide >= 0 {
            let result = value.addingReportingOverflow(UInt64(slide))
            return result.overflow ? nil : result.partialValue
        }
        let result = value.subtractingReportingOverflow(slide.magnitude)
        return result.overflow ? nil : result.partialValue
    }
}
