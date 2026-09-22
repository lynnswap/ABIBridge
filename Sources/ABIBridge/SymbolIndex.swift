import ABIBridgeCore
import Foundation
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
        var inIdentifier = false
        for byte in declaration.utf8 {
            switch byte {
            case 48...57, 65...90, 97...122, 95:
                if !inIdentifier { key.append(0) }
                key.append(byte)
                inIdentifier = true
            case 9...13, 32: inIdentifier = false
            default:
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

final class SymbolIndex {
    let image: NativeImage
    let sections: [SymbolSection]
    var symbols: [IndexedSymbol]
    var sharedCacheLoaded = false
    private struct Scope: Hashable {
        let language: NativeLanguage
        let owner: String?
    }
    private var decoded: [Scope: [[UInt8]: [IndexedSymbol]]] = [:]
    private var linkerNames: [String: [IndexedSymbol]]?

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
        linkerNames = nil
        sharedCacheLoaded = true
    }

    func matches(_ declaration: NativeDeclaration) -> [IndexedSymbol] {
        if declaration.language == .c {
            if linkerNames == nil { linkerNames = Dictionary(grouping: symbols, by: \.name) }
            return linkerNames?["_" + declaration.name] ?? []
        }
        // Plain Itanium owner names occur literally in their mangling. Restrict
        // demangling to that owner, then reuse its index for other members.
        let prefix = String(declaration.name.prefix { $0 != "(" })
            .replacingOccurrences(of: "vtable for ", with: "")
        let components = prefix.components(separatedBy: "::")
        let owner = components.dropLast().last
        let substitutions: Set<String> = [
            "std", "__1", "allocator", "basic_string", "string",
            "basic_istream", "basic_ostream", "basic_iostream", "istream", "ostream", "iostream",
        ]
        let needle = declaration.language == .cxx
            && owner?.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
            && !substitutions.contains(owner ?? "") ? owner : nil
        let scope = Scope(language: declaration.language, owner: needle)
        if decoded[scope] == nil {
            var index: [[UInt8]: [IndexedSymbol]] = [:]
            for symbol in symbols {
                if let needle = scope.owner, !symbol.name.contains(needle) { continue }
                guard let name = DeclarationKey.demangle(symbol.name, language: declaration.language) else { continue }
                index[DeclarationKey.make(name), default: []].append(symbol)
            }
            decoded[scope] = index
        }
        return decoded[scope]?[DeclarationKey.make(declaration.name)] ?? []
    }

    func resolve(_ declaration: NativeDeclaration, source: ResolvedSymbol.Source) throws -> ResolvedSymbol? {
        let candidates = matches(declaration).filter { $0.source == source }
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
