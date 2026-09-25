import ABIBridgeCore
import Foundation
import MachO
import MachOKit

/// A copied symbol name recorded by a lazy-load dependency.
///
/// This describes an import, not a resolved address, storage kind, or call signature.
public struct NativeLazySymbol: Sendable {
    /// The exact recorded spelling, or nil for an unreadable string.
    public let rawName: String?
    /// A demangled Swift/C++ name, or the original name without a Mach-O underscore.
    /// Nil means that the recorded string could not be read.
    public let name: String?

    init(rawName: String?) {
        self.rawName = rawName
        name = rawName.map {
            DeclarationKey.demangle($0, language: .swift)
                ?? DeclarationKey.demangle($0, language: .cxx)
                ?? DeclarationKey.demangle($0, language: .c)!
        }
    }
}

/// Copied diagnostics for one `LC_LAZY_LOAD_DYLIB_INFO` command.
///
/// Optional fields represent unavailable metadata. An empty symbols array means
/// the command records no symbols; nil means the array could not be read.
/// Results contain no borrowed addresses and may outlive their source image.
public struct NativeLazyLibrary: Sendable {
    /// Byte offset of the command from its Mach-O header.
    public let commandOffset: UInt64
    /// The recorded install path, including any unresolved loader tokens.
    public let path: String?
    /// Whether dyld allows this dependency to be absent, or nil if unknown.
    public let isOptional: Bool?
    /// Whether symbols were prebound, independently of library initialization.
    public let areSymbolsPrebound: Bool?
    /// Whether dyld's live initialized flag was nonzero when copied.
    /// Always nil for file inspection; disk contents cannot establish live state.
    public let isInitialized: Bool?
    /// Symbol names in their recorded order. Individual unreadable strings have nil names.
    public let symbols: [NativeLazySymbol]?
}

extension ABIRuntime {
    /// Copies lazy-load dependency diagnostics from a retained image.
    ///
    /// Reading does not load a dependency or walk its mutable binding chain.
    /// The initialized flag is an observation, not synchronization with dyld.
    /// Malformed command payloads remain represented with unavailable fields.
    /// - Parameter image: The loaded image declaring the dependencies.
    /// - Returns: Commands in load-command order, or an empty array if none exist.
    /// - Throws: `ABIResolutionError.metadataUnavailable` if the header or command table cannot be read.
    public func lazyLibraries(in image: NativeImage) throws -> [NativeLazyLibrary] {
        try LazyLibraryReader.read(image: image)
    }
}

extension ABIRuntime {
    /// Copies lazy-load metadata from a thin Mach-O file without loading it.
    ///
    /// Results do not claim that any recorded library is initialized in the
    /// current process. Universal/fat files are not accepted by this operation.
    /// - Parameter url: A thin Mach-O file, which is read into owned storage.
    /// - Returns: One diagnostic value per lazy-load command, including malformed payloads.
    /// - Throws: The file-reading error, or `ABIResolutionError.metadataUnavailable` for an invalid container.
    public func lazyLibraries(inFileAt url: URL) throws -> [NativeLazyLibrary] {
        try LazyLibraryReader.read(file: url)
    }
}

// MachOKit's convenience collection drops malformed payloads and reads live
// pointers directly. Diagnostics instead retain every command and decode bounded
// copies, using MachOKit's C-backed layout rather than defining another layout.
enum LazyLibraryReader {
    private struct Segment {
        let name: String
        let address: UInt64
        let memorySize: UInt64
        let fileOffset: UInt64
        let fileSize: UInt64
    }

    private struct Command {
        let offset: UInt64
        let dataOffset: UInt64?
        let dataSize: Int?
    }

    private struct ImageAddress {
        let header: UInt64
        let slide: Int64
    }

    private struct Bytes {
        let value: [UInt8]
        var swapped = false

        func load<T: BitwiseCopyable>(_ type: T.Type, at offset: Int) -> T? {
            guard offset >= 0, offset <= value.count,
                  MemoryLayout<T>.size <= value.count - offset else { return nil }
            return value.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }

        func u32(_ offset: Int) -> UInt32? {
            load(UInt32.self, at: offset).map { swapped ? $0.byteSwapped : $0 }
        }

        func u64(_ offset: Int) -> UInt64? {
            load(UInt64.self, at: offset).map { swapped ? $0.byteSwapped : $0 }
        }

        func string(_ offset: Int, minimum: Int = 0) -> String? {
            guard offset >= minimum, offset < value.count,
                  let end = value[offset...].firstIndex(of: 0) else { return nil }
            return String(bytes: value[offset..<end], encoding: .utf8)
        }
    }

    static func read(file: URL) throws -> [NativeLazyLibrary] {
        let bytes = [UInt8](try Data(contentsOf: file))
        return try read(readHeader: { offset, count in
            guard offset <= bytes.count, count <= bytes.count - offset else { return nil }
            return Array(bytes[offset..<(offset + count)])
        }, image: nil, fileBytes: bytes)
    }

    static func read(image: NativeImage) throws -> [NativeLazyLibrary] {
        try withExtendedLifetime(image) {
            try read(headerAddress: image.identity.headerAddress, slide: image.identity.slide)
        }
    }

    static func read(headerAddress: UInt64, slide: Int64) throws -> [NativeLazyLibrary] {
        try read(readHeader: { offset, count in
            let (address, overflow) = headerAddress.addingReportingOverflow(UInt64(offset))
            return overflow ? nil : memory(address, count)
        }, image: ImageAddress(header: headerAddress, slide: slide), fileBytes: nil)
    }

    private static func memory(_ address: UInt64, _ count: Int) -> [UInt8]? {
        guard let address = UInt(exactly: address) else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { ABIReadMemory(address, count, $0.baseAddress) }
        return result.status == ABIMemoryReadComplete ? bytes : nil
    }

    private static func contains(_ start: UInt64, _ size: UInt64, _ offset: UInt64, _ count: UInt64) -> Bool {
        offset >= start && offset - start <= size && count <= size - (offset - start)
    }

    private static func read(
        readHeader: (Int, Int) -> [UInt8]?, image: ImageAddress?, fileBytes: [UInt8]?
    ) throws -> [NativeLazyLibrary] {
        func invalid() -> ABIResolutionError { .metadataUnavailable("A readable thin Mach-O header and command table are required.") }
        guard let headerBytes = readHeader(0, MemoryLayout<mach_header>.size) else { throw invalid() }
        var header = Bytes(value: headerBytes)
        guard let magic = header.u32(0), [MH_MAGIC, MH_MAGIC_64, MH_CIGAM, MH_CIGAM_64].contains(magic) else { throw invalid() }
        header.swapped = magic == MH_CIGAM || magic == MH_CIGAM_64
        let is64 = magic == MH_MAGIC_64 || magic == MH_CIGAM_64
        let headerSize = is64 ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
        guard let count = header.u32(16), let size = header.u32(20), let size = Int(exactly: size),
              let commandBytes = readHeader(headerSize, size) else { throw invalid() }
        let bytes = Bytes(value: commandBytes, swapped: header.swapped)
        var segments: [Segment] = []
        var commands: [Command] = []
        var offset = 0
        for _ in 0..<count {
            guard let kind = bytes.u32(offset), let length = bytes.u32(offset + 4),
                  let length = Int(exactly: length), length >= 8,
                  offset <= size, length <= size - offset else { throw invalid() }
            if kind == LoadCommandType.lazyLoadDylibInfo.rawValue {
                let hasPayloadRange = length >= MemoryLayout<linkedit_data_command>.size
                commands.append(Command(
                    offset: UInt64(headerSize + offset),
                    dataOffset: hasPayloadRange ? bytes.u32(offset + 8).map(UInt64.init) : nil,
                    dataSize: hasPayloadRange ? bytes.u32(offset + 12).flatMap { Int(exactly: $0) } : nil
                ))
            } else if (kind == LoadCommandType.segment64.rawValue && length >= MemoryLayout<segment_command_64>.size)
                        || (kind == LoadCommandType.segment.rawValue && length >= MemoryLayout<segment_command>.size) {
                let name = String(decoding: bytes.value[(offset + 8)..<(offset + 24)].prefix { $0 != 0 }, as: UTF8.self)
                let wide = kind == LoadCommandType.segment64.rawValue
                func field(_ index: Int) -> UInt64 {
                    wide ? bytes.u64(offset + 24 + index * 8)! : UInt64(bytes.u32(offset + 24 + index * 4)!)
                }
                segments.append(Segment(name: name, address: field(0), memorySize: field(1), fileOffset: field(2), fileSize: field(3)))
            }
            offset += length
        }

        return commands.map { command in
            func unavailable() -> NativeLazyLibrary {
                .init(commandOffset: command.offset, path: nil, isOptional: nil,
                      areSymbolsPrebound: nil, isInitialized: nil, symbols: nil)
            }
            guard let dataOffset = command.dataOffset, let dataSize = command.dataSize,
                  dataSize >= MemoryLayout<LazyLoadDylib.Layout>.size,
                  let segment = segments.first(where: {
                      $0.name == "__LINKEDIT" && contains($0.fileOffset, $0.fileSize, dataOffset, UInt64(dataSize))
                  }) else { return unavailable() }
            let payload: [UInt8]?
            if let image {
                let delta = dataOffset - segment.fileOffset
                if contains(0, segment.memorySize, delta, UInt64(dataSize)),
                   let start = SymbolIndex.slid(segment.address, by: image.slide) {
                    let (address, overflow) = start.addingReportingOverflow(delta)
                    payload = overflow ? nil : memory(address, dataSize)
                } else { payload = nil }
            } else if let fileBytes, contains(0, UInt64(fileBytes.count), dataOffset, UInt64(dataSize)) {
                payload = Array(fileBytes[Int(dataOffset)..<(Int(dataOffset) + dataSize)])
            } else { payload = nil }
            guard let payload, var layout = Bytes(value: payload).load(LazyLoadDylib.Layout.self, at: 0) else { return unavailable() }
            if header.swapped {
                layout.loadPathOffset = layout.loadPathOffset.byteSwapped
                layout.flagImageOffset = layout.flagImageOffset.byteSwapped
                layout.flags = layout.flags.byteSwapped
                layout.symbolsCount = layout.symbolsCount.byteSwapped
                layout.symbolStringArrayOffset = layout.symbolStringArrayOffset.byteSwapped
            }
            let bytes = Bytes(value: payload, swapped: header.swapped)
            let minimum = MemoryLayout<LazyLoadDylib.Layout>.size
            let path = Int(exactly: layout.loadPathOffset).flatMap { bytes.string($0, minimum: minimum) }
            var symbols: [NativeLazySymbol]?
            if layout.symbolsCount == 0 {
                symbols = []
            } else if let start = Int(exactly: layout.symbolStringArrayOffset), start >= minimum,
                      start <= payload.count, UInt64(layout.symbolsCount) <= UInt64((payload.count - start) / 4) {
                symbols = (0..<Int(layout.symbolsCount)).map { index in
                    let name = bytes.u32(start + index * 4).flatMap { Int(exactly: $0) }
                        .flatMap { bytes.string($0, minimum: minimum) }
                    return NativeLazySymbol(rawName: name)
                }
            }
            var initialized: Bool?
            if let image {
                let (address, overflow) = image.header.addingReportingOverflow(UInt64(layout.flagImageOffset))
                if !overflow, segments.contains(where: {
                    guard let start = SymbolIndex.slid($0.address, by: image.slide) else { return false }
                    return contains(start, $0.memorySize, address, 4)
                }), let value = memory(address, 4).flatMap({ Bytes(value: $0, swapped: header.swapped).u32(0) }) {
                    initialized = value != 0
                }
            }
            return NativeLazyLibrary(commandOffset: command.offset, path: path,
                                     isOptional: layout.flags & 1 != 0, areSymbolsPrebound: layout.flags & 2 != 0,
                                     isInitialized: initialized, symbols: symbols)
        }
    }
}
