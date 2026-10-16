import ABIBridgeRuntime
import MachO
import Testing

struct ImageMetadataTests {
    @Test(arguments: [false, true])
    func preservesArchitectureSectionsAndRelocatedFunctionStarts(wide: Bool) throws {
        let fixture = ImageMetadataFixture(wide: wide)
        try fixture.withImage { address, slide in
            let result = try ImageMetadataReader.read(headerAddress: address, slide: slide)
            #expect(result.is64Bit == wide)
            #expect(result.architecture.cpuType == CPU_TYPE_ARM64_32)
            #expect(result.architecture.cpuSubtype == Int32(bitPattern: 0x8000000c))
            #expect(result.sections.map(\.name) == ["__text", "__empty"])
            #expect(result.sections.map(\.segmentName) == ["__TEXT", "__TEXT"])
            #expect(
                result.sections.map(\.addressRange) == [
                    (address + 384)..<(address + 448), (address + 448)..<(address + 448),
                ]
            )
            #expect(result.functionStartAddresses == [address + 384, address + 388])
        }
    }

    @Test func supportsNegativeSlides() throws {
        let fixture = ImageMetadataFixture(preferredAddress: UInt64(Int64.max))
        try fixture.withImage { address, slide in
            #expect(slide < 0)
            let result = try ImageMetadataReader.read(headerAddress: address, slide: slide)
            #expect(result.sections.first?.addressRange == (address + 384)..<(address + 448))
            #expect(result.functionStartAddresses == [address + 384, address + 388])
        }
    }

    @Test(arguments: [nil, [], [0, 0, 0]] as [[UInt8]?])
    func distinguishesAbsentAndEmptyFunctionStarts(payload: [UInt8]?) throws {
        let fixture = ImageMetadataFixture(payload: payload)
        try fixture.withImage { address, slide in
            let result = try ImageMetadataReader.read(headerAddress: address, slide: slide)
            #expect(result.functionStartAddresses == (payload == nil ? nil : []))
            #expect(result.sections.count == 2)
        }
    }

    @Test(
        arguments: [
            [0x80],
            [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02, 0],
            [0x01],
        ] as [[UInt8]]
    )
    func malformedFunctionStartsThrow(payload: [UInt8]) throws {
        let fixture = ImageMetadataFixture(payload: payload)
        fixture.withImage { address, slide in
            #expect(throws: RuntimeResolutionError.self) {
                try ImageMetadataReader.read(headerAddress: address, slide: slide)
            }
        }
    }

    @Test(arguments: [UInt64.max - 1, UInt64.max - 512])
    func functionAddressOverflowThrows(textAddress: UInt64) throws {
        var fixture = ImageMetadataFixture(preferredAddress: 0)
        fixture.store(textAddress, at: fixture.headerSize + 24)
        fixture.withImage { address, slide in
            #expect(throws: RuntimeResolutionError.self) {
                try ImageMetadataReader.read(headerAddress: address, slide: slide)
            }
        }
    }

    @Test func malformedSectionsThrowInsteadOfBeingOmitted() throws {
        var fixture = ImageMetadataFixture()
        fixture.store(UInt64.max, at: fixture.sectionOffset + 40)
        fixture.withImage { address, slide in
            #expect(throws: RuntimeResolutionError.self) {
                try ImageMetadataReader.read(headerAddress: address, slide: slide)
            }
        }
        fixture = ImageMetadataFixture()
        fixture.store(UInt32(3), at: fixture.headerSize + 64)
        fixture.withImage { address, slide in
            #expect(throws: RuntimeResolutionError.self) {
                try ImageMetadataReader.read(headerAddress: address, slide: slide)
            }
        }
    }

    @Test func unreadablePayloadAndMalformedCommandsThrow() throws {
        var fixture = ImageMetadataFixture()
        fixture.store(UInt64(1), at: fixture.linkeditOffset + 24)
        fixture.withImage { address, _ in
            #expect(throws: RuntimeResolutionError.self) {
                try ImageMetadataReader.read(headerAddress: address, slide: 0)
            }
        }
        fixture = ImageMetadataFixture()
        fixture.store(UInt32.max, at: fixture.headerSize + 4)
        fixture.withImage { address, slide in
            #expect(throws: RuntimeResolutionError.self) {
                try ImageMetadataReader.read(headerAddress: address, slide: slide)
            }
        }
        #expect(throws: RuntimeResolutionError.self) {
            try ImageMetadataReader.read(headerAddress: 1, slide: 0)
        }
    }
}

private struct ImageMetadataFixture {
    var bytes = [UInt8](repeating: 0, count: 1024)
    let preferredAddress: UInt64
    let headerSize: Int
    let sectionOffset: Int
    let linkeditOffset: Int

    init(
        wide: Bool = true,
        preferredAddress: UInt64? = nil,
        payload: [UInt8]? = [0x80, 0x03, 0x04, 0, 0, 0]
    ) {
        self.preferredAddress = preferredAddress ?? (wide ? 0x100000000 : 0x10000000)
        headerSize = wide ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
        let segmentSize =
            wide ? MemoryLayout<segment_command_64>.size : MemoryLayout<segment_command>.size
        let sectionSize = wide ? MemoryLayout<section_64>.size : MemoryLayout<section>.size
        sectionOffset = headerSize + segmentSize
        linkeditOffset = sectionOffset + 2 * sectionSize
        let functionStartsOffset = linkeditOffset + segmentSize
        let commandSize =
            functionStartsOffset - headerSize
            + (payload == nil ? 0 : MemoryLayout<linkedit_data_command>.size)
        store(wide ? MH_MAGIC_64 : MH_MAGIC, at: 0)
        store(CPU_TYPE_ARM64_32, at: 4)
        store(UInt32(0x8000000c), at: 8)
        store(UInt32(payload == nil ? 2 : 3), at: 16)
        store(UInt32(commandSize), at: 20)
        for (offset, name, delta, sections) in [
            (headerSize, "__TEXT", 0, 2), (linkeditOffset, "__LINKEDIT", 512, 0),
        ] {
            store(wide ? LC_SEGMENT_64 : LC_SEGMENT, at: offset)
            store(UInt32(segmentSize + sections * sectionSize), at: offset + 4)
            store(name, at: offset + 8)
            let values: [UInt64] = [self.preferredAddress + UInt64(delta), 512, UInt64(delta), 512]
            for (index, value) in values.enumerated() {
                if wide {
                    store(value, at: offset + 24 + 8 * index)
                } else {
                    store(UInt32(value), at: offset + 24 + 4 * index)
                }
            }
            store(UInt32(sections), at: offset + (wide ? 64 : 48))
        }
        for (index, name, delta, size) in [(0, "__text", 384, 64), (1, "__empty", 448, 0)] {
            let offset = sectionOffset + index * sectionSize
            store(name, at: offset)
            store("__TEXT", at: offset + 16)
            if wide {
                store(self.preferredAddress + UInt64(delta), at: offset + 32)
                store(UInt64(size), at: offset + 40)
            } else {
                store(UInt32(self.preferredAddress) + UInt32(delta), at: offset + 32)
                store(UInt32(size), at: offset + 36)
            }
        }
        if let payload {
            store(LC_FUNCTION_STARTS, at: functionStartsOffset)
            store(UInt32(MemoryLayout<linkedit_data_command>.size), at: functionStartsOffset + 4)
            store(UInt32(512), at: functionStartsOffset + 8)
            store(UInt32(payload.count), at: functionStartsOffset + 12)
            bytes.replaceSubrange(512..<(512 + payload.count), with: payload)
        }
    }

    mutating func store<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) {
            bytes.replaceSubrange(offset..<(offset + $0.count), with: $0)
        }
    }

    private mutating func store(_ value: String, at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
    }

    func withImage(_ body: (UInt64, Int64) throws -> Void) rethrows {
        try bytes.withUnsafeBytes { storage in
            let address = UInt64(UInt(bitPattern: storage.baseAddress!))
            try body(address, Int64(address) - Int64(preferredAddress))
        }
    }
}
