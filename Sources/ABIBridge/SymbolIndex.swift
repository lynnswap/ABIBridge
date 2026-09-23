import ABIBridgeCore
import Foundation
import Darwin
import MachO
import MachOKit

struct IndexedSymbol {
    let name: String
    let address: UInt64
    let source: ResolvedSymbol.Source
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
    var symbols: [IndexedSymbol]
    var sharedCacheLoaded = false
    private struct Scope: Hashable {
        let language: NativeLanguage
        let fragments: [String]
    }
    private var decoded: [Scope: [[UInt8]: [IndexedSymbol]]] = [:]
    private var cxxCandidates: [String: [IndexedSymbol]] = [:]
    private var linkerNames: [String: [IndexedSymbol]]?
    private var swiftExtensions: [[UInt8]: [IndexedSymbol]] = [:]

    init(image: NativeImage) {
        self.image = image
        let macho = MachOImage(ptr: UnsafePointer<mach_header>(bitPattern: UInt(image.identity.headerAddress))!)
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
        let base = image.identity.headerAddress
        symbols = macho.symbols.compactMap { symbol in
            guard symbol.nlist.flags?.type == .sect,
                  symbol.offset >= 0, UInt64(symbol.offset) <= UInt64.max - base else { return nil }
            return IndexedSymbol(name: symbol.name, address: base + UInt64(symbol.offset), source: .image)
        }
        symbols += macho.exportedSymbols.compactMap { symbol in
            guard let offset = symbol.offset, offset >= 0, UInt64(offset) <= UInt64.max - base else { return nil }
            return IndexedSymbol(name: symbol.name, address: base + UInt64(offset), source: .image)
        }
    }

    func appendSharedCacheSymbols(_ more: [IndexedSymbol]) {
        symbols += more
        decoded.removeAll()
        cxxCandidates.removeAll()
        swiftExtensions.removeAll()
        linkerNames = nil
        sharedCacheLoaded = true
    }

    func matches(_ declaration: NativeDeclaration, extensionsOnly: Bool = false) -> [IndexedSymbol] {
        if declaration.language == .c {
            if linkerNames == nil { linkerNames = Dictionary(grouping: symbols, by: \.name) }
            return linkerNames?["_" + declaration.name] ?? []
        }
        let filter = CXXSymbolFilter(declaration.language == .cxx ? declaration.name : "")
        let scope = Scope(language: declaration.language, fragments: filter.fragments)
        if decoded[scope] == nil {
            let candidates: [IndexedSymbol]
            if let owner = filter.fragments.first {
                if cxxCandidates[owner] == nil {
                    cxxCandidates[owner] = symbols.filter { filter.matchesOwner($0.name) }
                }
                candidates = cxxCandidates[owner]!
            } else {
                candidates = symbols
            }
            var index: [[UInt8]: [IndexedSymbol]] = [:]
            for symbol in candidates {
                guard filter.matches(symbol.name) else { continue }
                guard let name = DeclarationKey.demangle(symbol.name, language: declaration.language) else { continue }
                var names = [name]
                if declaration.language == .swift, let alias = Self.operatorAlias(name) { names.append(alias) }
                for name in names {
                    index[DeclarationKey.make(name), default: []].append(symbol)
                    if declaration.language == .swift, let unqualified = Self.extensionMemberName(name) {
                        swiftExtensions[DeclarationKey.make(unqualified), default: []].append(symbol)
                    }
                }
            }
            decoded[scope] = index
        }
        let key = DeclarationKey.make(declaration.name)
        return extensionsOnly ? swiftExtensions[key] ?? [] : decoded[scope]?[key] ?? []
    }

    private static func operatorAlias(_ name: String) -> String? {
        for token in [" infix(", " prefix(", " postfix("] {
            guard let fixity = name.range(of: token) else { continue }
            return String(name[..<fixity.lowerBound]) + "(" + name[fixity.upperBound...]
        }
        return nil
    }

    private static func extensionMemberName(_ name: String) -> String? {
        let isStatic = name.hasPrefix("static ")
        let declaration = isStatic ? String(name.dropFirst(7)) : name
        guard declaration.hasPrefix("(extension in "),
              let end = declaration.range(of: "):") else { return nil }
        return (isStatic ? "static " : "") + declaration[end.upperBound...]
    }

    func resolve(
        _ declaration: NativeDeclaration, source: ResolvedSymbol.Source, extensionsOnly: Bool = false
    ) throws -> ResolvedSymbol? {
        let candidates = matches(declaration, extensionsOnly: extensionsOnly).filter { $0.source == source }
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
