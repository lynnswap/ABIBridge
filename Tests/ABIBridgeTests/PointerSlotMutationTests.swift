import ABIBridgeCore
import Darwin
import ObjectiveCFixtures
import Testing

private final class SlotPages: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let size = Int(getpagesize())
    init() throws {
        pointer = try #require(mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))
        try #require(pointer != MAP_FAILED)
        pointer.initializeMemory(as: UInt.self, repeating: 41, count: size / MemoryLayout<UInt>.size)
    }
    deinit { munmap(pointer, size) }
}

struct PointerSlotMutationTests {
    @Test func reportsVMAndRecoveryFailuresFromTheSameAlgorithm() {
        if let error = ABITestPointerSlotRecovery() { Issue.record(Comment(rawValue: String(cString: error))) }
    }

    @Test func encodingValidatesSchemaAndPreservesNull() throws {
        let pages = try SlotPages()
        var bits: UInt = 123
        #expect(ABIEncodePointerSlotFunction(nil, pages.pointer, Int32(ABIAuthenticationInstructionA), 7, true, &bits))
        #expect(bits == 0)
        bits = 123
        #expect(!ABIEncodePointerSlotFunction(nil, pages.pointer, 99, 7, true, &bits))
        #expect(!ABIEncodePointerSlotFunction(nil, nil, Int32(ABIAuthenticationUnsigned), 0, false, &bits))
        #expect(bits == 123)
    }

    @Test func mutatesAndRestoresReadOnlyPagesAndPreservesCompetingValues() throws {
        let pages = try SlotPages()
        #expect(mprotect(pages.pointer, pages.size, PROT_READ) == 0)
        let changed = ABICompareExchangePointerSlot(pages.pointer, 41, 42)
        #expect(changed.status == ABIPointerSlotComplete && changed.didWrite && changed.observed == 41)
        #expect(changed.protectionBefore == VM_PROT_READ)
        #expect(changed.restoreProtectionError == 0 && changed.restoreMaximumError == 0)
        let conflict = ABICompareExchangePointerSlot(pages.pointer, 41, 43)
        #expect(conflict.status == ABIPointerSlotDisplaced && !conflict.didWrite && conflict.observed == 42)
        let restored = ABICompareExchangePointerSlot(pages.pointer, 42, 41)
        #expect(restored.status == ABIPointerSlotComplete && restored.protectionBefore == VM_PROT_READ)
        #expect(pages.pointer.load(as: UInt.self) == 41)
    }

    @Test func rejectsInaccessibleAndUnalignedStorage() throws {
        let pages = try SlotPages()
        #expect(ABICompareExchangePointerSlot(nil, 0, 1).status == ABIPointerSlotInvalidStorage)
        #expect(ABICompareExchangePointerSlot(pages.pointer.advanced(by: 1), 41, 42).status == ABIPointerSlotInvalidStorage)
        #expect(mprotect(pages.pointer, pages.size, PROT_NONE) == 0)
        let inaccessible = ABICompareExchangePointerSlot(pages.pointer, 41, 42)
        #expect(inaccessible.status == ABIPointerSlotReadFailed && !inaccessible.didWrite)
    }

    #if arch(arm64)
    @Test func taggedStorageUsesItsVirtualAddressForRegionLookup() throws {
        let pages = try SlotPages()
        #expect(mprotect(pages.pointer, pages.size, PROT_NONE) == 0)
        let tagged = try #require(UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: pages.pointer) | (UInt(14) << 56)))
        // An inaccessible mapping exercises the real Mach query without ever
        // dereferencing a fabricated logical tag. Actual tagged writes are
        // exercised by the allocator-backed arm64e architecture fixture.
        let result = ABICompareExchangePointerSlot(tagged, 41, 42)
        #expect(result.status == ABIPointerSlotReadFailed && !result.didWrite)
    }
    #endif

    @Test func rejectsExecutableStorageWithoutChangingIt() throws {
        let handle = try #require(dlopen(nil, RTLD_NOW))
        defer { dlclose(handle) }
        let code = try #require(dlsym(handle, "getpid"))
        let aligned = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: code) & ~(UInt(MemoryLayout<UInt>.alignment) - 1))
        let result = ABICompareExchangePointerSlot(aligned, 0, 0)
        #expect(result.status == ABIPointerSlotExecutableStorage && !result.didWrite)
        #expect(getpid() > 0)
    }

    @Test func restoresMaximumProtectionAfterCopyOnWrite() throws {
        let pages = try SlotPages()
        #expect(vm_protect(mach_task_self_, UInt(bitPattern: pages.pointer), UInt(pages.size), 1, VM_PROT_READ) == KERN_SUCCESS)
        let changed = ABICompareExchangePointerSlot(pages.pointer, 41, 42)
        #expect(changed.status == ABIPointerSlotComplete && changed.didWrite)
        #expect(changed.protectionBefore == VM_PROT_READ && changed.maximumBefore == VM_PROT_READ)
        let restored = ABICompareExchangePointerSlot(pages.pointer, 42, 41)
        #expect(restored.status == ABIPointerSlotComplete)
        #expect(restored.protectionBefore == VM_PROT_READ && restored.maximumBefore == VM_PROT_READ)
        #expect(pages.pointer.load(as: UInt.self) == 41)
    }

    @Test func samePageMutationsSerializeProtectionChanges() async throws {
        let pages = try SlotPages()
        #expect(mprotect(pages.pointer, pages.size, PROT_READ) == 0)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let slot = pages.pointer.advanced(by: index * MemoryLayout<UInt>.size)
                    for _ in 0..<20 {
                        let changed = ABICompareExchangePointerSlot(slot, 41, 42)
                        let restored = ABICompareExchangePointerSlot(slot, 42, 41)
                        #expect(changed.status == ABIPointerSlotComplete && restored.status == ABIPointerSlotComplete)
                        #expect(changed.protectionBefore == VM_PROT_READ && restored.protectionBefore == VM_PROT_READ)
                    }
                }
            }
        }
        #expect(pages.pointer.load(as: UInt.self) == 41)
    }
}
