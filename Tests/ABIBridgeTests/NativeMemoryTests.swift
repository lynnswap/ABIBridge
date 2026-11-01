import ABIBridge
import ABIBridgeTestSupport
import Darwin
import Testing

private final class MemoryPages {
    let address: UnsafeMutableRawPointer
    let count = Int(getpagesize()) * 2
    init() throws {
        address = try #require(mmap(nil, count, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))
        try #require(address != MAP_FAILED)
        address.initializeMemory(as: UInt8.self, repeating: 0x5a, count: count)
    }
    deinit { munmap(address, count) }
}

struct NativeMemoryTests {
    @Test func decodesSignedAndScaledARM64Operands() {
        #expect(
            NativeARM64Instruction(encoding: 0xf0ff_ffe8, at: 0x1234)
                == .pageAddress(register: 8, address: 0)
        )
        #expect(
            NativeARM64Instruction(encoding: 0x9080_0000, at: 0)
                == .pageAddress(register: 0, address: 0xffff_ffff_0000_0000)
        )
        #expect(
            NativeARM64Instruction(encoding: 0x10ff_ffe0, at: 0x1000)
                == .address(register: 0, address: 0xffc)
        )
        #expect(NativeARM64Instruction(encoding: 0x97ff_ffff, at: 0x1000) == .call(address: 0xffc))
        #expect(
            NativeARM64Instruction(encoding: 0x9140_0528, at: 0)
                == .addImmediate(destination: 8, source: 9, immediate: 4096)
        )
        #expect(
            NativeARM64Instruction(encoding: 0xb940_0928, at: 0)
                == .load(destination: 8, base: 9, offset: 8, byteCount: 4)
        )
        for encoding: UInt32 in [0xb100_0000, 0xd100_0000, 0x9180_0000, 0xf840_8c20] {
            #expect(NativeARM64Instruction(encoding: encoding, at: 0) == nil)
        }
        #expect(NativeARM64Instruction(encoding: 0x9400_0000, at: 1) == nil)
    }

    #if os(macOS)
    @Test func findsReferencesToAssemblerDefinedDataAndFunctions() throws {
        let library = try FixtureLibrary(
            cxxSource: """
                asm(R"(
                .text
                .p2align 2
                .globl _reference_start
                _reference_start:
                    adrp x8, _reference_data@PAGE
                    add x9, x8, _reference_data@PAGEOFF
                    ldr x0, [x9]
                    bl _reference_target
                    ret
                .globl _reference_target
                _reference_target:
                    ret
                .data
                .p2align 3
                .globl _reference_data
                _reference_data:
                    .quad 42
                )");
                """
        )
        defer { library.cleanup() }
        let address = UInt(bitPattern: try library.symbol(named: "reference_start"))
        let data = UInt64(UInt(bitPattern: try library.symbol(named: "reference_data")))
        let target = UInt64(UInt(bitPattern: try library.symbol(named: "reference_target")))
        let result = try NativeMemoryRegion(address: address, byteCount: 20, retaining: library)
            .arm64References()
        #expect(result.memory.isComplete && result.instructionByteCount == 20)
        #expect(result.references.map(\.targetAddress) == [data, data, target])
        #expect(result.references.map(\.kind) == [.address, .load(byteCount: 8), .call])
        #expect(
            result.references.map(\.instructionAddress) == [
                UInt64(address + 4), UInt64(address + 8), UInt64(address + 12),
            ]
        )
    }
    #endif

    @Test func referenceTrackingDiscardsClobberedAndLoadedAddresses() throws {
        let instructions: [UInt32] = [
            0x9000_0008, 0xd280_0008, 0xf940_0100,  // MOVZ overwrites ADRP's register.
            0x9000_0008, 0xf940_0108, 0xf940_0100,  // LDR's result is not a known address.
            0x9000_0008, 0x9400_0000, 0xf940_0100,  // BL invalidates earlier register evidence.
            0x9000_0008, 0xd503_201f, 0xf940_0100,  // NOP preserves it.
            0x9000_001f, 0xf940_03e0,  // Register 31 cannot establish SP or XZR evidence.
        ]
        try instructions.withUnsafeBytes { bytes in
            let address = UInt(bitPattern: bytes.baseAddress!)
            let result = try NativeMemoryRegion(address: address, byteCount: bytes.count)
                .arm64References()
            #expect(
                result.references.map(\.kind) == [.load(byteCount: 8), .call, .load(byteCount: 8)]
            )
            #expect(
                result.references.map(\.instructionAddress) == [
                    UInt64(address + 16), UInt64(address + 28), UInt64(address + 44),
                ]
            )
        }
    }

    @Test func referenceReadsKeepPartialMemoryResultsAndSkipTrailingBytes() throws {
        let pages = try MemoryPages()
        let page = Int(getpagesize())
        let start = pages.address.advanced(by: page - 8)
        start.storeBytes(of: UInt32(0x9400_0000), as: UInt32.self)
        start.advanced(by: 4).storeBytes(of: UInt32(0xd503_201f), as: UInt32.self)
        #expect(mprotect(pages.address.advanced(by: page), page, PROT_NONE) == 0)
        let address = UInt(bitPattern: start)
        let partial = try NativeMemoryRegion(address: address, byteCount: 12).arm64References()
        #expect(partial.memory.status == .partial && partial.memory.systemErrorCode != 0)
        #expect(partial.instructionByteCount == 8 && partial.references.count == 1)
        #expect(partial.references.first?.targetAddress == UInt64(address))
        let tail = try NativeMemoryRegion(address: address, byteCount: 6).arm64References()
        #expect(
            tail.memory.isComplete && tail.instructionByteCount == 4 && tail.references.count == 1
        )
        #expect(throws: NativeARM64ReferenceError.unalignedAddress(address + 1)) {
            try NativeMemoryRegion(address: address + 1, byteCount: 4).arm64References()
        }
    }

    @Test func unalignedCopiesAreIndependentOfTheirOwner() throws {
        var pages: MemoryPages? = try MemoryPages()
        weak var weakPages = pages
        var region: NativeMemoryRegion? = try .init(
            address: UInt(bitPattern: pages!.address) + 1, byteCount: 17, retaining: pages
        )
        pages = nil
        #expect(weakPages != nil)
        let result = region!.read()
        #expect(result.isComplete)
        #expect(result.requestedByteCount == 17 && result.bytes == Array(repeating: 0x5a, count: 17))
        #expect(result.systemErrorCode == 0)
        region = nil
        #expect(weakPages == nil)
        #expect(result.bytes.last == 0x5a)
    }

    @Test func pageFailuresPreserveOnlyTheReadablePrefix() throws {
        let pages = try MemoryPages()
        let page = Int(getpagesize())
        #expect(mprotect(pages.address.advanced(by: page), page, PROT_NONE) == 0)
        let address = UInt(bitPattern: pages.address)
        let region = try NativeMemoryRegion(address: address + UInt(page - 7), byteCount: 14, retaining: pages)
        var oracleByte: UInt8 = 0
        var oracleCount: vm_size_t = 0
        let oracleCode = withUnsafeMutablePointer(to: &oracleByte) {
            vm_read_overwrite(mach_task_self_, address + UInt(page), 1, UInt(bitPattern: $0), &oracleCount)
        }
        #expect(oracleCode != KERN_SUCCESS)
        let partial = region.read()
        #expect(partial.status == .partial && !partial.isComplete)
        #expect(partial.bytes == Array(repeating: 0x5a, count: 7))
        #expect(partial.systemErrorCode == oracleCode)
        let failed = try region.read(at: 7, byteCount: 7)
        #expect(failed.status == .failed && failed.bytes.isEmpty)
        #expect(failed.systemErrorCode == oracleCode)
        #expect(try region.read(at: 14, byteCount: 0).isComplete)
    }

    @Test func unmappedMemoryIsReportedWithoutDereferencingIt() throws {
        let region = try NativeMemoryRegion(address: 1, byteCount: 6)
        let result = region.read()
        #expect(result.status == .failed && result.bytes.isEmpty)
        #expect(result.systemErrorCode == KERN_INVALID_ADDRESS)
    }

    @Test func boundsAndEmptyRangesAreCheckedWithoutAccess() throws {
        #expect(throws: NativeMemoryError.self) { try NativeMemoryRegion(address: .max, byteCount: 1) }
        #expect(throws: NativeMemoryError.self) { try NativeMemoryRegion(address: 0, byteCount: -1) }
        let region = try NativeMemoryRegion(address: 0, byteCount: 4)
        #expect(throws: NativeMemoryError.self) { try region.read(at: -1, byteCount: 1) }
        #expect(throws: NativeMemoryError.self) { try region.read(at: 1, byteCount: .max) }
        #expect(throws: NativeMemoryError.self) { try region.read(at: .max, byteCount: 0) }
        #expect(throws: NativeMemoryError.self) { try region.read(at: 0, byteCount: -1) }
        #expect(region.read().status == .failed)
        #expect(try NativeMemoryRegion(address: .max, byteCount: 0).read().isComplete)
        #expect(try region.read(at: 0, byteCount: 0).bytes.isEmpty)
    }
}
