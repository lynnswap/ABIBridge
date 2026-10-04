import ABIBridgeCore
import Darwin
import Testing

struct MemoryReadTests {
    @Test func kernelFailurePreservesTheReadablePrefix() throws {
        let page = Int(getpagesize())
        let address = try #require(
            mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        )
        try #require(address != MAP_FAILED)
        defer { munmap(address, page * 2) }
        address.initializeMemory(as: UInt8.self, repeating: 0x5a, count: page * 2)
        try #require(mprotect(address.advanced(by: page), page, PROT_NONE) == 0)
        var output = Array(repeating: UInt8(0), count: 14)
        let result = output.withUnsafeMutableBytes {
            ABIReadMemory(UInt(bitPattern: address) + UInt(page - 7), 14, $0.baseAddress)
        }
        #expect(result.status == ABIMemoryReadPartial && result.byteCount == 7)
        #expect(Array(output.prefix(7)) == Array(repeating: 0x5a, count: 7))
        var copied: vm_size_t = 0, byte: UInt8 = 0
        let expected = withUnsafeMutablePointer(to: &byte) {
            vm_read_overwrite(
                mach_task_self_,
                UInt(bitPattern: address) + UInt(page),
                1,
                UInt(bitPattern: $0),
                &copied
            )
        }
        #expect(result.systemError == expected && expected != KERN_SUCCESS)
    }
}
