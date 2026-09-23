import ABIBridge
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
