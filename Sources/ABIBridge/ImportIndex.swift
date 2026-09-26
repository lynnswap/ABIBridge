import ABIBridgeCore
import Foundation
import MachO
import MachOKit
import Synchronization

// Binding metadata describes references, not the signature or mutability of the
// referenced storage. Consumers must establish those separately before calling
// or changing an entry. References retain their importing image; a resolved or
// interposed target can require an independent image/code owner.
struct ImportedReference: Sendable {
    enum Source: Sendable, Equatable { case chained, opcodes, indirectSymbols }
    let image: NativeImage
    let symbol: String
    let libraryOrdinal: Int
    let libraryName: String?
    let weak: Bool
    // Identifies the legacy lazy-bind stream, not whether dyld has resolved it.
    let isLazyBinding: Bool
    let addend: Int64
    let address: UInt64
    let width: Int
    let sectionType: SectionType?
    let authentication: NativePointerAuthentication?
    let source: Source
}

final class ImportIndex: Sendable {
    let image: NativeImage
    let references: [ImportedReference]
    private let exactNames: [[UInt8]: [Int]]
    private let decoded = Mutex<[NativeLanguage: [Int: [([UInt8], Int)]]]>([:])

    init(image: NativeImage) throws {
        self.image = image
        let references = try ImportMetadata(image: image).read()
        self.references = references
        exactNames = Dictionary(grouping: references.indices, by: { Array(references[$0].symbol.utf8) })
    }

    func matches(_ declaration: NativeDeclaration, libraryOrdinal: Int? = nil) throws -> [ImportedReference] {
        guard declaration.language != .objectiveC || declaration.nameForm != .source else {
            throw ABIResolutionError.unsupportedDeclaration("Objective-C selectors do not identify imported symbols.")
        }
        let query = SymbolQuery(declaration)
        let matches: [ImportedReference]
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
                        if let existing = names[raw] { keys = existing }
                        else {
                            var spellings: [String] = []
                            if let name = DeclarationKey.demangle(reference.symbol, language: declaration.language) {
                                spellings.append(name)
                                if declaration.language == .swift, let alias = SymbolIndex.operatorAlias(name) { spellings.append(alias) }
                            }
                            keys = spellings.map(DeclarationKey.make)
                            names[raw] = keys
                        }
                        for key in keys { index[DeclarationKey.fingerprint(key), default: []].append((key, offset)) }
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

struct ImportMetadata {
    let image: NativeImage
    let macho: MachOImage
    let segments: [(address: UInt64, size: UInt64)]
    let libraries: [String]
    let sections: [(address: UInt64, size: UInt64, type: SectionType?)]

    init(image: NativeImage) {
        self.image = image
        macho = MachOImage(ptr: UnsafePointer<mach_header>(bitPattern: UInt(image.identity.headerAddress))!)
        if macho.is64Bit { segments = macho.segments64.map { ($0.vmaddr, $0.vmsize) } }
        else { segments = macho.segments32.map { (UInt64($0.vmaddr), UInt64($0.vmsize)) } }
        libraries = macho.dependencies.map { $0.dylib.name }
        sections = macho.sections.map { (UInt64($0.address), UInt64($0.size), $0.flags.type) }
    }

    func unavailable(_ message: String) -> ABIResolutionError {
        .metadataUnavailable("Imports in \(image.path): \(message)")
    }

    func reference(_ name: String, ordinal: Int, weak: Bool, lazy: Bool = false, addend: Int64, address: UInt64,
                   width: Int, authentication: NativePointerAuthentication?, source: ImportedReference.Source) throws -> ImportedReference {
        let library: String?
        if ordinal > 0 {
            guard libraries.indices.contains(ordinal - 1) else { throw unavailable("library ordinal is out of range") }
            library = libraries[ordinal - 1]
        } else { library = nil }
        let unslid = UInt64(bitPattern: Int64(bitPattern: address) &- image.identity.slide)
        let sectionType = sections.first { unslid >= $0.address && unslid - $0.address < $0.size }?.type
        return .init(image: image, symbol: name, libraryOrdinal: ordinal, libraryName: library,
            weak: weak, isLazyBinding: lazy, addend: addend, address: address, width: width,
            sectionType: sectionType, authentication: authentication, source: source)
    }

    func address(segment: Int, offset: UInt64, width: Int) throws -> UInt64 {
        guard segments.indices.contains(segment), offset <= segments[segment].size,
              UInt64(width) <= segments[segment].size - offset else { throw unavailable("binding exceeds its segment") }
        let unslid = segments[segment].address.addingReportingOverflow(offset)
        guard !unslid.overflow else { throw unavailable("binding address overflow") }
        let value = Int64(bitPattern: unslid.partialValue).addingReportingOverflow(image.identity.slide)
        guard !value.overflow else { throw unavailable("binding slide overflow") }
        return UInt64(bitPattern: value.partialValue)
    }

    func read() throws -> [ImportedReference] {
        if macho.dyldChainedFixups != nil { return try chained() }
        let normal = macho.bindOperations.map(Array.init) ?? []
        let lazy = macho.lazyBindOperations.map(Array.init) ?? []
        let weak = macho.weakBindOperations.map(Array.init) ?? []
        if !normal.isEmpty || !lazy.isEmpty || !weak.isEmpty {
            return try opcodes(normal) + opcodes(lazy, lazy: true) + opcodes(weak, coalesced: true)
        }
        if image.path.withCString({ ABIImageIsInSharedCache($0) }) {
            throw unavailable("the shared-cache image has no recoverable binding metadata")
        }
        return try indirect()
    }

    func originalFile() throws -> MachOFile {
        let files: [MachOFile]
        do {
            switch try MachOKit.loadFromFile(url: URL(fileURLWithPath: image.path)) {
            case .machO(let file): files = [file]
            case .fat(let file): files = try file.machOFiles()
            }
        } catch { throw unavailable("original chained-fixup file is unavailable: \(error)") }
        guard let uuid = image.identity.uuid else { throw unavailable("no UUID identifies the original chained-fixup file") }
        guard let file = files.first(where: { file in
            file.header.layout.cputype == macho.header.layout.cputype
                && file.header.layout.cpusubtype == macho.header.layout.cpusubtype
                && file.loadCommands.contains { if case .uuid(let command) = $0 { command.uuid == uuid } else { false } }
        }) else { throw unavailable("original file does not match the loaded image") }
        return file
    }

    func chained() throws -> [ImportedReference] {
        let file = try originalFile()
        guard let fixups = file.dyldChainedFixups, let starts = fixups.startsInImage else { throw unavailable("chain starts are unavailable") }
        let imports = fixups.imports
        let fileOffsets: [UInt64] = file.is64Bit ? file.segments64.map(\.fileoff) : file.segments32.map { UInt64($0.fileoff) }
        var result: [ImportedReference] = []
        for segment in fixups.startsInSegments(of: starts) where segment.offset != starts.offset {
            guard let format = segment.pointerFormat else { throw unavailable("unknown chained pointer format") }
            let width: Int
            switch format {
            case ._32: width = 4
            case ._64, ._64_offset, .arm64e, .arm64e_kernel, .arm64e_firmware, .arm64e_userland, .arm64e_userland24: width = 8
            default: throw unavailable("unsupported chained pointer format \(format)")
            }
            guard fileOffsets.indices.contains(segment.segmentIndex) else { throw unavailable("chain segment is out of range") }
            // MachOKit 0.53's file walker interprets segment_offset as a file
            // offset. Zero-fill can make that differ from the VM offset stored
            // in the actual command; translate only the walker's input/output.
            let fileOffset = fileOffsets[segment.segmentIndex]
            var fileSegment = segment
            fileSegment.layout.segment_offset = fileOffset
            guard !fixups.pages(of: segment).contains(where: { !$0.isNone && $0.isMulti }) else {
                throw unavailable("the current file walker cannot decode multi-start chain overflow entries")
            }
            for pointer in fixups.pointers(of: fileSegment, in: file) {
                guard let bind = pointer.fixupInfo.bind else { continue }
                guard imports.indices.contains(bind.ordinal) else { throw unavailable("chained import ordinal is out of range") }
                let item = imports[bind.ordinal].info
                guard let name = fixups.symbolName(for: item.nameOffset) else { throw unavailable("chained import name is unavailable") }
                let authentication: NativePointerAuthentication
                if let auth = bind as? DyldChainedPtrArm64eAuthBind {
                    guard let key = NativePointerAuthentication.Key(rawValue: Int32(auth.layout.key)) else { throw unavailable("unknown authentication key") }
                    authentication = .signed(key: key, discriminator: UInt(auth.layout.diversity), addressDiversity: auth.layout.addrDiv != 0)
                } else if let auth = bind as? DyldChainedPtrArm64eAuthBind24 {
                    guard let key = NativePointerAuthentication.Key(rawValue: Int32(auth.layout.key)) else { throw unavailable("unknown authentication key") }
                    authentication = .signed(key: key, discriminator: UInt(auth.layout.diversity), addressDiversity: auth.layout.addrDiv != 0)
                } else {
                    guard !bind.isAuth else { throw unavailable("unknown authenticated bind") }
                    authentication = .unsigned
                }
                guard pointer.offset >= 0, UInt64(pointer.offset) >= fileOffset else { throw unavailable("invalid chain offset") }
                let slot = try address(segment: segment.segmentIndex, offset: UInt64(pointer.offset) - fileOffset, width: width)
                let addend = Int64(bitPattern: bind.signExtendedAddend &+ UInt64(bitPattern: Int64(item.addend)))
                result.append(try reference(name, ordinal: item.libraryOrdinal, weak: item.isWeakImport, addend: addend,
                    address: slot, width: width, authentication: authentication, source: .chained))
            }
        }
        return result
    }

    // MachOKit decodes the opcodes; retain symbol flags as well as location state
    // here because its interpreted BindingSymbol currently omits weak-import flags.
    func opcodes(_ operations: [BindOperation], lazy: Bool = false, coalesced: Bool = false) throws -> [ImportedReference] {
        let width = MemoryLayout<UnsafeRawPointer>.size
        var name: String?, ordinal = coalesced ? -3 : 0, segment = 0, offset: UInt64 = 0, flags: UInt = 0, addend: Int64 = 0
        var type = BindType.pointer
        var result: [ImportedReference] = []
        func advance(_ amount: UInt64) throws {
            let next = offset.addingReportingOverflow(amount)
            guard !next.overflow else { throw unavailable("bind offset overflow") }
            offset = next.partialValue
        }
        func emit() throws {
            guard type == .pointer else { throw unavailable("non-pointer binding cannot describe a callable slot") }
            guard let name else { throw unavailable("binding has no symbol name") }
            result.append(try reference(name, ordinal: ordinal, weak: flags & UInt(BIND_SYMBOL_FLAGS_WEAK_IMPORT) != 0,
                lazy: lazy, addend: addend, address: address(segment: segment, offset: offset, width: width), width: width,
                authentication: .unsigned, source: .opcodes))
        }
        for operation in operations {
            switch operation {
            case .done:
                if !lazy { return result }
                name = nil; ordinal = 0; segment = 0; offset = 0; flags = 0; addend = 0; type = .pointer
            case .set_dylib_ordinal_imm(let value), .set_dylib_ordinal_uleb(let value): ordinal = value
            case .set_dylib_special_imm(let value): ordinal = Int(value.rawValue)
            case .set_symbol_trailing_flags_imm(let value, let symbol): flags = value; name = symbol
            case .set_type_imm(let value): type = value
            case .set_addend_sleb(let value): addend = Int64(value)
            case .set_segment_and_offset_uleb(let value, let location): segment = Int(value); offset = UInt64(location)
            case .add_addr_uleb(let value): try advance(UInt64(value))
            case .do_bind: try emit(); try advance(UInt64(width))
            case .do_bind_add_addr_uleb(let value): try emit(); try advance(UInt64(width)); try advance(UInt64(value))
            case .do_bind_add_addr_imm_scaled(let scale): try emit(); try advance(UInt64(width)); try advance(UInt64(scale) * UInt64(width))
            case .do_bind_uleb_times_skipping_uleb(let count, let skip):
                for _ in 0..<count { try emit(); try advance(UInt64(width)); try advance(UInt64(skip)) }
            case .threaded: throw unavailable("threaded bind opcodes require their original encoded pointer chains")
            }
        }
        return result
    }

    func indirect() throws -> [ImportedReference] {
        if let relocations = macho.externalRelocations, relocations.contains(where: { _ in true }) {
            throw unavailable("classic external relocations require their original addend storage")
        }
        guard let indirect = macho.indirectSymbols else { return [] }
        let table = Array(indirect)
        let symbols = Array(macho.symbols)
        let width = MemoryLayout<UnsafeRawPointer>.size
        var result: [ImportedReference] = []
        for section in macho.sections {
            guard let type = section.flags.type,
                  [.lazy_symbol_pointers, .non_lazy_symbol_pointers, .lazy_dylib_symbol_pointers].contains(type) else { continue }
            guard let start = section.indirectSymbolIndex, let count = section.numberOfIndirectSymbols,
                  start >= 0, start <= table.count, count >= 0, count <= table.count - start,
                  section.address >= 0, let segment = segments.indices.first(where: {
                      UInt64(section.address) >= segments[$0].address
                          && UInt64(section.address) - segments[$0].address < segments[$0].size
                  }) else { throw unavailable("indirect section exceeds its image metadata") }
            for slot in 0..<count {
                // Preserve the physical slot index when local/absolute entries
                // are skipped; filtering the table before enumeration shifts it.
                guard let index = table[start + slot].index else { continue }
                guard symbols.indices.contains(index) else { throw unavailable("indirect symbol index is out of range") }
                let symbol = symbols[index]
                guard let descriptor = symbol.nlist.symbolDescription else { throw unavailable("indirect symbol description is unavailable") }
                let ordinal = descriptor.libraryOrdinal == 255 ? -1 : descriptor.libraryOrdinal == 254 ? -2 : Int(descriptor.libraryOrdinal)
                let offset = UInt64(section.address) - segments[segment].address + UInt64(slot * width)
                result.append(try reference(symbol.name, ordinal: ordinal, weak: descriptor.contains(.weak_ref),
                    lazy: type != .non_lazy_symbol_pointers, addend: 0, address: address(segment: segment, offset: offset, width: width),
                    width: width, authentication: nil, source: .indirectSymbols))
            }
        }
        return result
    }
}
