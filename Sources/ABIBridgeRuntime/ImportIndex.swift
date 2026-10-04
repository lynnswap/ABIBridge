import ABIBridgeCore
import Foundation
import MachO
import MachOKit
import Synchronization

// Binding metadata describes references, not the signature or mutability of the
// referenced storage. Consumers must establish those separately before calling
// or changing an entry. References retain their importing image; a resolved or
// interposed target can require an independent image/code owner.
package struct RuntimeImportedReference: Sendable {
    package enum Source: Sendable, Equatable { case chained, opcodes, indirectSymbols }
    package let image: RuntimeImage
    package let symbol: String
    package let libraryOrdinal: Int
    package let libraryName: String?
    package var weak: Bool
    package var usesWeakCoalescing: Bool
    // Identifies the legacy lazy-bind stream, not whether dyld has resolved it.
    package let isLazyBinding: Bool
    package let addend: Int64
    package let address: UInt64
    package let width: Int
    package let sectionType: SectionType?
    package let authentication: RuntimePointerAuthentication?
    package let source: Source
}

package final class ImportIndex: Sendable {
    package let image: RuntimeImage
    package let references: [RuntimeImportedReference]
    private let exactNames: [[UInt8]: [Int]]
    private let decoded = Mutex<[RuntimeLanguage: [Int: [([UInt8], Int)]]]>([:])

    package init(image: RuntimeImage) throws {
        self.image = image
        let references = try ImportMetadata(image: image).read()
        self.references = references
        exactNames = Dictionary(
            grouping: references.indices,
            by: { Array(references[$0].symbol.utf8) }
        )
    }

    package func matches(
        _ declaration: RuntimeDeclaration,
        libraryOrdinal: Int? = nil
    ) throws -> [RuntimeImportedReference] {
        guard declaration.language != .objectiveC || declaration.nameForm != .source else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "Objective-C selectors do not identify imported symbols."
            )
        }
        let query = SymbolQuery(declaration)
        let matches: [RuntimeImportedReference]
        if let exact = query.exactName {
            matches = (exactNames[Array(exact.utf8)] ?? []).map { references[$0] }
        } else {
            matches = decoded.withLock { cache in
                if cache[declaration.language] == nil {
                    var index: [Int: [([UInt8], Int)]] = [:]
                    var names: [[UInt8]: [[UInt8]]] = [:]
                    let prefixes = DeclarationKey.symbolPrefixes(for: declaration.language)
                    for (offset, reference) in references.enumerated() {
                        guard prefixes.contains(where: reference.symbol.hasPrefix) else { continue }
                        let raw = Array(reference.symbol.utf8)
                        let keys: [[UInt8]]
                        if let existing = names[raw] {
                            keys = existing
                        } else {
                            var spellings: [String] = []
                            if let name = DeclarationKey.demangle(
                                reference.symbol,
                                language: declaration.language
                            ) {
                                spellings.append(name)
                                if declaration.language == .swift,
                                    let alias = SymbolIndex.operatorAlias(name)
                                {
                                    spellings.append(alias)
                                }
                            }
                            keys = spellings.map {
                                DeclarationKey.make($0, language: declaration.language)
                            }
                            names[raw] = keys
                        }
                        for key in keys {
                            index[DeclarationKey.fingerprint(key), default: []].append(
                                (key, offset)
                            )
                        }
                    }
                    cache[declaration.language] = index
                }
                return (cache[declaration.language]?[query.fingerprint] ?? [])
                    .filter { $0.0 == query.key }.map { references[$0.1] }
            }
        }
        return matches.filter { libraryOrdinal == nil || $0.libraryOrdinal == libraryOrdinal }
    }
}

package struct ImportMetadata {
    package let image: RuntimeImage
    package let macho: MachOImage
    package let segments: [(address: UInt64, size: UInt64)]
    package let libraries: [String]
    package let sections: [(address: UInt64, size: UInt64, type: SectionType?)]

    package init(image: RuntimeImage) {
        self.image = image
        macho = MachOImage(
            ptr: UnsafePointer<mach_header>(bitPattern: UInt(image.identity.headerAddress))!
        )
        if macho.is64Bit {
            segments = macho.segments64.map { ($0.vmaddr, $0.vmsize) }
        } else {
            segments = macho.segments32.map { (UInt64($0.vmaddr), UInt64($0.vmsize)) }
        }
        libraries = macho.dependencies.map { $0.dylib.name }
        sections = macho.sections.map { (UInt64($0.address), UInt64($0.size), $0.flags.type) }
    }

    package func unavailable(_ message: String) -> RuntimeResolutionError {
        .metadataUnavailable("Imports in \(image.path): \(message)")
    }

    package func reference(
        _ name: String,
        ordinal: Int,
        weak: Bool,
        lazy: Bool = false,
        addend: Int64,
        address: UInt64,
        width: Int,
        authentication: RuntimePointerAuthentication?,
        source: RuntimeImportedReference.Source
    ) throws -> RuntimeImportedReference {
        let library: String?
        if ordinal > 0 {
            guard libraries.indices.contains(ordinal - 1) else {
                throw unavailable("library ordinal is out of range")
            }
            library = libraries[ordinal - 1]
        } else {
            library = nil
        }
        let unslid = UInt64(bitPattern: Int64(bitPattern: address) &- image.identity.slide)
        let sectionType = sections.first { unslid >= $0.address && unslid - $0.address < $0.size }?
            .type
        return .init(
            image: image,
            symbol: name,
            libraryOrdinal: ordinal,
            libraryName: library,
            weak: weak,
            usesWeakCoalescing: ordinal == -3,
            isLazyBinding: lazy,
            addend: addend,
            address: address,
            width: width,
            sectionType: sectionType,
            authentication: authentication,
            source: source
        )
    }

    package func address(segment: Int, offset: UInt64, width: Int) throws -> UInt64 {
        guard segments.indices.contains(segment), offset <= segments[segment].size,
            UInt64(width) <= segments[segment].size - offset
        else { throw unavailable("binding exceeds its segment") }
        let unslid = segments[segment].address.addingReportingOverflow(offset)
        guard !unslid.overflow else { throw unavailable("binding address overflow") }
        let value = Int64(bitPattern: unslid.partialValue).addingReportingOverflow(
            image.identity.slide
        )
        guard !value.overflow else { throw unavailable("binding slide overflow") }
        return UInt64(bitPattern: value.partialValue)
    }

    package func read() throws -> [RuntimeImportedReference] {
        if macho.dyldChainedFixups != nil { return try chained() }
        let normal = macho.bindOperations.map(Array.init) ?? []
        let lazy = macho.lazyBindOperations.map(Array.init) ?? []
        let weak = macho.weakBindOperations.map(Array.init) ?? []
        if !normal.isEmpty || !lazy.isEmpty || !weak.isEmpty {
            var result = try opcodes(normal) + opcodes(lazy, lazy: true)
            var positions: [UInt64: Int] = [:]
            for (index, reference) in result.enumerated() { positions[reference.address] = index }
            for reference in try opcodes(weak, coalesced: true) {
                if let index = positions[reference.address] {
                    let previous = result[index]
                    guard previous.symbol.utf8.elementsEqual(reference.symbol.utf8),
                        previous.addend == reference.addend,
                        previous.width == reference.width,
                        previous.authentication == reference.authentication
                    else {
                        throw unavailable("normal and weak streams disagree about one slot")
                    }
                    // The weak stream refines lookup at an existing binding; it
                    // is not another slot and does not erase its declared dylib.
                    result[index].usesWeakCoalescing = true
                    result[index].weak = previous.weak || reference.weak
                } else {
                    positions[reference.address] = result.count
                    result.append(reference)
                }
            }
            return result
        }
        if image.path.withCString({ ABIImageIsInSharedCache($0) }) {
            throw unavailable("the shared-cache image has no recoverable binding metadata")
        }
        return try indirect()
    }

    package func chained() throws -> [RuntimeImportedReference] {
        let original = try OriginalImageMetadata(image: image)
        guard let fixups = original.file.dyldChainedFixups else {
            throw unavailable("chain starts are unavailable")
        }
        let imports = fixups.imports
        return try original.chainedPointers().compactMap { entry in
            guard let bind = entry.pointer.fixupInfo.bind else { return nil }
            guard imports.indices.contains(bind.ordinal) else {
                throw unavailable("chained import ordinal is out of range")
            }
            let item = Self.chainedImport(imports[bind.ordinal])
            guard let name = fixups.symbolName(for: item.nameOffset) else {
                throw unavailable("chained import name is unavailable")
            }
            let addend = Int64(
                bitPattern: bind.signExtendedAddend &+ UInt64(bitPattern: item.addend)
            )
            return try reference(
                name,
                ordinal: item.ordinal,
                weak: item.weak,
                addend: addend,
                address: entry.address,
                width: entry.width,
                authentication: OriginalImageMetadata.authentication(bind),
                source: .chained
            )
        }
    }

    // Only the reserved high ordinal range is signed. MachOKit 0.53's accessors
    // sign-extend all ordinals and checked-convert ADDEND64 to Int; use the raw
    // fields so large dependency indexes and negative addends preserve their bits.
    package static func chainedImport(
        _ item: DyldChainedImport
    ) -> (ordinal: Int, nameOffset: Int, weak: Bool, addend: Int64) {
        switch item {
        case .general(let item):
            let raw = Int(item.layout.lib_ordinal)
            return (
                raw > 0xF0 ? raw - 0x100 : raw, Int(item.layout.name_offset),
                item.layout.weak_import != 0, 0
            )
        case .addend(let item):
            let raw = Int(item.layout.lib_ordinal)
            return (
                raw > 0xF0 ? raw - 0x100 : raw, Int(item.layout.name_offset),
                item.layout.weak_import != 0, Int64(item.layout.addend)
            )
        case .addend64(let item):
            let raw = Int(item.layout.lib_ordinal)
            return (
                raw > 0xFFF0 ? raw - 0x10000 : raw, Int(item.layout.name_offset),
                item.layout.weak_import != 0, Int64(bitPattern: item.layout.addend)
            )
        }
    }

    // MachOKit decodes the opcodes; retain symbol flags as well as location state
    // here because its interpreted BindingSymbol currently omits weak-import flags.
    package func opcodes(
        _ operations: [BindOperation],
        lazy: Bool = false,
        coalesced: Bool = false
    ) throws -> [RuntimeImportedReference] {
        let width = MemoryLayout<UnsafeRawPointer>.size
        var name: String?, ordinal = coalesced ? -3 : 0, segment = 0, offset: UInt64 = 0,
            flags: UInt = 0, addend: Int64 = 0
        var type = BindType.pointer
        var result: [RuntimeImportedReference] = []
        func advance(_ amount: UInt64) throws {
            let next = offset.addingReportingOverflow(amount)
            guard !next.overflow else { throw unavailable("bind offset overflow") }
            offset = next.partialValue
        }
        func emit() throws {
            guard type == .pointer else {
                throw unavailable("non-pointer binding cannot describe a callable slot")
            }
            guard let name else { throw unavailable("binding has no symbol name") }
            result.append(
                try reference(
                    name,
                    ordinal: ordinal,
                    weak: flags & UInt(BIND_SYMBOL_FLAGS_WEAK_IMPORT) != 0,
                    lazy: lazy,
                    addend: addend,
                    address: address(segment: segment, offset: offset, width: width),
                    width: width,
                    authentication: .unsigned,
                    source: .opcodes
                )
            )
        }
        for operation in operations {
            switch operation {
            case .done:
                if !lazy { return result }
                name = nil; ordinal = 0; segment = 0; offset = 0; flags = 0; addend = 0;
                type = .pointer
            case .set_dylib_ordinal_imm(let value), .set_dylib_ordinal_uleb(let value):
                ordinal = value
            case .set_dylib_special_imm(let value): ordinal = Int(value.rawValue)
            case .set_symbol_trailing_flags_imm(let value, let symbol): flags = value; name = symbol
            case .set_type_imm(let value): type = value
            case .set_addend_sleb(let value): addend = Int64(value)
            case .set_segment_and_offset_uleb(let value, let location):
                segment = Int(value); offset = UInt64(location)
            case .add_addr_uleb(let value): try advance(UInt64(value))
            case .do_bind: try emit(); try advance(UInt64(width))
            case .do_bind_add_addr_uleb(let value):
                try emit(); try advance(UInt64(width)); try advance(UInt64(value))
            case .do_bind_add_addr_imm_scaled(let scale):
                try emit(); try advance(UInt64(width)); try advance(UInt64(scale) * UInt64(width))
            case .do_bind_uleb_times_skipping_uleb(let count, let skip):
                for _ in 0..<count {
                    try emit(); try advance(UInt64(width)); try advance(UInt64(skip))
                }
            case .threaded:
                throw unavailable(
                    "threaded bind opcodes require their original encoded pointer chains"
                )
            }
        }
        return result
    }

    package func indirect() throws -> [RuntimeImportedReference] {
        if let relocations = macho.externalRelocations, relocations.contains(where: { _ in true }) {
            throw unavailable("classic external relocations require their original addend storage")
        }
        guard let indirect = macho.indirectSymbols else { return [] }
        let table = Array(indirect)
        let symbols = Array(macho.symbols)
        let width = MemoryLayout<UnsafeRawPointer>.size
        var result: [RuntimeImportedReference] = []
        for section in macho.sections {
            guard let type = section.flags.type,
                [.lazy_symbol_pointers, .non_lazy_symbol_pointers, .lazy_dylib_symbol_pointers]
                    .contains(type)
            else { continue }
            guard let start = section.indirectSymbolIndex,
                let count = section.numberOfIndirectSymbols,
                start >= 0, start <= table.count, count >= 0, count <= table.count - start,
                section.address >= 0,
                let segment = segments.indices.first(where: {
                    UInt64(section.address) >= segments[$0].address
                        && UInt64(section.address) - segments[$0].address < segments[$0].size
                })
            else { throw unavailable("indirect section exceeds its image metadata") }
            for slot in 0..<count {
                // Preserve the physical slot index when local/absolute entries
                // are skipped; filtering the table before enumeration shifts it.
                guard let index = table[start + slot].index else { continue }
                guard symbols.indices.contains(index) else {
                    throw unavailable("indirect symbol index is out of range")
                }
                let symbol = symbols[index]
                guard let descriptor = symbol.nlist.symbolDescription else {
                    throw unavailable("indirect symbol description is unavailable")
                }
                let ordinal =
                    descriptor.libraryOrdinal == 255
                    ? -1 : descriptor.libraryOrdinal == 254 ? -2 : Int(descriptor.libraryOrdinal)
                let offset =
                    UInt64(section.address) - segments[segment].address + UInt64(slot * width)
                result.append(
                    try reference(
                        symbol.name,
                        ordinal: ordinal,
                        weak: descriptor.contains(.weak_ref),
                        lazy: type != .non_lazy_symbol_pointers,
                        addend: 0,
                        address: address(segment: segment, offset: offset, width: width),
                        width: width,
                        authentication: nil,
                        source: .indirectSymbols
                    )
                )
            }
        }
        return result
    }
}
