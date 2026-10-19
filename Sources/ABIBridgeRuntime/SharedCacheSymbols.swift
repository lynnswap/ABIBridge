import Foundation
import MachO
import MachOKit

package final class SharedCacheSymbols {
    private lazy var loadedCache = DyldCacheLoaded.current
    private lazy var fullCache = FullDyldCache.host
    private lazy var filesByUUID: [UUID: MachOFile] = {
        guard let fullCache else { return [:] }
        var files: [UUID: MachOFile] = [:]
        for file in fullCache.machOFiles() {
            for command in file.loadCommands {
                if case .uuid(let uuid) = command, files[uuid.uuid] == nil {
                    files[uuid.uuid] = file
                    break
                }
            }
        }
        return files
    }()
    private var filesByCache: [UUID: [SymbolFile]] = [:]
    private var rangesByTable: [UUID: [UInt64: Range<Int>]] = [:]

    package enum Source: Hashable, Sendable { case loaded, file }

    package struct Extraction {
        package let symbols: [IndexedSymbol]
        package let foundDefinitions: Bool
        package var coveredQueries: [SymbolQuery] = []
    }

    package struct CapturedSymbols {
        package typealias Reader = ((UnsafePointer<CChar>, UInt64) -> Void) -> Void
        private let slide: Int64
        private let readers: [Reader]
        // Complete image captures can serve multiple declarations in one traversal.
        package let imageIdentity: RuntimeImageIdentity?

        package init(
            slide: Int64,
            readers: [Reader],
            imageIdentity: RuntimeImageIdentity? = nil
        ) {
            self.slide = slide
            self.readers = readers
            self.imageIdentity = imageIdentity
        }

        package func extract(
            matching query: SymbolQuery,
            includingSwiftFallback: Bool,
            relatedQueries: [SymbolQuery] = []
        ) -> Extraction {
            var scopes: Set<SymbolCandidateScope> = [query.candidateScope]
            let queries =
                [query] + relatedQueries.filter { scopes.insert($0.candidateScope).inserted }
            var result: [IndexedSymbol] = []
            var foundDefinitions = false
            SymbolCandidateMatcher(queries).withMatcher { accepts in
                func record(_ name: UnsafePointer<CChar>, _ value: UInt64) {
                    guard let address = SymbolIndex.slid(value, by: slide) else { return }
                    foundDefinitions = true
                    if accepts(name),
                        includingSwiftFallback || SwiftModuleFilter.knownModulePrefix(name) != false
                    {
                        result.append(
                            IndexedSymbol(
                                name: String(cString: name),
                                address: address,
                                source: .sharedCache
                            )
                        )
                    }
                }
                for read in readers { read(record) }
            }
            return Extraction(
                symbols: result,
                foundDefinitions: foundDefinitions,
                coveredQueries: queries
            )
        }
    }

    // Capture dyld/cache discovery and file owners before publishing a shared
    // scan. Readers below only visit the captured table or mapped file range.
    package func capture(in image: RuntimeImage, source: Source) -> CapturedSymbols? {
        let macho = MachOImage(
            ptr: UnsafePointer<mach_header>(bitPattern: UInt(image.identity.headerAddress))!
        )
        guard macho.header.flags.contains(.dylib_in_cache),
            macho.is64Bit,
            let text = macho.segments64.first(where: { $0.segmentName == "__TEXT" })
        else { return nil }
        var readers: [CapturedSymbols.Reader] = []
        switch source {
        case .loaded:
            if let cache = loadedCache, let cacheSlide = cache.slide,
                cacheSlide == image.identity.slide,
                UInt64(text.virtualMemoryAddress) >= cache.mainCacheHeader.sharedRegionStart
            {
                let offset =
                    UInt64(text.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
                if let info = cache.localSymbolsInfo, let symbols = info.symbols64(in: cache),
                    let range = localRange(
                        offset,
                        table: cache.mainCacheHeader.uuid,
                        entries: Array(info.entries(in: cache)),
                        count: symbols.count
                    )
                {
                    readers.append { record in
                        withExtendedLifetime(cache) {
                            for index in range {
                                let symbol = symbols.symbols.advanced(by: index).pointee
                                let name = symbols.stringBase.advanced(
                                    by: numericCast(symbol.n_un.n_strx)
                                )
                                let address = symbols.addressStart + numericCast(symbol.n_value)
                                if address >= 0 { record(name, UInt64(address)) }
                            }
                        }
                    }
                }
                readers += captureSymbolFiles(header: cache.mainCacheHeader, offset: offset)
            }
        case .file:
            if let cache = fullCache, let expectedUUID = image.identity.uuid,
                let file = filesByUUID[expectedUUID],
                let fileText = file.segments64.first(where: { $0.segmentName == "__TEXT" }),
                UInt64(fileText.virtualMemoryAddress) >= cache.mainCacheHeader.sharedRegionStart
            {
                let offset =
                    UInt64(fileText.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
                if let info = cache.localSymbolsInfo, let symbols = info.symbols64(in: cache),
                    let range = localRange(
                        offset,
                        table: cache.mainCacheHeader.uuid,
                        entries: Array(info.entries(in: cache)),
                        count: symbols.count
                    )
                {
                    readers.append { record in
                        withExtendedLifetime(cache) {
                            for index in range {
                                let symbol = symbols[index]
                                if symbol.offset >= 0 {
                                    symbol.name.withCString { record($0, UInt64(symbol.offset)) }
                                }
                            }
                        }
                    }
                }
                readers += captureSymbolFiles(header: cache.mainCacheHeader, offset: offset)
            }
        }
        return CapturedSymbols(
            slide: image.identity.slide,
            readers: readers,
            imageIdentity: image.identity
        )
    }

    private func localRange(
        _ offset: UInt64,
        table: UUID,
        entries: @autoclosure () -> [any DyldCacheLocalSymbolsEntryProtocol],
        count: Int
    ) -> Range<Int>? {
        if rangesByTable[table] == nil {
            var ranges: [UInt64: Range<Int>] = [:]
            var seen: Set<UInt64> = []
            for entry in entries() {
                let address = UInt64(entry.dylibOffset)
                guard seen.insert(address).inserted,
                    entry.nlistStartIndex >= 0, entry.nlistCount >= 0,
                    entry.nlistStartIndex <= count,
                    entry.nlistCount <= count - entry.nlistStartIndex
                else { continue }
                ranges[address] = entry.nlistStartIndex..<(entry.nlistStartIndex + entry.nlistCount)
            }
            rangesByTable[table] = ranges
        }
        return rangesByTable[table]?[offset]
    }

    private func captureSymbolFiles(
        header: DyldCacheHeader,
        offset: UInt64
    ) -> [CapturedSymbols.Reader] {
        if filesByCache[header.uuid] == nil {
            filesByCache[header.uuid] = []
            for url in Self.symbolFileURLs() {
                guard let file = try? DyldCache(subcacheUrl: url, mainCacheHeader: header),
                    file.header.uuid == header.symbolFileUUID,
                    let symbols = SymbolFile(file)
                else { continue }
                // Several Cryptex paths can expose the same symbol file. Its
                // UUID identifies the complete table, so read it only once.
                filesByCache[header.uuid] = [symbols]
                break
            }
        }
        var readers: [CapturedSymbols.Reader] = []
        for file in filesByCache[header.uuid] ?? [] {
            guard
                let range = localRange(
                    offset,
                    table: file.cache.header.uuid,
                    entries: Array(file.info.entries(in: file.cache)),
                    count: file.symbols.count
                )
            else { continue }
            if let mapping = file.mapping {
                readers.append { record in mapping.forEach(in: range, record: record) }
            } else {
                readers.append { record in
                    for index in range {
                        let symbol = file.symbols[index]
                        if symbol.offset >= 0 {
                            symbol.name.withCString { record($0, UInt64(symbol.offset)) }
                        }
                    }
                }
            }
        }
        return readers
    }

    private struct SymbolFile {
        let cache: DyldCache
        let info: DyldCacheLocalSymbolsInfo
        let symbols: MachOFile.Symbols64
        let mapping: MappedSymbols?

        init?(_ cache: DyldCache) {
            guard let info = cache.localSymbolsInfo, let symbols = info.symbols64(in: cache) else {
                return nil
            }
            self.cache = cache
            self.info = info
            self.symbols = symbols
            mapping = MappedSymbols(cache, info: info)
        }
    }

    // Keep names in the mapped string table until the query accepts them. The
    // ordinary MachOKit collection remains available when mapping is unavailable.
    package struct MappedSymbols {
        package let data: Data
        package let symbolStart: Int
        package let strings: Range<Int>

        package init?(_ cache: DyldCache, info: DyldCacheLocalSymbolsInfo) {
            guard let data = try? Data(contentsOf: cache.url, options: .alwaysMapped),
                data.count >= MemoryLayout<DyldCacheHeader.Layout>.size,
                data.withUnsafeBytes({
                    UUID(uuid: $0.loadUnaligned(as: DyldCacheHeader.Layout.self).uuid)
                }) == cache.header.uuid
            else { return nil }
            self.init(
                data: data,
                localSymbolsOffset: cache.header.localSymbolsOffset,
                layout: info.layout
            )
        }

        package init?(
            data: Data,
            localSymbolsOffset: UInt64,
            layout: DyldCacheLocalSymbolsInfo.Layout
        ) {
            guard let base = Int(exactly: localSymbolsOffset), base <= data.count,
                let namesOffset = Int(exactly: layout.stringsOffset),
                namesOffset <= data.count - base,
                let namesCount = Int(exactly: layout.stringsSize),
                namesCount <= data.count - base - namesOffset,
                let symbolsOffset = Int(exactly: layout.nlistOffset),
                symbolsOffset <= data.count - base,
                let count = Int(exactly: layout.nlistCount),
                count <= (data.count - base - symbolsOffset) / MemoryLayout<nlist_64>.stride
            else { return nil }
            self.data = data
            symbolStart = base + symbolsOffset
            strings = (base + namesOffset)..<(base + namesOffset + namesCount)
        }

        package func forEach(in range: Range<Int>, record: (UnsafePointer<CChar>, UInt64) -> Void) {
            data.withUnsafeBytes { bytes in
                for index in range {
                    let entry = bytes.loadUnaligned(
                        fromByteOffset: symbolStart + index * MemoryLayout<nlist_64>.stride,
                        as: nlist_64.self
                    )
                    guard let offset = Int(exactly: entry.n_un.n_strx), offset < strings.count
                    else { continue }
                    let name = bytes.baseAddress!.advanced(by: strings.lowerBound + offset)
                    guard memchr(name, 0, strings.count - offset) != nil else { continue }
                    record(name.assumingMemoryBound(to: CChar.self), entry.n_value)
                }
            }
        }
    }

    private static func symbolFileURLs() -> [URL] {
        var urls: [URL] = []
        if let path = DyldCache.host?.url.path {
            urls.append(URL(fileURLWithPath: path.hasSuffix(".symbols") ? path : path + ".symbols"))
        }
        #if os(macOS)
        let directories = [
            "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld", "/System/Library/dyld",
        ]
        #else
        let directories = [
            "/System/Library/Caches/com.apple.dyld",
            "/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
            "/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
        ]
        #endif
        for path in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            urls += names.filter { $0.hasPrefix("dyld_shared_cache_") && $0.hasSuffix(".symbols") }
                .map { URL(fileURLWithPath: path).appendingPathComponent($0) }
        }
        return Array(Set(urls))
    }
}
