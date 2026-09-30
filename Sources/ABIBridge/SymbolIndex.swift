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

// Coverage describes names read from a source, independently of symbol kind.
// A filtered scan must not mark other names or owners as already loaded.
enum SymbolCandidateScope: Hashable {
    case exact([UInt8])
    case language(NativeLanguage)
    case swiftModule(String)
    case swiftFallback
    case cxxOwner(String)
}

struct SymbolQuery {
    let declaration: NativeDeclaration
    let exactName: String?
    let key: [UInt8]
    let fingerprint: Int
    let filter: CXXSymbolFilter?
    let swiftModule: SwiftModuleFilter?
    let candidateScope: SymbolCandidateScope
    private let exactNeedle: [CChar]
    private let prefixes: [[CChar]]

    init(_ declaration: NativeDeclaration) {
        self.declaration = declaration
        swiftModule = declaration.language == .swift && declaration.nameForm == .source ? SwiftModuleFilter(declaration.name) : nil
        if declaration.nameForm != .source || declaration.language == .c {
            let name = declaration.nameForm == .machO ? declaration.name : "_" + declaration.name
            exactName = name
            key = Array(name.utf8)
            fingerprint = 0
            filter = nil
            candidateScope = .exact(key)
            exactNeedle = key.contains(0) ? [] : Array(name.utf8CString)
        } else {
            exactName = nil
            key = DeclarationKey.make(declaration.name)
            fingerprint = DeclarationKey.fingerprint(key)
            filter = declaration.language == .cxx ? CXXSymbolFilter(declaration.name) : nil
            if let module = swiftModule?.module { candidateScope = .swiftModule(module) }
            else if let owner = filter?.fragments.first { candidateScope = .cxxOwner(owner) }
            else { candidateScope = .language(declaration.language) }
            exactNeedle = []
        }
        prefixes = DeclarationKey.symbolPrefixes(for: declaration.language).map { Array($0.utf8CString) }
    }

    func acceptsCandidate(_ raw: UnsafePointer<CChar>) -> Bool {
        if exactName != nil {
            return !exactNeedle.isEmpty && exactNeedle.withUnsafeBufferPointer { strcmp(raw, $0.baseAddress!) == 0 }
        }
        guard prefixes.contains(where: { prefix in
            prefix.withUnsafeBufferPointer { strncmp(raw, $0.baseAddress!, $0.count - 1) == 0 }
        }) else { return false }
        return (swiftModule?.matches(raw) ?? true) && (filter?.matchesOwner(raw) ?? true)
    }
}

/// Rejects only an explicitly spelled, different root module. Compressed,
/// substituted and other mangling forms still reach the full demangler.
struct SwiftModuleFilter {
    let module: String
    private let prefix: String

    init?(_ declaration: String) {
        var name = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["nominal type descriptor for ", "type metadata accessor for ", "type metadata for ", "static "] {
            if name.hasPrefix(marker) { name.removeFirst(marker.count); break }
        }
        guard let dot = name.firstIndex(of: ".") else { return nil }
        let module = String(name[..<dot])
        guard module.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return nil }
        self.module = module
        prefix = String(module.utf8.count) + module
    }

    // Nil also describes an incomplete trie edge. Only a literal root can be
    // excluded from the conservative bucket without interpreting substitutions.
    static func literalModulePrefix(_ name: UnsafePointer<CChar>) -> Bool? {
        var body = name
        if body.pointee == 95 { body += 1 }
        guard body.pointee == 36, body[1] == 115 || body[1] == 83 else { return nil }
        body += 2
        guard body.pointee != 0 else { return nil }
        return body.pointee >= 49 && body.pointee <= 57
    }

    func matches(_ raw: String) -> Bool {
        raw.withCString { matches($0) }
    }

    func matches(_ name: UnsafePointer<CChar>, partial: Bool = false) -> Bool {
        var body = name
        if body.pointee == 95 { body += 1 }
        guard body.pointee == 36, body[1] == 115 || body[1] == 83 else { return true }
        body += 2
        guard body.pointee >= 49 && body.pointee <= 57 else { return true }
        return prefix.withCString { expected in
            let count = partial ? min(strlen(body), prefix.utf8.count) : prefix.utf8.count
            return strncmp(body, expected, count) == 0
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
        rawName.withCString { matchesOwner($0) }
    }

    func matchesOwner(_ raw: UnsafePointer<CChar>) -> Bool {
        guard let needle = needles.first else { return true }
        return needle.withUnsafeBufferPointer { strstr(raw, $0.baseAddress!) != nil }
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
    private var swiftTableIndices: [Int]?
    private var sourceSymbols: [SymbolCandidateScope: [IndexedSymbol]] = [:]
    private var sharedCacheScopes: Set<SymbolCandidateScope> = []
    private enum SwiftBucket { case literal, fallback }
    private struct Scope: Hashable, Sendable {
        let language: NativeLanguage
        let fragments: [String]
        let swiftFallback: Bool
    }
    private static let swiftFallbackScope = Scope(language: .swift, fragments: [], swiftFallback: true)
    private var decoded: [Scope: [Int: [IndexedSymbol]]] = [:]
    private var linkerNames: [[UInt8]: [IndexedSymbol]] = [:]
    private var swiftExtensions: [Scope: [Int: [IndexedSymbol]]] = [:]

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

    var hasSharedSwiftFallback: Bool {
        sharedCacheScopes.contains(.swiftFallback) || sharedCacheScopes.contains(.language(.swift))
    }

    func hasSharedCacheSymbols(for query: SymbolQuery) -> Bool {
        if sharedCacheScopes.contains(query.candidateScope) { return true }
        switch query.candidateScope {
        case .swiftModule: return sharedCacheScopes.contains(.language(.swift))
        case .cxxOwner: return sharedCacheScopes.contains(.language(.cxx))
        case .exact(let name):
            if hasSharedSwiftFallback, query.exactName?.withCString({ SwiftModuleFilter.literalModulePrefix($0) == false }) == true { return true }
            return [NativeLanguage.swift, .cxx].contains { language in
                sharedCacheScopes.contains(.language(language))
                    && DeclarationKey.symbolPrefixes(for: language).contains { name.starts(with: $0.utf8) }
            }
        default: return false
        }
    }

    func appendSharedCacheSymbols(_ more: [IndexedSymbol], matching query: SymbolQuery) {
        let hasFallback = hasSharedSwiftFallback
        // The first Swift module read already includes all uncertain roots.
        // Concurrent or broader reads must not append that same payload again.
        let additions = hasFallback ? more.filter {
            $0.name.withCString { SwiftModuleFilter.literalModulePrefix($0) != false }
        } : more
        let changesFallback = !hasFallback && additions.contains {
            $0.name.withCString { SwiftModuleFilter.literalModulePrefix($0) == false }
        }
        sharedCacheScopes.insert(query.candidateScope)
        switch query.candidateScope {
        case .swiftModule, .language(.swift): sharedCacheScopes.insert(.swiftFallback)
        default: break
        }
        guard !additions.isEmpty else { return }
        let fallback = (sourceSymbols[.swiftFallback], decoded[Self.swiftFallbackScope], swiftExtensions[Self.swiftFallbackScope])
        localSymbols += additions
        sourceSymbols.removeAll()
        decoded.removeAll()
        swiftExtensions.removeAll()
        linkerNames.removeAll()
        if !changesFallback {
            sourceSymbols[.swiftFallback] = fallback.0
            decoded[Self.swiftFallbackScope] = fallback.1
            swiftExtensions[Self.swiftFallbackScope] = fallback.2
        }
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

    // Keep offsets rather than names: another module can reuse the language
    // scan without materializing unrelated strings or pinning a second copy.
    private func swiftSymbols(matching predicate: (UnsafePointer<CChar>) -> Bool) -> [IndexedSymbol] {
        guard let table = macho.symbols64 else { return tableSymbols(matching: predicate) }
        if swiftTableIndices == nil {
            var indexes: [Int] = []
            for index in 0..<table.numberOfSymbols {
                let entry = table.symbols[index]
                guard Int32(entry.n_type) & N_TYPE == N_SECT else { continue }
                let name = table.stringBase.advanced(by: Int(entry.n_un.n_strx))
                var prefix = name
                if prefix.pointee == 95 { prefix += 1 }
                if prefix.pointee == 36 && (prefix[1] == 115 || prefix[1] == 83) { indexes.append(index) }
            }
            swiftTableIndices = indexes
        }
        return swiftTableIndices!.compactMap { index in
            let entry = table.symbols[index]
            let name = table.stringBase.advanced(by: Int(entry.n_un.n_strx))
            guard predicate(name) else { return nil }
            return imageSymbol(name: String(cString: name), offset: table.addressStart + Int(entry.n_value))
        }
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

    private func symbols(for query: SymbolQuery, swiftBucket: SwiftBucket?) -> [IndexedSymbol] {
        let scope = swiftBucket == .fallback ? SymbolCandidateScope.swiftFallback : query.candidateScope
        if let cached = sourceSymbols[scope] { return cached }
        let prefixes = DeclarationKey.symbolPrefixes(for: query.declaration.language)
        let accepts: (UnsafePointer<CChar>) -> Bool = { raw in
            guard query.acceptsCandidate(raw) else { return false }
            guard let swiftBucket else { return true }
            return SwiftModuleFilter.literalModulePrefix(raw) == (swiftBucket == .literal)
        }
        var symbols = query.declaration.language == .swift
            ? swiftSymbols(matching: accepts) : tableSymbols(matching: accepts)
        if let trie = exportTrie {
            symbols += filteredExports(in: trie, prefixes: prefixes, query: query, swiftBucket: swiftBucket, accepts: accepts)
        }
        symbols += localSymbols.filter { $0.name.withCString(accepts) }
        // Definitions commonly occur in both nlist and the export trie.
        // Demangle each distinct spelling/address/source only once.
        var seen = Set<IndexedSymbol>()
        symbols = symbols.filter { seen.insert($0).inserted }
        sourceSymbols[scope] = symbols
        return symbols
    }

    // An owner substring can occur later in a C++ name, so only Swift's proven
    // module prefix may prune a subtree. Other filters apply at terminals.
    private func filteredExports(in trie: MachOImage.ExportTrie, prefixes: [String], query: SymbolQuery,
                                 swiftBucket: SwiftBucket?, accepts: (UnsafePointer<CChar>) -> Bool) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        var pending = [(name: "", offset: 0)]
        while let entry = pending.popLast() {
            var offset = entry.offset
            guard let node = TrieNode<ExportTrieNodeContent>.readNext(
                basePointer: trie.basePointer.assumingMemoryBound(to: UInt8.self),
                trieSize: trie.exportSize, nextOffset: &offset
            ) else { continue }
            if let value = node.content?.symbolOffset,
               entry.name.withCString(accepts),
               let symbol = imageSymbol(name: entry.name, offset: Int(bitPattern: value)) {
                symbols.append(symbol)
            }
            for child in node.children {
                let name = entry.name + child.label
                guard prefixes.contains(where: { name.hasPrefix($0) || $0.hasPrefix(name) }),
                      name.withCString({ query.swiftModule?.matches($0, partial: true) ?? true }),
                      let next = Int(exactly: child.offset) else { continue }
                if let swiftBucket, let literal = name.withCString(SwiftModuleFilter.literalModulePrefix),
                   literal != (swiftBucket == .literal) { continue }
                pending.append((name, next))
            }
        }
        return symbols
    }

    func matches(_ declaration: NativeDeclaration, extensionsOnly: Bool = false) -> [IndexedSymbol] {
        var unsupported: ABIResolutionError?
        return matches(SymbolQuery(declaration), extensionsOnly: extensionsOnly, unsupported: &unsupported)
    }

    private func matches(_ query: SymbolQuery, extensionsOnly: Bool, genericContext: SwiftGenericContext? = nil,
                         unsupported: inout ABIResolutionError?) -> [IndexedSymbol] {
        let declaration = query.declaration
        if let name = query.exactName {
            return exactSymbols(named: name, key: query.key)
        }
        if declaration.language == .swift {
            return indexedMatches(query, extensionsOnly: extensionsOnly, swiftBucket: .literal, genericContext: genericContext, unsupported: &unsupported)
                + indexedMatches(query, extensionsOnly: extensionsOnly, swiftBucket: .fallback, genericContext: genericContext, unsupported: &unsupported)
        }
        return indexedMatches(query, extensionsOnly: extensionsOnly, swiftBucket: nil, genericContext: genericContext, unsupported: &unsupported)
    }

    private func indexedMatches(_ query: SymbolQuery, extensionsOnly: Bool, swiftBucket: SwiftBucket?,
                                genericContext: SwiftGenericContext?, unsupported: inout ABIResolutionError?) -> [IndexedSymbol] {
        let declaration = query.declaration
        let filter = query.filter
        let scope = swiftBucket == .fallback ? Self.swiftFallbackScope
            : Scope(language: declaration.language, fragments: filter?.fragments ?? query.swiftModule.map { [$0.module] } ?? [], swiftFallback: false)
        if extensionsOnly, let extensions = swiftExtensions[scope] {
            return Self.matching(extensions[query.fingerprint] ?? [], query: query, extensionsOnly: true, genericContext: genericContext, unsupported: &unsupported)
        }
        if decoded[scope] == nil {
            let candidates = symbols(for: query, swiftBucket: swiftBucket)
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
                        if let constrained = SwiftConstrainedExtension(unqualified) {
                            extensions[DeclarationKey.fingerprint(DeclarationKey.make(constrained.memberName)), default: []].append(symbol)
                        }
                    }
                }
            }
            if !extensionsOnly { decoded[scope] = index }
            if declaration.language == .swift { swiftExtensions[scope] = extensions }
        }
        let candidates = extensionsOnly ? swiftExtensions[scope]?[query.fingerprint] ?? [] : decoded[scope]?[query.fingerprint] ?? []
        return Self.matching(candidates, query: query, extensionsOnly: extensionsOnly, genericContext: genericContext, unsupported: &unsupported)
    }

    // Fingerprints keep the index compact; the full normalized spelling is
    // always checked before a candidate can affect resolution or ambiguity.
    static func matching(_ candidates: [IndexedSymbol], query: SymbolQuery, extensionsOnly: Bool,
                         genericContext: SwiftGenericContext? = nil, unsupported: inout ABIResolutionError?) -> [IndexedSymbol] {
        candidates.filter { symbol in
            guard let name = DeclarationKey.demangle(symbol.name, language: query.declaration.language) else { return false }
            var names = [name]
            if query.declaration.language == .swift, let alias = operatorAlias(name) { names.append(alias) }
            return names.contains { name in
                if extensionsOnly {
                    guard let unqualified = extensionMemberName(name) else { return false }
                    if DeclarationKey.make(unqualified) == query.key { return true }
                    guard let constrained = SwiftConstrainedExtension(unqualified),
                          DeclarationKey.make(constrained.memberName) == query.key else { return false }
                    guard let genericContext else {
                        unsupported = .unsupportedDeclaration("No generic receiver context establishes \(unqualified).")
                        return false
                    }
                    do throws(ABIResolutionError) {
                        return try genericContext.satisfies(constrained) {
                            dependentType($0, requirement: $1, in: symbol.name, extensionMember: constrained)
                        }
                    }
                    catch { unsupported = error; return false }
                }
                return DeclarationKey.make(name) == query.key
            }
        }
    }

    private static let dependentMember = try! NSRegularExpression(
        pattern: "Q(?:[zZxX]|[yY](?:[zs]|d[0-9]*_[0-9]*_|[0-9]*_))"
    )
    private static let genericParameter = try! NSRegularExpression(
        pattern: "x|q(?:[zs]|d[0-9]*_[0-9]*_|[0-9]*_)"
    )

    private static func dependentType(_ reference: String, requirement: String, in mangled: String,
                                      extensionMember: SwiftConstrainedExtension) -> Bool {
        var context: String?
        for index in mangled.indices where mangled[index] == "E" {
            let prefix = String(mangled[...index])
            guard let declaration = DeclarationKey.demangle(prefix + "1fyyF", language: .swift),
                  let unqualified = extensionMemberName(declaration),
                  let parsed = SwiftConstrainedExtension(unqualified),
                  parsed.owner == extensionMember.owner, parsed.requirements == extensionMember.requirements else { continue }
            context = prefix
            break
        }
        guard let context else { return true }
        guard let requirementIndex = extensionMember.requirements.firstIndex(of: requirement) else { return true }
        let head = reference.prefix { $0 != "." }
        let newHead = head == "A" ? "B" : "A"
        let components = reference.split(separator: ".")
        guard components.count > 1 else { return true }
        let references = (2...components.count).map { components.prefix($0).joined(separator: ".") }
        func changesRequirement(_ prefix: String, suffix: Substring) -> Bool {
            guard let declaration = DeclarationKey.demangle(prefix + suffix + "1fyyF", language: .swift),
                  let unqualified = extensionMemberName(declaration),
                  let parsed = SwiftConstrainedExtension(unqualified), parsed.owner == extensionMember.owner,
                  parsed.requirements.count == extensionMember.requirements.count else { return false }
            let old = requirement.components(separatedBy: "==")
            let changed = parsed.requirements[requirementIndex].components(separatedBy: "==")
            return old.count == 2 && changed.count == 2 && old[0] == changed[0] && old[1] != changed[1]
        }
        // A parameter can appear under a metatype or other type constructor
        // without a dependent-member operator. Validate the parameter prefix
        // and establish that changing it changes this requirement's RHS.
        for match in genericParameter.matches(in: context, range: NSRange(context.startIndex..., in: context)) {
            guard let range = Range(match.range, in: context),
                  let before = DeclarationKey.demangle(String(context[..<range.upperBound]) + "D", language: .swift),
                  before.hasSuffix(head) else { continue }
            let altered = String(context[..<range.lowerBound]) + (head == "A" ? "q_" : "x")
            guard let after = DeclarationKey.demangle(altered + "D", language: .swift),
                  after.hasSuffix(newHead), before.dropLast(head.count) == after.dropLast(newHead.count),
                  changesRequirement(altered, suffix: context[range.upperBound...]) else { continue }
            return true
        }
        // Swift's mangling ABI uses Q operators for dependent members. Ask the
        // demangler to validate type prefixes so text inside an identifier cannot
        // imitate an operator. Changing its parameter must change only this type.
        for match in dependentMember.matches(in: context, range: NSRange(context.startIndex..., in: context)) {
            guard let range = Range(match.range, in: context),
                  let before = DeclarationKey.demangle(String(context[..<range.upperBound]) + "D", language: .swift),
                  references.contains(where: before.hasSuffix) else { continue }
            let code = context[range].dropFirst().first!
            let chain = code == "Y" || code == "Z" || code == "X"
            let replacement = head == "A" ? (chain ? "QY_" : "Qy_") : (chain ? "QZ" : "Qz")
            let altered = String(context[..<range.lowerBound]) + replacement
            guard let after = DeclarationKey.demangle(altered + "D", language: .swift) else { continue }
            for candidate in references where before.hasSuffix(candidate) {
                let changed = newHead + candidate.dropFirst(head.count)
                guard after.hasSuffix(changed) else { continue }
                let prefix = before.dropLast(candidate.count)
                let newPrefix = after.dropLast(changed.count)
                if prefix == newPrefix, changesRequirement(altered, suffix: context[range.upperBound...]) { return true }
                if code == "x" || code == "X", newPrefix == prefix + head {
                    let bases = genericParameter.matches(in: context, range: NSRange(context.startIndex..<range.lowerBound, in: context))
                    for base in bases {
                        guard let baseRange = Range(base.range, in: context) else { continue }
                        let value = head == "A" ? "q_" : "x"
                        let altered = String(context[..<baseRange.lowerBound]) + value + context[baseRange.upperBound..<range.upperBound]
                        guard let result = DeclarationKey.demangle(altered + "D", language: .swift), result.hasSuffix(changed),
                              before.dropLast(candidate.count) == result.dropLast(changed.count),
                              changesRequirement(altered, suffix: context[range.upperBound...]) else { continue }
                        return true
                    }
                }
            }
        }
        return false
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

    func swiftNominalTypeName(
        at address: UInt64, matching query: SymbolQuery, source: ResolvedSymbol.Source
    ) throws -> String? {
        let candidates = query.swiftModule == nil
            ? symbols(for: query, swiftBucket: nil)
            : symbols(for: query, swiftBucket: .literal) + symbols(for: query, swiftBucket: .fallback)
        let marker = "nominal type descriptor for "
        var names = Set<String>()
        for candidate in candidates where candidate.address == address && candidate.source == source {
            guard let name = DeclarationKey.demangle(candidate.name, language: .swift),
                  name.hasPrefix(marker) else { continue }
            names.insert(String(name.dropFirst(marker.count)))
        }
        guard names.count <= 1 else {
            throw ABIResolutionError.ambiguousDeclaration(query.declaration, candidates: names.sorted())
        }
        return names.first
    }

    func resolve(
        _ declaration: NativeDeclaration, source: ResolvedSymbol.Source, extensionsOnly: Bool = false
    ) throws -> ResolvedSymbol? {
        try resolve(SymbolQuery(declaration), source: source, extensionsOnly: extensionsOnly)
    }

    func resolve(
        _ query: SymbolQuery, source: ResolvedSymbol.Source, extensionsOnly: Bool = false,
        genericContext: SwiftGenericContext? = nil
    ) throws -> ResolvedSymbol? {
        let declaration = query.declaration
        var unsupported: ABIResolutionError?
        let candidates = matches(query, extensionsOnly: extensionsOnly, genericContext: genericContext, unsupported: &unsupported).filter { $0.source == source }
        guard !candidates.isEmpty else {
            if let unsupported { throw unsupported }
            return nil
        }
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
                              source: match.0.source, address: match.0.address, linkageName: match.0.name)
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
