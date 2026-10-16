import ABIBridgeCore
import MachO
import MachOKit

package struct RuntimeImageArchitecture: Sendable, Hashable {
    package let cpuType: Int32
    package let cpuSubtype: Int32
}

package struct RuntimeImageSection: Sendable, Hashable {
    package let segmentName: String
    package let name: String
    package let addressRange: Range<UInt64>
}

package struct RuntimeImageMetadata: Sendable {
    package let image: RuntimeImage
    package let is64Bit: Bool
    package let architecture: RuntimeImageArchitecture
    package let sections: [RuntimeImageSection]
    package let functionStartAddresses: [UInt64]?
}

package enum ImageMetadataReader {
    private struct Segment {
        let address: UInt64
        let memorySize: UInt64
        let fileOffset: UInt64
        let fileSize: UInt64
    }

    private struct Bytes {
        let value: [UInt8]
        var swapped = false

        func load<T: BitwiseCopyable>(_ type: T.Type, at offset: Int) throws -> T {
            guard offset >= 0, offset <= value.count,
                MemoryLayout<T>.size <= value.count - offset
            else { throw unavailable("The Mach-O header or command table is truncated.") }
            return value.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }

        func u32(_ offset: Int) throws -> UInt32 {
            let value = try load(UInt32.self, at: offset)
            return swapped ? value.byteSwapped : value
        }

        func u64(_ offset: Int) throws -> UInt64 {
            let value = try load(UInt64.self, at: offset)
            return swapped ? value.byteSwapped : value
        }

        func name(_ offset: Int) -> String {
            String(decoding: value[offset..<(offset + 16)].prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    package static func read(image: RuntimeImage) throws -> RuntimeImageMetadata {
        try withExtendedLifetime(image) {
            let value = try read(
                headerAddress: image.identity.headerAddress,
                slide: image.identity.slide
            )
            return RuntimeImageMetadata(
                image: image,
                is64Bit: value.is64Bit,
                architecture: value.architecture,
                sections: value.sections,
                functionStartAddresses: value.functionStartAddresses
            )
        }
    }

    package static func read(
        headerAddress: UInt64,
        slide: Int64
    ) throws -> (
        is64Bit: Bool,
        architecture: RuntimeImageArchitecture,
        sections: [RuntimeImageSection],
        functionStartAddresses: [UInt64]?
    ) {
        var header = Bytes(value: try memory(headerAddress, MemoryLayout<mach_header>.size))
        let magic = try header.u32(0)
        guard [MH_MAGIC, MH_MAGIC_64, MH_CIGAM, MH_CIGAM_64].contains(magic) else {
            throw unavailable("A thin Mach-O header is required.")
        }
        header.swapped = magic == MH_CIGAM || magic == MH_CIGAM_64
        let is64Bit = magic == MH_MAGIC_64 || magic == MH_CIGAM_64
        let headerSize =
            is64Bit ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
        let architecture = RuntimeImageArchitecture(
            cpuType: Int32(bitPattern: try header.u32(4)),
            cpuSubtype: Int32(bitPattern: try header.u32(8))
        )
        let commandCount = try header.u32(16)
        guard let commandSize = Int(exactly: try header.u32(20)) else {
            throw unavailable("The command table size is not representable.")
        }
        let (commandAddress, overflow) = headerAddress.addingReportingOverflow(UInt64(headerSize))
        guard !overflow else { throw unavailable("The command table address overflows.") }
        let bytes = Bytes(
            value: try memory(commandAddress, commandSize),
            swapped: header.swapped
        )
        var sections: [RuntimeImageSection] = []
        var textAddress: UInt64?
        var linkedit: Segment?
        var functionStarts: (offset: UInt64, size: Int)?
        var offset = 0
        for _ in 0..<commandCount {
            let kind = try bytes.u32(offset)
            guard let length = Int(exactly: try bytes.u32(offset + 4)),
                length >= MemoryLayout<load_command>.size,
                offset <= bytes.value.count, length <= bytes.value.count - offset
            else { throw unavailable("A Mach-O command exceeds the command table.") }

            if kind == LoadCommandType.segment64.rawValue
                || kind == LoadCommandType.segment.rawValue
            {
                let wide = kind == LoadCommandType.segment64.rawValue
                let segmentSize =
                    wide
                    ? MemoryLayout<segment_command_64>.size : MemoryLayout<segment_command>.size
                let sectionSize = wide ? MemoryLayout<section_64>.size : MemoryLayout<section>.size
                guard length >= segmentSize else {
                    throw unavailable("A segment command is truncated.")
                }
                func field(_ index: Int) throws -> UInt64 {
                    try wide
                        ? bytes.u64(offset + 24 + index * 8)
                        : UInt64(bytes.u32(offset + 24 + index * 4))
                }
                let segment = try Segment(
                    address: field(0),
                    memorySize: field(1),
                    fileOffset: field(2),
                    fileSize: field(3)
                )
                let segmentName = bytes.name(offset + 8)
                if segmentName == "__TEXT" { textAddress = segment.address }
                if segmentName == "__LINKEDIT" { linkedit = segment }
                guard let sectionCount = Int(exactly: try bytes.u32(offset + (wide ? 64 : 48))),
                    sectionCount <= (length - segmentSize) / sectionSize
                else {
                    throw unavailable("Sections exceed their segment command.")
                }
                for index in 0..<sectionCount {
                    let start = offset + segmentSize + index * sectionSize
                    let address = try wide ? bytes.u64(start + 32) : UInt64(bytes.u32(start + 32))
                    let size = try wide ? bytes.u64(start + 40) : UInt64(bytes.u32(start + 36))
                    guard let lowerBound = SymbolIndex.slid(address, by: slide),
                        size <= UInt64.max - lowerBound
                    else { throw unavailable("A section address range overflows.") }
                    sections.append(
                        RuntimeImageSection(
                            segmentName: bytes.name(start + 16),
                            name: bytes.name(start),
                            addressRange: lowerBound..<(lowerBound + size)
                        )
                    )
                }
            } else if kind == LoadCommandType.functionStarts.rawValue {
                guard length >= MemoryLayout<linkedit_data_command>.size else {
                    throw unavailable("The function-starts command is truncated.")
                }
                guard let size = Int(exactly: try bytes.u32(offset + 12)) else {
                    throw unavailable("The function-starts table size is not representable.")
                }
                functionStarts = (UInt64(try bytes.u32(offset + 8)), size)
            }
            offset += length
        }

        let addresses: [UInt64]?
        if let command = functionStarts {
            if command.size == 0 {
                addresses = []
            } else {
                guard let linkedit, command.offset >= linkedit.fileOffset else {
                    throw unavailable("Function starts have no matching __LINKEDIT storage.")
                }
                let delta = command.offset - linkedit.fileOffset
                guard delta <= linkedit.fileSize, UInt64(command.size) <= linkedit.fileSize - delta,
                    delta <= linkedit.memorySize,
                    UInt64(command.size) <= linkedit.memorySize - delta,
                    let base = SymbolIndex.slid(linkedit.address, by: slide)
                else { throw unavailable("Function starts exceed their __LINKEDIT storage.") }
                let (address, overflow) = base.addingReportingOverflow(delta)
                guard !overflow else { throw unavailable("The function-starts address overflows.") }
                addresses = try decodeFunctionStarts(
                    memory(address, command.size),
                    textAddress: textAddress,
                    slide: slide
                )
            }
        } else {
            addresses = nil
        }
        return (is64Bit, architecture, sections, addresses)
    }

    // MachOKit's sequence does not stop at the zero terminator or bound each
    // ULEB128 read. Decode owned bytes so malformed metadata remains an error.
    private static func decodeFunctionStarts(
        _ bytes: [UInt8],
        textAddress: UInt64?,
        slide: Int64
    ) throws -> [UInt64] {
        var addresses: [UInt64] = []
        var previous = textAddress
        var offset = 0
        while offset < bytes.count {
            var delta: UInt64 = 0
            var shift = 0
            while true {
                guard offset < bytes.count else {
                    throw unavailable("A function-starts ULEB128 is truncated.")
                }
                let byte = bytes[offset]
                offset += 1
                let payload = UInt64(byte & 0x7f)
                guard shift < 64, payload <= UInt64.max >> shift else {
                    throw unavailable("A function-starts ULEB128 overflows.")
                }
                delta |= payload << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            if delta == 0 { return addresses }
            guard let previousAddress = previous else {
                throw unavailable("Function starts have no __TEXT base address.")
            }
            let (address, overflow) = previousAddress.addingReportingOverflow(delta)
            guard !overflow, let loadedAddress = SymbolIndex.slid(address, by: slide) else {
                throw unavailable("A function-start address overflows.")
            }
            addresses.append(loadedAddress)
            previous = address
        }
        throw unavailable("The function-starts table has no terminator.")
    }

    private static func memory(_ address: UInt64, _ count: Int) throws -> [UInt8] {
        guard let address = UInt(exactly: address) else {
            throw unavailable("An image address is not representable.")
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { ABIReadMemory(address, count, $0.baseAddress) }
        guard result.status == ABIMemoryReadComplete else {
            throw unavailable("Image memory could not be read (Mach error \(result.systemError)).")
        }
        return bytes
    }

    private static func unavailable(_ message: String) -> RuntimeResolutionError {
        .metadataUnavailable(message)
    }
}
