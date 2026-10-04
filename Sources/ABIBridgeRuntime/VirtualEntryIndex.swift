import ABIBridgeCore
import Foundation
import MachOKit
import MachO
import Synchronization

package struct RuntimeVirtualEntryResolution: Sendable {
    package let image: RuntimeImage
    package let index: Int
    package let symbol: String
    package let authentication: RuntimePointerAuthentication
}

package final class VirtualEntryIndex: Sendable {
    package struct Target: Sendable {
        package let symbols: [String]
        package let authentication: RuntimePointerAuthentication
    }
    package let image: RuntimeImage
    private let targets: [UInt64: Result<Target, RuntimeResolutionError>]
    private struct OriginalSegment: Sendable {
        let address: UInt64
        let size: UInt64
        let file: UInt64
        let fileSize: UInt64
    }
    private let segments: [OriginalSegment]
    private let headerOffset: Int
    private let source: Mutex<Result<FileHandle, RuntimeResolutionError>>
    private struct DecodedTarget: Sendable {
        let declarations: Set<[UInt8]>
        let uniqueSymbol: String?
    }
    private let decoded = Mutex<[UInt64: DecodedTarget]>([:])

    private func declarations(at address: UInt64, for target: Target) -> DecodedTarget {
        decoded.withLock { cache in
            if let cached = cache[address] { return cached }
            let keys = target.symbols.compactMap { symbol -> [UInt8]? in
                guard let name = DeclarationKey.demangle(symbol, language: .cxx) else { return nil }
                let prefixes = [
                    "non-virtual thunk to ", "virtual thunk to ", "covariant return thunk to ",
                ]
                let method =
                    prefixes.first(where: name.hasPrefix).map { String(name.dropFirst($0.count)) }
                    ?? name
                return DeclarationKey.make(method)
            }
            let result = DecodedTarget(
                declarations: Set(keys),
                uniqueSymbol: target.symbols.count == 1 ? target.symbols.first : nil
            )
            cache[address] = result
            return result
        }
    }

    package init(image: RuntimeImage) throws {
        self.image = image
        let original = try OriginalImageMetadata(image: image)
        let file = original.file
        headerOffset = file.headerStartOffset
        segments = file.segments.compactMap { segment in
            guard let address = UInt64(exactly: segment.virtualMemoryAddress),
                let size = UInt64(exactly: segment.virtualMemorySize),
                let offset = UInt64(exactly: segment.fileOffset),
                let fileSize = UInt64(exactly: segment.fileSize)
            else { return nil }
            return OriginalSegment(address: address, size: size, file: offset, fileSize: fileSize)
        }
        do { source = Mutex(.success(try original.openReadHandle())) } catch {
            source = Mutex(
                .failure(
                    .metadataUnavailable(
                        "Original pointer bytes in \(image.path) are unavailable: \(error)"
                    )
                )
            )
        }
        guard file.is64Bit, let preferred = file.preferredLoadAddress else {
            throw RuntimeResolutionError.metadataUnavailable(
                "Named virtual entries require a 64-bit absolute table"
            )
        }
        let code = file.sections.filter {
            $0.flags.attributes.contains(.pure_instructions)
                || $0.flags.attributes.contains(.some_instructions)
        }
        var symbols: [UInt64: [[UInt8]: String]] = [:]
        func add(_ name: String, at address: UInt64) {
            guard !name.isEmpty,
                code.contains(where: {
                    $0.address >= 0 && $0.size > 0 && address >= UInt64($0.address)
                        && address - UInt64($0.address) < UInt64($0.size)
                })
            else { return }
            symbols[address, default: [:]][Array(name.utf8)] = name
        }
        for symbol in file.symbols64.map(Array.init) ?? [] {
            // STABS records can share a function address without defining an alias.
            guard let flags = symbol.nlist.flags, flags.rawValue & N_STAB == 0,
                flags.type == .sect, symbol.offset >= 0
            else { continue }
            add(symbol.name, at: UInt64(symbol.offset))
        }
        if let trie = file.exportTrie {
            for symbol in trie.exportedSymbols {
                if let offset = symbol.offset, offset >= 0 {
                    let address = preferred.addingReportingOverflow(UInt64(offset))
                    if !address.overflow { add(symbol.name, at: address.partialValue) }
                }
            }
        }
        let imports = file.dyldChainedFixups?.imports ?? []
        var targets: [UInt64: Result<Target, RuntimeResolutionError>] = [:]
        for entry in try original.chainedPointers() {
            guard entry.width == 8 else {
                targets[entry.address] = .failure(
                    .metadataUnavailable(
                        "Original virtual entry uses a non-64-bit fixup; supply explicit adapter metadata"
                    )
                )
                continue
            }
            do {
                let names: [String]
                let authentication: RuntimePointerAuthentication
                if let bind = entry.pointer.fixupInfo.bind {
                    guard imports.indices.contains(bind.ordinal) else {
                        throw RuntimeResolutionError.metadataUnavailable(
                            "Virtual entry has an invalid import ordinal"
                        )
                    }
                    let item = ImportMetadata.chainedImport(imports[bind.ordinal])
                    guard bind.signExtendedAddend &+ UInt64(bitPattern: item.addend) == 0,
                        let name = file.dyldChainedFixups?.symbolName(for: item.nameOffset)
                    else {
                        throw RuntimeResolutionError.metadataUnavailable(
                            "Virtual entry needs a named zero-addend binding"
                        )
                    }
                    names = [name]
                    authentication = try OriginalImageMetadata.authentication(bind)
                } else if let rebase = entry.pointer.fixupInfo.rebase {
                    // Decode the original target, not the current slot. The latter
                    // can already contain a hook and has lost declaration identity.
                    let raw = rebase.unpackedTarget
                    let format = entry.pointer.fixupInfo.pointerFormat
                    let absolute =
                        !rebase.isAuth
                        && (format == ._64 || format == .arm64e || format == .arm64e_firmware)
                    let target = absolute ? (raw, false) : preferred.addingReportingOverflow(raw)
                    guard !target.1 else {
                        throw RuntimeResolutionError.metadataUnavailable(
                            "Virtual entry target overflow"
                        )
                    }
                    names = Array(symbols[target.0]?.values ?? [:].values)
                    authentication = try OriginalImageMetadata.authentication(rebase)
                } else {
                    continue
                }
                targets[entry.address] = .success(
                    Target(symbols: names, authentication: authentication)
                )
            } catch let error as RuntimeResolutionError { targets[entry.address] = .failure(error) }
        }
        self.targets = targets
    }

    private func originalNull(at address: UInt64) throws -> Bool {
        let value = Int64(bitPattern: address).subtractingReportingOverflow(image.identity.slide)
        guard !value.overflow else {
            throw RuntimeResolutionError.metadataUnavailable(
                "Original virtual entry address overflow"
            )
        }
        let unslid = UInt64(bitPattern: value.partialValue)
        guard
            let segment = segments.first(where: {
                unslid >= $0.address && unslid - $0.address < $0.size
            })
        else {
            throw RuntimeResolutionError.metadataUnavailable(
                "Original virtual entry lies outside its image"
            )
        }
        let offset = unslid - segment.address
        guard segment.size - offset >= 8 else {
            throw RuntimeResolutionError.metadataUnavailable(
                "Original virtual entry exceeds its segment"
            )
        }
        if offset >= segment.fileSize { return true }
        guard segment.fileSize - offset >= 8 else {
            throw RuntimeResolutionError.metadataUnavailable(
                "Original virtual entry crosses its file-backed range"
            )
        }
        let position = segment.file.addingReportingOverflow(offset)
        guard !position.overflow, let position = Int(exactly: position.partialValue) else {
            throw RuntimeResolutionError.metadataUnavailable(
                "Original virtual entry file offset overflow"
            )
        }
        let final = position.addingReportingOverflow(headerOffset)
        guard !final.overflow else {
            throw RuntimeResolutionError.metadataUnavailable(
                "Original virtual entry header offset overflow"
            )
        }
        return try source.withLock { result in
            try OriginalImageMetadata.read(UInt64.self, from: result.get(), at: final.partialValue)
                == 0
        }
    }

    package func match(
        named name: String,
        addressPoint: UInt,
        entryCount: Int
    ) throws -> RuntimeVirtualEntryResolution {
        guard !name.isEmpty, !name.utf8.contains(0) else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "Use a qualified C++ method declaration"
            )
        }
        let declaration = RuntimeDeclaration(name: name, language: .cxx)
        let key = DeclarationKey.make(name)
        var found: [RuntimeVirtualEntryResolution] = []
        for index in 0..<entryCount {
            let address = UInt64(addressPoint) + UInt64(index) * 8
            guard let target = targets[address] else {
                if try originalNull(at: address) { continue }
                throw RuntimeResolutionError.metadataUnavailable(
                    "No original absolute fixup identifies virtual entry \(index); supply explicit adapter metadata"
                )
            }
            let info = try target.get()
            guard !info.symbols.isEmpty else {
                throw RuntimeResolutionError.metadataUnavailable(
                    "Original virtual entry \(index) has no recoverable symbol identity; supply explicit adapter metadata"
                )
            }
            let parsed = declarations(at: address, for: info)
            guard parsed.declarations.contains(key) else { continue }
            guard let symbol = parsed.uniqueSymbol else {
                throw RuntimeResolutionError.ambiguousDeclaration(
                    declaration,
                    candidates: info.symbols.sorted()
                )
            }
            found.append(
                .init(
                    image: image,
                    index: index,
                    symbol: symbol,
                    authentication: info.authentication
                )
            )
        }
        guard let result = found.first else {
            throw RuntimeResolutionError.declarationNotFound(declaration)
        }
        guard found.count == 1 else {
            throw RuntimeResolutionError.ambiguousDeclaration(
                declaration,
                candidates: found.map { "entry \($0.index): \($0.symbol)" }
            )
        }
        return result
    }
}
