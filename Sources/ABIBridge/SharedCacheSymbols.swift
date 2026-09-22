import Foundation
import MachO
import MachOKit

/// Isolated by ABIRuntime. Cache files supply names and unslid addresses only;
/// addresses are subsequently checked against the retained image's sections.
final class SharedCacheSymbols {
    private lazy var loadedCache = DyldCacheLoaded.current
    private lazy var fullCache = FullDyldCache.host
    private var filesByCache: [UUID: [DyldCache]] = [:]

    func symbols(in image: NativeImage) -> [IndexedSymbol] {
        let macho = MachOImage(ptr: UnsafePointer<mach_header>(bitPattern: UInt(image.identity.headerAddress))!)
        guard macho.header.flags.contains(.dylib_in_cache),
              macho.is64Bit,
              let text = macho.segments64.first(where: { $0.segmentName == "__TEXT" }) else { return [] }
        var result: [IndexedSymbol] = []
        func record(_ name: String, _ address: UInt64) {
            if let address = SymbolIndex.slid(address, by: image.identity.slide) {
                result.append(IndexedSymbol(name: name, address: address, source: .sharedCache))
            }
        }
        if let cache = loadedCache, let cacheSlide = cache.slide, cacheSlide == image.identity.slide,
           UInt64(text.virtualMemoryAddress) >= cache.mainCacheHeader.sharedRegionStart {
            let offset = UInt64(text.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
            if let info = cache.localSymbolsInfo, let symbols = info.symbols64(in: cache),
               let range = localRange(offset, entries: Array(info.entries(in: cache)), count: symbols.count) {
                for index in range {
                    let symbol = symbols.symbols.advanced(by: index).pointee
                    let name = symbols.stringBase.advanced(by: numericCast(symbol.n_un.n_strx))
                    let address = symbols.addressStart + numericCast(symbol.n_value)
                    if address >= 0 { record(String(cString: name), UInt64(address)) }
                }
            }
            readSymbolFiles(header: cache.mainCacheHeader, offset: offset, record: record)
        }
        if result.isEmpty, let cache = fullCache, let expectedUUID = image.identity.uuid,
           let file = cache.machOFiles().first(where: { file in
               file.loadCommands.contains { command in
                   if case .uuid(let uuid) = command { return uuid.uuid == expectedUUID }
                   return false
               }
           }), let fileText = file.segments64.first(where: { $0.segmentName == "__TEXT" }),
           UInt64(fileText.virtualMemoryAddress) >= cache.mainCacheHeader.sharedRegionStart {
            let offset = UInt64(fileText.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
            if let info = cache.localSymbolsInfo, let symbols = info.symbols64(in: cache),
               let range = localRange(offset, entries: Array(info.entries(in: cache)), count: symbols.count) {
                for index in range {
                    let symbol = symbols[index]
                    if symbol.offset >= 0 { record(symbol.name, UInt64(symbol.offset)) }
                }
            }
            readSymbolFiles(header: cache.mainCacheHeader, offset: offset, record: record)
        }
        return result
    }

    private func localRange(
        _ offset: UInt64, entries: [any DyldCacheLocalSymbolsEntryProtocol], count: Int
    ) -> Range<Int>? {
        guard let entry = entries.first(where: { UInt64($0.dylibOffset) == offset }),
              entry.nlistStartIndex >= 0, entry.nlistCount >= 0,
              entry.nlistStartIndex <= count, entry.nlistCount <= count - entry.nlistStartIndex else { return nil }
        return entry.nlistStartIndex..<(entry.nlistStartIndex + entry.nlistCount)
    }

    private func readSymbolFiles(
        header: DyldCacheHeader, offset: UInt64, record: (String, UInt64) -> Void
    ) {
        if filesByCache[header.uuid] == nil {
            filesByCache[header.uuid] = Self.symbolFileURLs().compactMap { url in
                guard let file = try? DyldCache(subcacheUrl: url, mainCacheHeader: header),
                      file.header.uuid == header.symbolFileUUID else { return nil }
                return file
            }
        }
        for file in filesByCache[header.uuid] ?? [] {
            guard let info = file.localSymbolsInfo, let symbols = info.symbols64(in: file),
                  let range = localRange(offset, entries: Array(info.entries(in: file)), count: symbols.count) else { continue }
            for index in range {
                let symbol = symbols[index]
                if symbol.offset >= 0 { record(symbol.name, UInt64(symbol.offset)) }
            }
        }
    }

    private static func symbolFileURLs() -> [URL] {
        var urls: [URL] = []
        if let path = DyldCache.host?.url.path {
            urls.append(URL(fileURLWithPath: path.hasSuffix(".symbols") ? path : path + ".symbols"))
        }
        #if os(macOS)
        let directories = ["/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld", "/System/Library/dyld"]
        #else
        let directories = ["/System/Library/Caches/com.apple.dyld", "/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld", "/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld"]
        #endif
        for path in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            urls += names.filter { $0.hasPrefix("dyld_shared_cache_") && $0.hasSuffix(".symbols") }
                .map { URL(fileURLWithPath: path).appendingPathComponent($0) }
        }
        return Array(Set(urls))
    }
}
