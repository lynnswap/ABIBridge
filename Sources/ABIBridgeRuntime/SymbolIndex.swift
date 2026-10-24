import ABIBridgeCore
import Foundation
import Darwin
import MachO
import MachOKit

package struct IndexedSymbol: Hashable {
    package let name: String
    package let address: UInt64
    package let source: RuntimeSymbol.Source

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.address == rhs.address && lhs.source == rhs.source
            && lhs.name.utf8.elementsEqual(rhs.name.utf8)
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(address)
        hasher.combine(source)
    }
}

package struct SymbolSection {
    package let range: Range<UInt64>
    package let code: Bool
    package let vtable: Bool
    package let threadLocal: Bool

    package func accepts(_ kind: RuntimeSymbolKind) -> Bool {
        guard !threadLocal else { return false }
        switch kind {
        case .function: return code
        case .data: return !code
        case .vtable: return vtable
        }
    }
}

package enum DeclarationKey {
    // These are exactly the prefixes accepted by the native demanglers.
    package static func symbolPrefixes(for language: RuntimeLanguage) -> [String] {
        switch language {
        case .cxx: ["__Z", "_Z"]
        case .swift: ["_$s", "_$S", "$s", "$S"]
        default: []
        }
    }

    package static func fingerprint(_ key: [UInt8]) -> Int {
        var hasher = Hasher()
        key.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    package static func make(_ declaration: String, language: RuntimeLanguage) -> [UInt8] {
        make(language == .swift ? canonicalCollections(declaration) : declaration)
    }

    private static let collectionSpelling = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.])Swift\.(Array|Dictionary|Optional)\s*<"#
    )

    // Swift runtime and toolchain demanglers use both nominal and sugared
    // spellings. Normalize only Swift's three language-defined type sugars.
    private static func canonicalCollections(_ source: String) -> String {
        guard source.contains("Swift.") else { return source }
        var remaining = source
        var result = ""
        while let match = collectionSpelling.firstMatch(
            in: remaining,
            range: NSRange(remaining.startIndex..., in: remaining)
        ),
            let range = Range(match.range, in: remaining),
            let kindRange = Range(match.range(at: 1), in: remaining)
        {
            let opening = remaining.index(before: range.upperBound)
            var depth = 0
            var previous: Character?
            var closing: String.Index?
            for index in remaining[opening...].indices {
                let character = remaining[index]
                if character == "<" {
                    depth += 1
                } else if character == ">", previous != "-" {
                    depth -= 1
                    if depth == 0 { closing = index; break }
                }
                previous = character
            }
            guard let closing else { break }
            let fields = SwiftGenericSyntax.split(remaining[range.upperBound..<closing]).map {
                canonicalCollections($0.trimmingCharacters(in: .whitespaces))
            }
            let replacement: String
            switch remaining[kindRange] {
            case "Array" where fields.count == 1: replacement = "[" + fields[0] + "]"
            case "Dictionary" where fields.count == 2:
                replacement = "[" + fields[0] + ": " + fields[1] + "]"
            case "Optional" where fields.count == 1:
                let wrapped = fields[0]
                replacement =
                    (SwiftFormalSyntax.topLevelArrow(in: wrapped) == nil
                        ? wrapped : "(" + wrapped + ")") + "?"
            default: return result + remaining
            }
            result += remaining[..<range.lowerBound] + replacement
            remaining = String(remaining[remaining.index(after: closing)...])
        }
        return result + remaining
    }

    package static func make(_ declaration: String) -> [UInt8] {
        var key: [UInt8] = []
        key.reserveCapacity(declaration.utf8.count * 2)
        var inIdentifier = false
        for byte in declaration.utf8 {
            if (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122) || byte == 95
            {
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

    package static func demangle(_ raw: String, language: RuntimeLanguage) -> String? {
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
package enum SymbolCandidateScope: Hashable {
    case exact([UInt8])
    case language(RuntimeLanguage)
    case swiftModule(String)
    case swiftFallback
    case cxxOwner(String)
}

package struct SymbolQuery {
    package let declaration: RuntimeDeclaration
    package let exactName: String?
    package let key: [UInt8]
    package let fingerprint: Int
    package let filter: CXXSymbolFilter?
    package let swiftModule: SwiftModuleFilter?
    package let candidateScope: SymbolCandidateScope
    private let exactNeedle: [CChar]
    private let prefixes: [[CChar]]

    package init(_ declaration: RuntimeDeclaration) {
        self.init(declaration, module: nil)
    }

    /// - Parameter module: The module whose symbols a Swift source-name query
    ///   reads instead of the declaration's own, such as the module of a
    ///   conforming type, whose name starts the mangling of its witnesses.
    package init(_ declaration: RuntimeDeclaration, module: String?) {
        self.declaration = declaration
        swiftModule =
            declaration.language == .swift && declaration.nameForm == .source
            ? module.flatMap(SwiftModuleFilter.init(module:)) ?? SwiftModuleFilter(declaration.name)
            : nil
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
            key = DeclarationKey.make(declaration.name, language: declaration.language)
            fingerprint = DeclarationKey.fingerprint(key)
            filter = declaration.language == .cxx ? CXXSymbolFilter(declaration.name) : nil
            if let module = swiftModule?.module {
                candidateScope = .swiftModule(module)
            } else if let owner = filter?.fragments.first {
                candidateScope = .cxxOwner(owner)
            } else {
                candidateScope = .language(declaration.language)
            }
            exactNeedle = []
        }
        prefixes = DeclarationKey.symbolPrefixes(for: declaration.language).map {
            Array($0.utf8CString)
        }
    }

    package func acceptsCandidate(_ raw: UnsafePointer<CChar>) -> Bool {
        if exactName != nil {
            return !exactNeedle.isEmpty
                && exactNeedle.withUnsafeBufferPointer { strcmp(raw, $0.baseAddress!) == 0 }
        }
        guard
            prefixes.contains(where: { prefix in
                prefix.withUnsafeBufferPointer { strncmp(raw, $0.baseAddress!, $0.count - 1) == 0 }
            })
        else { return false }
        return (swiftModule?.matches(raw) ?? true) && (filter?.matchesOwner(raw) ?? true)
    }
}

package struct SymbolCandidateMatcher {
    private var storage: [CChar] = [0]
    private var exactOffsets: [Int] = []
    private var ownerOffsets: [Int] = []
    private var allCXX = false
    private var swiftQueries: [SymbolQuery] = []

    package init(_ queries: [SymbolQuery]) {
        for query in queries {
            switch query.candidateScope {
            case .exact(let bytes):
                guard !bytes.contains(0) else { continue }
                exactOffsets.append(storage.count)
                storage += bytes.map { CChar(bitPattern: $0) } + [0]
            case .cxxOwner(let owner):
                ownerOffsets.append(storage.count)
                storage += owner.utf8CString
            case .language(.cxx):
                allCXX = true
            case .swiftModule, .swiftFallback, .language(.swift):
                swiftQueries.append(query)
            default:
                break
            }
        }
    }

    package func withMatcher<Value>(
        _ body: (_ accepts: (UnsafePointer<CChar>) -> Bool) -> Value
    ) -> Value {
        storage.withUnsafeBufferPointer { bytes in
            let strings = bytes.baseAddress!
            return body { name in
                for offset in exactOffsets {
                    if strcmp(name, strings + offset) == 0 { return true }
                }
                if name.pointee == 95,
                    name[1] == 90 || (name[1] == 95 && name[2] == 90)
                {
                    if allCXX { return true }
                    for offset in ownerOffsets {
                        if strstr(name, strings + offset) != nil { return true }
                    }
                    return false
                }
                var swiftName = name
                if swiftName.pointee == 95 { swiftName += 1 }
                guard swiftName.pointee == 36,
                    swiftName[1] == 115 || swiftName[1] == 83
                else { return false }
                return swiftQueries.contains { $0.acceptsCandidate(name) }
            }
        }
    }
}

package struct SwiftModuleFilter {
    package let module: String
    private let prefix: String

    package init?(_ declaration: String) {
        var name = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = [
            "nominal type descriptor for ", "protocol descriptor for ",
            "type metadata accessor for ", "type metadata for ",
            "async function pointer to ", "property descriptor for ",
            "method descriptor for ", "dispatch thunk of ", "static ",
        ]
        while let marker = markers.first(where: { name.hasPrefix($0) }) {
            name.removeFirst(marker.count)
        }
        // An extension's mangling starts with the extended type's module.
        name = SymbolIndex.extensionMemberName(name) ?? name
        guard let dot = name.firstIndex(of: ".") else { return nil }
        self.init(module: String(name[..<dot]))
    }

    package init?(module: String) {
        guard module.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        else { return nil }
        self.module = module
        prefix = String(module.utf8.count) + module
    }

    // Nil also describes an incomplete trie edge. Standard module and type
    // substitutions have known roots; compressed identifiers stay conservative.
    package static func knownModulePrefix(_ name: UnsafePointer<CChar>) -> Bool? {
        var body = name
        if body.pointee == 95 { body += 1 }
        guard body.pointee == 36, body[1] == 115 || body[1] == 83 else { return nil }
        body += 2
        guard body.pointee != 0 else { return nil }
        if body.pointee == 83 { return body[1] == 0 ? nil : true }
        return body.pointee == 115 || (body.pointee >= 49 && body.pointee <= 57)
    }

    package func matches(_ raw: String) -> Bool {
        raw.withCString { matches($0) }
    }

    package func matches(_ name: UnsafePointer<CChar>, partial: Bool = false) -> Bool {
        var body = name
        if body.pointee == 95 { body += 1 }
        guard body.pointee == 36, body[1] == 115 || body[1] == 83 else { return true }
        body += 2
        if body.pointee == 115 { return module == "Swift" }
        if body.pointee == 83 {
            // S alone can be an unfinished trie edge. So and SC are modules;
            // other standard substitutions name types from the Swift module.
            guard body[1] != 0 else { return true }
            if body[1] == 111 { return module == "__C" }
            if body[1] == 67 { return module == "__C_Synthesized" }
            return module == "Swift"
        }
        guard body.pointee >= 49 && body.pointee <= 57 else { return true }
        return prefix.withCString { expected in
            let count = partial ? min(strlen(body), prefix.utf8.count) : prefix.utf8.count
            return strncmp(body, expected, count) == 0
        }
    }
}

package struct CXXSymbolFilter {
    package let fragments: [String]
    private let needles: [[CChar]]

    package init(_ declaration: String) {
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
            prefix.range(
                of: "^(?:[A-Za-z_][A-Za-z0-9_]*::)*~?[A-Za-z_][A-Za-z0-9_]*$",
                options: .regularExpression
            ) != nil
        else {
            fragments = []
            needles = []
            return
        }
        let substitutions: Set<String> = [
            "std", "__1", "allocator", "basic_string", "string",
            "basic_istream", "basic_ostream", "basic_iostream", "istream", "ostream", "iostream",
        ]
        var names = Array(
            prefix.replacingOccurrences(of: "~", with: "")
                .components(separatedBy: "::").suffix(2)
        )
        // Group type metadata and operators with the class's ordinary members.
        if isTypeName { names.reverse() }
        var selected: [String] = []
        for name in names where !substitutions.contains(name) && !selected.contains(name) {
            selected.append(name)
        }
        fragments = selected
        needles = selected.map { Array($0.utf8CString) }
    }

    package func matchesOwner(_ rawName: String) -> Bool {
        rawName.withCString { matchesOwner($0) }
    }

    package func matchesOwner(_ raw: UnsafePointer<CChar>) -> Bool {
        guard let needle = needles.first else { return true }
        return needle.withUnsafeBufferPointer { strstr(raw, $0.baseAddress!) != nil }
    }

    package func matches(_ rawName: String) -> Bool {
        if needles.isEmpty { return true }
        return rawName.withCString { raw in
            needles.allSatisfy { needle in
                needle.withUnsafeBufferPointer { strstr(raw, $0.baseAddress!) != nil }
            }
        }
    }
}

package final class SymbolIndex {
    package let image: RuntimeImage
    package let sections: [SymbolSection]
    private let macho: MachOImage
    private lazy var exportTrie = macho.exportTrie
    private var localSymbols: [IndexedSymbol] = []
    private var swiftTableIndices: [Int]?
    private enum DescriptorKind: UInt8 { case nominalType = 110, protocolType = 112 }
    private struct SourceScope: Hashable {
        let candidates: SymbolCandidateScope
        let descriptorKind: DescriptorKind?
    }
    private var sourceSymbols: [SourceScope: [IndexedSymbol]] = [:]
    // Loaded definitions remain valid when shared-cache locals extend an index.
    private var imageSymbols: [SourceScope: [IndexedSymbol]] = [:]
    private var sharedCacheScopes: Set<SymbolCandidateScope> = []
    private struct SharedCacheScanKey: Hashable {
        let candidates: SymbolCandidateScope
        let source: SharedCacheSymbols.Source
    }
    private var sharedCacheScans: [SharedCacheScanKey: SharedCacheSymbolScan] = [:]
    #if DEBUG
    package var hasSharedCacheWaiters: Bool {
        sharedCacheScans.values.contains { $0.waitingCallerCount > 0 }
    }
    #endif
    private enum SwiftBucket { case knownModule, fallback }
    private struct Scope: Hashable, Sendable {
        let language: RuntimeLanguage
        let fragments: [String]
        let swiftFallback: Bool
    }
    private static let swiftFallbackScope = Scope(
        language: .swift,
        fragments: [],
        swiftFallback: true
    )
    private var decoded: [Scope: [Int: [IndexedSymbol]]] = [:]
    private var linkerNames: [[UInt8]: [IndexedSymbol]] = [:]
    private var imageLinkerNames: [[UInt8]: [IndexedSymbol]] = [:]
    private var swiftMembers: [Scope: [SwiftMemberPath: [IndexedSymbol]]] = [:]
    private var swiftRecords: [IndexedSymbol: RuntimeSwiftDeclaration?] = [:]

    package init(image: RuntimeImage) {
        self.image = image
        let macho = MachOImage(
            ptr: UnsafePointer<mach_header>(bitPattern: UInt(image.identity.headerAddress))!
        )
        self.macho = macho
        let slide = image.identity.slide
        sections = macho.sections.compactMap { section in
            guard section.address >= 0, section.size > 0,
                let start = Self.slid(UInt64(section.address), by: slide),
                UInt64(section.size) <= UInt64.max - start
            else { return nil }
            let threadLocal: Bool
            switch section.flags.type {
            case .some(.thread_local_regular), .some(.thread_local_zerofill),
                .some(.thread_local_variables), .some(.thread_local_variable_pointers),
                .some(.thread_local_init_function_pointers):
                threadLocal = true
            default: threadLocal = false
            }
            return SymbolSection(
                range: start..<(start + UInt64(section.size)),
                code: section.flags.attributes.contains(.pure_instructions)
                    || section.flags.attributes.contains(.some_instructions),
                vtable: section.sectionName == "__const"
                    && (section.segmentName.hasPrefix("__DATA")
                        || section.segmentName.hasPrefix("__AUTH")),
                threadLocal: threadLocal
            )
        }
    }

    package var hasSharedSwiftFallback: Bool {
        sharedCacheScopes.contains(.swiftFallback) || sharedCacheScopes.contains(.language(.swift))
    }

    package func hasSharedCacheSymbols(for query: SymbolQuery) -> Bool {
        if sharedCacheScopes.contains(query.candidateScope) { return true }
        switch query.candidateScope {
        case .swiftModule: return sharedCacheScopes.contains(.language(.swift))
        case .cxxOwner: return sharedCacheScopes.contains(.language(.cxx))
        case .exact(let name):
            if hasSharedSwiftFallback,
                query.exactName?.withCString({ SwiftModuleFilter.knownModulePrefix($0) == false })
                    == true
            {
                return true
            }
            return [RuntimeLanguage.swift, .cxx].contains { language in
                sharedCacheScopes.contains(.language(language))
                    && DeclarationKey.symbolPrefixes(for: language).contains {
                        name.starts(with: $0.utf8)
                    }
            }
        default: return false
        }
    }

    package func sharedCacheScan(
        for query: SymbolQuery,
        source: SharedCacheSymbols.Source,
        includingSwiftFallback: Bool,
        capturing sources: SharedCacheSymbols.CapturedSymbols,
        relatedQueries: [SymbolQuery] = []
    ) -> SharedCacheSymbolScan {
        let key = SharedCacheScanKey(
            candidates: query.candidateScope,
            source: source
        )
        // Fallback coverage only grows within an index, so an existing scan's
        // choice also satisfies callers with an older coverage observation.
        if let scan = sharedCacheScans[key] { return scan }
        let scan = SharedCacheSymbolScan(
            sources: sources,
            query: query,
            includingSwiftFallback: includingSwiftFallback,
            relatedQueries: sources.imageIdentity == image.identity ? relatedQueries : []
        )
        sharedCacheScans[key] = scan
        return scan
    }

    package func removeSharedCacheScans(for query: SymbolQuery) -> [SharedCacheSymbolScan] {
        let keys = sharedCacheScans.keys.filter { $0.candidates == query.candidateScope }
        return keys.compactMap { sharedCacheScans.removeValue(forKey: $0) }
    }

    package func appendSharedCacheSymbols(_ more: [IndexedSymbol], matching query: SymbolQuery) {
        appendSharedCacheSymbols(more, matching: [query])
    }

    package func appendSharedCacheSymbols(_ more: [IndexedSymbol], matching queries: [SymbolQuery])
    {
        let hasFallback = hasSharedSwiftFallback
        // The first Swift module read already includes all uncertain roots.
        // Concurrent or broader reads must not append that same payload again.
        let additions =
            hasFallback
            ? more.filter {
                $0.name.withCString { SwiftModuleFilter.knownModulePrefix($0) != false }
            } : more
        let changesFallback =
            !hasFallback
            && additions.contains {
                $0.name.withCString { SwiftModuleFilter.knownModulePrefix($0) == false }
            }
        for query in queries {
            sharedCacheScopes.insert(query.candidateScope)
            switch query.candidateScope {
            case .swiftModule, .language(.swift): sharedCacheScopes.insert(.swiftFallback)
            default: break
            }
        }
        guard !additions.isEmpty else { return }
        let fallback = (
            sourceSymbols.filter { $0.key.candidates == .swiftFallback },
            decoded[Self.swiftFallbackScope], swiftMembers[Self.swiftFallbackScope]
        )
        localSymbols += additions
        sourceSymbols.removeAll()
        decoded.removeAll()
        swiftMembers.removeAll()
        linkerNames.removeAll()
        if !changesFallback {
            sourceSymbols = fallback.0
            decoded[Self.swiftFallbackScope] = fallback.1
            swiftMembers[Self.swiftFallbackScope] = fallback.2
        }
    }

    private func imageSymbol(name: String, offset: Int) -> IndexedSymbol? {
        let base = image.identity.headerAddress
        guard offset >= 0, UInt64(offset) <= UInt64.max - base else { return nil }
        return IndexedSymbol(name: name, address: base + UInt64(offset), source: .image)
    }

    private func tableSymbols(matching predicate: (UnsafePointer<CChar>) -> Bool) -> [IndexedSymbol]
    {
        if let table = macho.symbols64 {
            var result: [IndexedSymbol] = []
            var index = 0
            while index < table.numberOfSymbols {
                let entry = table.symbols[index]
                index += 1
                guard Int32(entry.n_type) & N_TYPE == N_SECT else { continue }
                let name = table.stringBase.advanced(by: Int(entry.n_un.n_strx))
                guard predicate(name) else { continue }
                if let symbol = imageSymbol(
                    name: String(cString: name),
                    offset: table.addressStart + Int(entry.n_value)
                ) {
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
    private func swiftSymbols(matching predicate: (UnsafePointer<CChar>) -> Bool) -> [IndexedSymbol]
    {
        guard let table = macho.symbols64 else { return tableSymbols(matching: predicate) }
        if swiftTableIndices == nil {
            var indexes: [Int] = []
            for index in 0..<table.numberOfSymbols {
                let entry = table.symbols[index]
                guard Int32(entry.n_type) & N_TYPE == N_SECT else { continue }
                let name = table.stringBase.advanced(by: Int(entry.n_un.n_strx))
                var prefix = name
                if prefix.pointee == 95 { prefix += 1 }
                if prefix.pointee == 36 && (prefix[1] == 115 || prefix[1] == 83) {
                    indexes.append(index)
                }
            }
            swiftTableIndices = indexes
        }
        return swiftTableIndices!.compactMap { index in
            let entry = table.symbols[index]
            let name = table.stringBase.advanced(by: Int(entry.n_un.n_strx))
            guard predicate(name) else { return nil }
            return imageSymbol(
                name: String(cString: name),
                offset: table.addressStart + Int(entry.n_value)
            )
        }
    }

    private func exactSymbols(named name: String, key: [UInt8]) -> [IndexedSymbol] {
        guard !key.contains(0) else { return [] }
        if let cached = linkerNames[key] { return cached }
        var matches: [IndexedSymbol]
        if let cached = imageLinkerNames[key] {
            matches = cached
        } else {
            matches = name.withCString { name in tableSymbols { strcmp($0, name) == 0 } }
            if let offset = exportedOffset(named: key),
                let symbol = imageSymbol(name: name, offset: offset)
            {
                matches.append(symbol)
            }
            imageLinkerNames[key] = matches
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
            guard
                let node = TrieNode<ExportTrieNodeContent>.readNext(
                    basePointer: trie.basePointer.assumingMemoryBound(to: UInt8.self),
                    trieSize: trie.exportSize,
                    nextOffset: &offset
                )
            else { return nil }
            if remaining.isEmpty {
                return node.content?.symbolOffset.map { Int(bitPattern: $0) }
            }
            guard
                let child = node.children.first(where: {
                    !$0.label.isEmpty && remaining.starts(with: $0.label.utf8)
                }), let childOffset = Int(exactly: child.offset)
            else { return nil }
            remaining = remaining.dropFirst(child.label.utf8.count)
            offset = childOffset
        }
        return nil
    }

    /// The symbols this image exports with names starting with `prefix`. The
    /// walk visits only the trie's subtree for the prefix, such as one Swift
    /// declaration or module context.
    package func exportedSymbols(withPrefix prefix: String) -> [IndexedSymbol] {
        guard let trie = exportTrie else { return [] }
        let prefix = Array(prefix.utf8)
        var symbols: [IndexedSymbol] = []
        var pending: [(name: [UInt8], offset: Int)] = [([], 0)]
        while let entry = pending.popLast() {
            var offset = entry.offset
            guard
                let node = TrieNode<ExportTrieNodeContent>.readNext(
                    basePointer: trie.basePointer.assumingMemoryBound(to: UInt8.self),
                    trieSize: trie.exportSize,
                    nextOffset: &offset
                )
            else { continue }
            if entry.name.count >= prefix.count, let value = node.content?.symbolOffset,
                let symbol = imageSymbol(
                    name: String(decoding: entry.name, as: UTF8.self),
                    offset: Int(bitPattern: value)
                )
            {
                symbols.append(symbol)
            }
            for child in node.children {
                let name = entry.name + child.label.utf8
                let shared = min(name.count, prefix.count)
                guard name[..<shared].elementsEqual(prefix[..<shared]),
                    let next = Int(exactly: child.offset)
                else { continue }
                pending.append((name, next))
            }
        }
        return symbols
    }

    /// The declaration, such as `8ProbeLib5PointV`, under which this image
    /// exports the Swift nominal type descriptor at `address`. Nil when the
    /// image exports no such descriptor, or exports it under two names.
    package func exportedSwiftTypeDeclaration(at address: UInt64) -> String? {
        exportedTypeDescriptors.names[address].map(Self.declaration(ofDescriptor:))
    }

    /// The declaration under which this image names the Swift nominal type
    /// descriptor at `address`, in its exports or its symbol table. The
    /// symbol table keeps local symbols, such as the descriptors of private
    /// and local types, until the image is stripped. Nil when neither names
    /// the descriptor, or one names it twice.
    package func swiftTypeDeclaration(at address: UInt64) -> String? {
        swiftTypeDescriptorSymbol(at: address).map(Self.declaration(ofDescriptor:))
    }

    /// The symbol, such as `$s8ProbeLib5PointVMn`, under which this image
    /// names the Swift nominal type descriptor at `address`, in its exports
    /// or its symbol table.
    private func swiftTypeDescriptorSymbol(at address: UInt64) -> String? {
        exportedTypeDescriptors.names[address] ?? tableTypeDescriptors.names[address]
    }

    /// The address of the Swift nominal type descriptor that this image names
    /// `name`, such as `$s8ProbeLib5PointVMn`, in its exports or its symbol
    /// table.
    private func swiftTypeDescriptor(named name: String) -> UInt64? {
        exportedTypeDescriptors.addresses[name] ?? tableTypeDescriptors.addresses[name]
    }

    private static func declaration(ofDescriptor name: String) -> String {
        String(name.dropFirst(2).dropLast(2))
    }

    /// Nominal type descriptor symbols, without their leading underscores.
    /// A name or address that two symbols spell differently is left out.
    private struct TypeDescriptorSymbols {
        var names: [UInt64: String] = [:]
        var addresses: [String: UInt64] = [:]

        init(_ symbols: [IndexedSymbol]) {
            var ambiguousNames: Set<String> = [], ambiguousAddresses: Set<UInt64> = []
            for symbol in symbols where symbol.name.hasPrefix("_$s") && symbol.name.hasSuffix("Mn") {
                let name = String(symbol.name.dropFirst())
                if let other = names.updateValue(name, forKey: symbol.address), other != name {
                    ambiguousAddresses.insert(symbol.address)
                }
                if let other = addresses.updateValue(symbol.address, forKey: name),
                    other != symbol.address
                {
                    ambiguousNames.insert(name)
                }
            }
            for address in ambiguousAddresses { names[address] = nil }
            for name in ambiguousNames { addresses[name] = nil }
        }
    }

    private lazy var exportedTypeDescriptors = TypeDescriptorSymbols(
        exportedSymbols(withPrefix: "_$s")
    )

    // Only the names that end in `Mn` become strings.
    private lazy var tableTypeDescriptors = TypeDescriptorSymbols(
        swiftSymbols { name in
            let count = strlen(name)
            return count > 2 && name[count - 2] == 77 && name[count - 1] == 110
        }
    )

    // MARK: Stored properties

    /// Whether this image holds a trivial property descriptor for a stored
    /// `var` of a struct or class that `module` declares: a `…vpMV` symbol,
    /// in the exports or the symbol table, whose first word is 0 and whose
    /// type's field records mark the property as a `var`. A type declared in
    /// an extension belongs to the extension's module.
    package func hasTrivialStoredVariableDescriptor(declaredBy module: String) -> Bool {
        if let cached = trivialStoredVariableModules[module] { return cached }
        let found = trivialPropertyDescriptors.contains { property in
            guard property.module == module, !property.isStatic,
                let address = swiftTypeDescriptor(named: property.typeDescriptor),
                let descriptor = UnsafeRawPointer(bitPattern: UInt(address))
            else { return false }
            return ABISwiftDescriptorStoredProperty(descriptor, property.name)
                == ABISwiftStoredPropertyVar
        }
        trivialStoredVariableModules[module] = found
        return found
    }

    private var trivialStoredVariableModules: [String: Bool] = [:]

    // Swift mangles a property descriptor with the suffix `MV`. A trivial
    // descriptor's first word, its key-path component header, is 0.
    private lazy var trivialPropertyDescriptors: [RuntimeSwiftPropertySymbol] =
        swiftSymbols(endingWith: (77, 86)).compactMap { symbol in
            guard symbol.name.hasSuffix("vpMV"),
                let descriptor = UnsafeRawPointer(bitPattern: UInt(symbol.address)),
                descriptor.loadUnaligned(as: UInt32.self) == 0,
                let property = RuntimeSwiftPropertySymbol(linkageName: symbol.name),
                property.isDescriptor
            else { return nil }
            return property
        }

    /// The instance properties of the struct, enum, or class whose nominal
    /// type descriptor is at `address` that a symbol in this image's exports
    /// or symbol table spells: a property descriptor, an accessor, or a
    /// variable initializer. Each is mapped to whether a spelled declared type
    /// contains an opaque type. Empty when the image does not name the
    /// descriptor.
    package func swiftPropertyDeclarations(ofTypeAt address: UInt64) -> [String: Bool] {
        if let cached = propertyDeclarations[address] { return cached }
        var result: [String: Bool] = [:]
        if let descriptor = swiftTypeDescriptorSymbol(at: address) {
            // A member's symbols start with its type's context, which the
            // descriptor's symbol spells before its suffix; their trees
            // decide which ones belong to the type.
            let prefix = "_" + descriptor.dropLast(2)
            let bytes = Array(prefix.utf8CString)
            let table = swiftSymbols { name in strncmp(name, bytes, bytes.count - 1) == 0 }
            let exports = exportedSymbols(withPrefix: prefix)
            for symbol in Set(table + exports) {
                guard let property = RuntimeSwiftPropertySymbol(linkageName: symbol.name),
                    !property.isStatic, property.typeDescriptor == descriptor
                else { continue }
                result[property.name, default: false] =
                    result[property.name, default: false] || property.declaresOpaqueType
            }
        }
        propertyDeclarations[address] = result
        return result
    }

    private var propertyDeclarations: [UInt64: [String: Bool]] = [:]

    private func symbols(
        for query: SymbolQuery,
        swiftBucket: SwiftBucket?,
        descriptorKind: DescriptorKind? = nil
    ) -> [IndexedSymbol] {
        let scope = SourceScope(
            candidates: swiftBucket == .fallback ? .swiftFallback : query.candidateScope,
            descriptorKind: descriptorKind
        )
        if let cached = sourceSymbols[scope] { return cached }
        let prefixes = DeclarationKey.symbolPrefixes(for: query.declaration.language)
        let accepts: (UnsafePointer<CChar>) -> Bool = { raw in
            if let descriptorKind {
                let count = strlen(raw)
                guard count >= 2, raw[count - 2] == 77,
                    raw[count - 1] == CChar(descriptorKind.rawValue)
                else { return false }
            }
            guard query.acceptsCandidate(raw) else { return false }
            guard let swiftBucket else { return true }
            return SwiftModuleFilter.knownModulePrefix(raw) == (swiftBucket == .knownModule)
        }
        var symbols: [IndexedSymbol]
        if let cached = imageSymbols[scope] {
            symbols = cached
        } else {
            symbols =
                query.declaration.language == .swift && descriptorKind == nil
                ? swiftSymbols(matching: accepts) : tableSymbols(matching: accepts)
            if let trie = exportTrie {
                symbols += filteredExports(
                    in: trie,
                    prefixes: prefixes,
                    query: query,
                    swiftBucket: swiftBucket,
                    accepts: accepts
                )
            }
            imageSymbols[scope] = symbols
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
    // known module prefix may prune a subtree. Other filters apply at terminals.
    private func filteredExports(
        in trie: MachOImage.ExportTrie,
        prefixes: [String],
        query: SymbolQuery,
        swiftBucket: SwiftBucket?,
        accepts: (UnsafePointer<CChar>) -> Bool
    ) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        var pending = [(name: "", offset: 0)]
        while let entry = pending.popLast() {
            var offset = entry.offset
            guard
                let node = TrieNode<ExportTrieNodeContent>.readNext(
                    basePointer: trie.basePointer.assumingMemoryBound(to: UInt8.self),
                    trieSize: trie.exportSize,
                    nextOffset: &offset
                )
            else { continue }
            if let value = node.content?.symbolOffset,
                entry.name.withCString(accepts),
                let symbol = imageSymbol(name: entry.name, offset: Int(bitPattern: value))
            {
                symbols.append(symbol)
            }
            for child in node.children {
                let name = entry.name + child.label
                guard prefixes.contains(where: { name.hasPrefix($0) || $0.hasPrefix(name) }),
                    name.withCString({ query.swiftModule?.matches($0, partial: true) ?? true }),
                    let next = Int(exactly: child.offset)
                else { continue }
                if let swiftBucket,
                    let known = name.withCString(SwiftModuleFilter.knownModulePrefix),
                    known != (swiftBucket == .knownModule)
                {
                    continue
                }
                pending.append((name, next))
            }
        }
        return symbols
    }

    package func matches(_ declaration: RuntimeDeclaration) -> [IndexedSymbol] {
        matches(SymbolQuery(declaration))
    }

    private func matches(_ query: SymbolQuery) -> [IndexedSymbol] {
        let declaration = query.declaration
        if let name = query.exactName {
            return exactSymbols(named: name, key: query.key)
        }
        if declaration.language == .swift {
            let name = declaration.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let descriptor: DescriptorKind? =
                name.hasPrefix("protocol descriptor for ")
                ? .protocolType
                : name.hasPrefix("nominal type descriptor for ") ? .nominalType : nil
            if let descriptor {
                // Mp and Mn identify descriptors in Swift's stable mangling.
                // Descriptor coverage must not hide later ordinary declarations.
                let candidates =
                    symbols(for: query, swiftBucket: .knownModule, descriptorKind: descriptor)
                    + symbols(for: query, swiftBucket: .fallback, descriptorKind: descriptor)
                return Self.matching(candidates, query: query)
            }
            return indexedMatches(query, swiftBucket: .knownModule)
                + indexedMatches(query, swiftBucket: .fallback)
        }
        return indexedMatches(query, swiftBucket: nil)
    }

    private func indexedMatches(
        _ query: SymbolQuery,
        swiftBucket: SwiftBucket?
    ) -> [IndexedSymbol] {
        let declaration = query.declaration
        let filter = query.filter
        let scope =
            swiftBucket == .fallback
            ? Self.swiftFallbackScope
            : Scope(
                language: declaration.language,
                fragments: filter?.fragments ?? query.swiftModule.map { [$0.module] } ?? [],
                swiftFallback: false
            )
        if decoded[scope] == nil {
            let candidates = symbols(for: query, swiftBucket: swiftBucket)
            var index: [Int: [IndexedSymbol]] = [:]
            for symbol in candidates {
                guard filter?.matches(symbol.name) ?? true else { continue }
                guard
                    let name = DeclarationKey.demangle(symbol.name, language: declaration.language)
                else { continue }
                var names = [name]
                if declaration.language == .swift {
                    if let alias = Self.operatorAlias(name) { names.append(alias) }
                    if let alias = Self.nominalDescriptorAlias(name) { names.append(alias) }
                }
                for name in names {
                    index[
                        DeclarationKey.fingerprint(
                            DeclarationKey.make(name, language: declaration.language)
                        ),
                        default: []
                    ].append(symbol)
                }
            }
            decoded[scope] = index
        }
        return Self.matching(decoded[scope]?[query.fingerprint] ?? [], query: query)
    }

    /// The candidates of the member that the query's declaration spells.
    package func swiftDeclarationCandidates(
        _ query: SymbolQuery,
        source: RuntimeSymbol.Source,
        extensionsOnly: Bool
    ) -> [RuntimeSwiftCandidate] {
        guard let match = SwiftMemberMatch(declaration: query.declaration.name) else { return [] }
        return swiftDeclarationCandidates(
            match,
            query: query,
            source: source,
            extensionsOnly: extensionsOnly
        )
    }

    // A dispatch thunk is keyed by the member it dispatches, so one query
    // returns a declaration's code and its thunk together. A conformance's
    // witness is keyed by the requirement it serves. The path selects the
    // symbols, and their records decide whether each declares the member.
    package func swiftDeclarationCandidates(
        _ match: SwiftMemberMatch,
        query: SymbolQuery,
        source: RuntimeSymbol.Source,
        extensionsOnly: Bool
    ) -> [RuntimeSwiftCandidate] {
        var symbols: [IndexedSymbol] = []
        for bucket in [SwiftBucket.knownModule, .fallback] {
            let scope =
                bucket == .fallback
                ? Self.swiftFallbackScope
                : Scope(
                    language: .swift,
                    fragments: query.swiftModule.map { [$0.module] } ?? [],
                    swiftFallback: false
                )
            if swiftMembers[scope] == nil {
                var members: [SwiftMemberPath: [IndexedSymbol]] = [:]
                for symbol in self.symbols(for: query, swiftBucket: bucket) {
                    guard let name = memberName(of: symbol) else { continue }
                    for name in [name, Self.operatorAlias(name)].compactMap({ $0 }) {
                        guard let path = SwiftMemberPath(declaration: name) else { continue }
                        members[path, default: []].append(symbol)
                    }
                }
                swiftMembers[scope] = members
            }
            symbols += swiftMembers[scope]?[match.path] ?? []
        }
        var addresses: Set<UInt64> = []
        var witnesses: Set<IndexedSymbol> = []
        return symbols.compactMap { symbol in
            guard symbol.source == source,
                let record = record(of: symbol),
                extensionsOnly == record.context.isExtension,
                match.accepts(record),
                let name = memberName(of: symbol),
                let section = sections.first(where: { $0.range.contains(symbol.address) }),
                section.accepts(query.declaration.kind),
                let spelling = DeclarationKey.demangle(symbol.name, language: .swift)
            else { return nil }
            // A linker folds identical witness thunks of different
            // conformances into one address. Each still serves its own
            // conformance, which selection compares.
            if case .witness = record.role {
                guard witnesses.insert(symbol).inserted else { return nil }
            } else {
                guard addresses.insert(symbol.address).inserted else { return nil }
            }
            return candidate(
                symbol,
                record: record,
                name: name,
                spelling: spelling,
                section: section,
                kind: query.declaration.kind
            )
        }
    }

    /// The witnesses that this image's symbol table holds for the
    /// conformance whose descriptor is at `descriptor`.
    package func swiftWitnesses(ofConformanceAt descriptor: UInt64) -> [RuntimeSwiftCandidate] {
        guard let names = conformanceDescriptors.byAddress[descriptor] else { return [] }
        // Swift mangles a witness with the suffix `TW`.
        let symbols = swiftSymbols { name in
            let length = strlen(name)
            return length > 2 && name[length - 2] == 84 && name[length - 1] == 87
        }
        return symbols.compactMap { symbol in
            guard let record = record(of: symbol),
                case .witness(let conformance) = record.role,
                names.contains(conformance),
                let name = memberName(of: symbol),
                let section = sections.first(where: { $0.range.contains(symbol.address) }),
                let spelling = DeclarationKey.demangle(symbol.name, language: .swift)
            else { return nil }
            return candidate(
                symbol,
                record: record,
                name: name,
                spelling: spelling,
                section: section
            )
        }
    }

    /// The address of the protocol conformance descriptor that this image
    /// names `name`, as the remangler spells it, in its exports or symbol table.
    package func swiftConformanceDescriptor(named name: String) -> UInt64? {
        conformanceDescriptors.byName[name]
    }

    /// The requirements that method descriptor symbols name at `address`, in
    /// this image's exports or symbol table, as the remangler spells them.
    package func swiftMethodDescriptorRequirements(at address: UInt64) -> Set<String> {
        methodDescriptors[address] ?? []
    }

    // Swift mangles a conformance descriptor with the suffix `Mc` and a method
    // descriptor with `Tq`. Records compare the names that the remangler
    // produces from each symbol's tree.
    private lazy var conformanceDescriptors:
        (byName: [String: UInt64], byAddress: [UInt64: Set<String>]) = {
            var result: (byName: [String: UInt64], byAddress: [UInt64: Set<String>]) = ([:], [:])
            for symbol in swiftSymbols(endingWith: (77, 99)) {
                guard
                    let name = RuntimeSwiftDeclaration.conformanceDescriptor(
                        linkageName: symbol.name
                    )
                else { continue }
                result.byName[name] = symbol.address
                result.byAddress[symbol.address, default: []].insert(name)
            }
            return result
        }()

    private lazy var methodDescriptors: [UInt64: Set<String>] = {
        var result: [UInt64: Set<String>] = [:]
        for symbol in swiftSymbols(endingWith: (84, 113)) {
            guard
                let requirement = RuntimeSwiftDeclaration.methodDescriptorRequirement(
                    linkageName: symbol.name
                )
            else { continue }
            result[symbol.address, default: []].insert(requirement)
        }
        return result
    }()

    /// The Swift symbols of this image's exports and symbol table whose names
    /// end with the two characters of `suffix`.
    private func swiftSymbols(endingWith suffix: (CChar, CChar)) -> [IndexedSymbol] {
        let table = swiftSymbols { name in
            let length = strlen(name)
            return length > 2 && name[length - 2] == suffix.0 && name[length - 1] == suffix.1
        }
        let exports = exportedSymbols(withPrefix: "_$s").filter {
            $0.name.utf8.suffix(2).elementsEqual([UInt8(suffix.0), UInt8(suffix.1)])
        }
        var seen = Set<IndexedSymbol>()
        return (table + exports).filter { seen.insert($0).inserted }
    }

    private func candidate(
        _ symbol: IndexedSymbol,
        record: RuntimeSwiftDeclaration,
        name: String,
        spelling: String,
        section: SymbolSection,
        kind: RuntimeSymbolKind = .function
    ) -> RuntimeSwiftCandidate {
        RuntimeSwiftCandidate(
            symbol: RuntimeSymbol(
                declaration: .init(name: spelling, language: .swift, kind: kind),
                image: image,
                sectionRange: section.range,
                source: symbol.source,
                address: symbol.address,
                linkageName: symbol.name
            ),
            record: record,
            declaration: .init(name: name, language: .swift),
            memberName: Self.extensionMemberName(name) ?? name
        )
    }

    private func record(of symbol: IndexedSymbol) -> RuntimeSwiftDeclaration? {
        if let cached = swiftRecords[symbol] { return cached }
        let record = RuntimeSwiftDeclaration(linkageName: symbol.name)
        swiftRecords[symbol] = record
        return record
    }

    // The source name of the declaration a symbol defines, dispatches, or
    // witnesses. Swift mangles a dispatch thunk as its declaration followed by
    // `Tj`, and a protocol witness thunk with the suffix `TW`.
    private func memberName(of symbol: IndexedSymbol) -> String? {
        // A property descriptor, mangled with the suffix `MV`, is filed with
        // its storage's members under the spelling of the getter it describes.
        if symbol.name.hasSuffix("MV"), let record = record(of: symbol),
            record.role == .propertyDescriptor
        {
            return record.describedGetter.flatMap {
                DeclarationKey.demangle($0, language: .swift)
            }
        }
        if symbol.name.hasSuffix("TW"), let record = record(of: symbol),
            case .witness = record.role, let requirement = record.requirement
        {
            return DeclarationKey.demangle(requirement, language: .swift)
        }
        let mangled =
            symbol.name.hasSuffix("Tj") ? String(symbol.name.dropLast(2)) : symbol.name
        return DeclarationKey.demangle(mangled, language: .swift)
    }

    // Fingerprints keep the index compact; the full normalized spelling is
    // always checked before a candidate can affect resolution or ambiguity.
    package static func matching(
        _ candidates: [IndexedSymbol],
        query: SymbolQuery
    ) -> [IndexedSymbol] {
        candidates.filter { symbol in
            guard
                let name = DeclarationKey.demangle(
                    symbol.name,
                    language: query.declaration.language
                )
            else { return false }
            var names = [name]
            if query.declaration.language == .swift {
                if let alias = operatorAlias(name) { names.append(alias) }
                if let alias = nominalDescriptorAlias(name) { names.append(alias) }
            }
            return names.contains {
                DeclarationKey.make($0, language: query.declaration.language) == query.key
            }
        }
    }

    package static func nominalDescriptorAlias(_ name: String) -> String? {
        let marker = "nominal type descriptor for "
        guard name.hasPrefix(marker),
            var nominal = extensionMemberName(String(name.dropFirst(marker.count)))
        else { return nil }
        // A nominal declaration is selected before its arguments are bound.
        // Its descriptor retains the extension constraints for runtime validation.
        for group in SwiftGenericSyntax.groups(in: nominal).reversed() {
            nominal.removeSubrange(group.range)
        }
        return marker + nominal
    }

    package static func operatorAlias(_ name: String) -> String? {
        for fixity in [" infix", " prefix", " postfix"] {
            for suffix in ["(", "<"] {
                guard let offset = byteOffset(of: fixity + suffix, in: name) else { continue }
                return String(decoding: name.utf8.prefix(offset), as: UTF8.self)
                    + String(
                        decoding: name.utf8.dropFirst(offset + fixity.utf8.count),
                        as: UTF8.self
                    )
            }
        }
        return nil
    }

    package static func extensionMemberName(_ name: String) -> String? {
        let isStatic = name.hasPrefix("static ")
        let declaration = isStatic ? String(name.dropFirst(7)) : name
        guard declaration.hasPrefix("(extension in "),
            let offset = byteOffset(of: "):", in: declaration)
        else { return nil }
        return (isStatic ? "static " : "")
            + String(decoding: declaration.utf8.dropFirst(offset + 2), as: UTF8.self)
    }

    // Demangler markers are ASCII. Avoid locale-aware substring search on
    // every Swift symbol while retaining the spelling of Unicode identifiers.
    static func byteOffset(of marker: String, in name: String) -> Int? {
        name.withCString { start in
            marker.withCString { marker in strstr(start, marker).map { start.distance(to: $0) } }
        }
    }

    package func swiftNominalTypeName(
        at address: UInt64,
        matching query: SymbolQuery,
        source: RuntimeSymbol.Source
    ) throws -> String? {
        let candidates =
            query.swiftModule == nil
            ? symbols(for: query, swiftBucket: nil, descriptorKind: .nominalType)
            : symbols(for: query, swiftBucket: .knownModule, descriptorKind: .nominalType)
                + symbols(for: query, swiftBucket: .fallback, descriptorKind: .nominalType)
        let marker = "nominal type descriptor for "
        var names = Set<String>()
        for candidate in candidates where candidate.address == address && candidate.source == source
        {
            guard let name = DeclarationKey.demangle(candidate.name, language: .swift),
                name.hasPrefix(marker)
            else { continue }
            names.insert(String(name.dropFirst(marker.count)))
        }
        guard names.count <= 1 else {
            throw RuntimeResolutionError.ambiguousDeclaration(
                query.declaration,
                candidates: names.sorted()
            )
        }
        return names.first
    }

    package func resolve(
        _ declaration: RuntimeDeclaration,
        source: RuntimeSymbol.Source
    ) throws -> RuntimeSymbol? {
        try resolve(SymbolQuery(declaration), source: source)
    }

    package func resolve(
        _ query: SymbolQuery,
        source: RuntimeSymbol.Source
    ) throws -> RuntimeSymbol? {
        let declaration = query.declaration
        let candidates = matches(query).filter { $0.source == source }
        guard !candidates.isEmpty else { return nil }
        var addresses: [UInt64: (IndexedSymbol, SymbolSection)] = [:]
        for candidate in candidates {
            if candidate.address != 0,
                let section = sections.first(where: { $0.range.contains(candidate.address) }),
                section.accepts(declaration.kind)
            {
                addresses[candidate.address] = (candidate, section)
            }
        }
        guard !addresses.isEmpty else { throw RuntimeResolutionError.invalidAddress }
        let definitions = addresses.sorted { $0.key < $1.key }.map { address, match in
            RuntimeSymbol(
                declaration: declaration,
                image: image,
                sectionRange: match.1.range,
                source: match.0.source,
                address: address,
                linkageName: match.0.name
            )
        }
        guard definitions.count > 1 else { return definitions[0] }
        if let definition = try RuntimeUniquedRecord.representative(of: definitions) {
            return definition
        }
        throw RuntimeResolutionError.ambiguousDeclaration(
            declaration,
            candidates: candidates.map(\.name).sorted()
        )
    }

    package static func slid(_ value: UInt64, by slide: Int64) -> UInt64? {
        if slide >= 0 {
            let result = value.addingReportingOverflow(UInt64(slide))
            return result.overflow ? nil : result.partialValue
        }
        let result = value.subtractingReportingOverflow(slide.magnitude)
        return result.overflow ? nil : result.partialValue
    }
}
