import ABIBridge
import Darwin
import ObjectiveCFixtures
import Testing

private final class DiscoveryOwner {
    let object: NativeValue
    let slots: UnsafeMutablePointer<UInt>
    let slotCount = 6
    init() throws {
        object = unsafe NativeValue(
            adopting: try #require(ABICXXCreateDerived()),
            as: try .opaque(named: "Derived", size: ABICXXDerivedSize(), alignment: ABICXXDerivedAlignment()),
            release: ABICXXDeleteDerived
        )
        slots = .allocate(capacity: slotCount)
        slots.initialize(repeating: 0, count: slotCount)
    }
    deinit { slots.deinitialize(count: slotCount); slots.deallocate() }
    var objectAddress: UInt { unsafe object.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) } }
    var addressPoint: UInt { get throws { try unsafe object.read(as: UInt.self) } }
    func region() throws -> NativeMemoryRegion {
        try .init(address: UInt(bitPattern: slots), byteCount: slotCount * MemoryLayout<UInt>.size, retaining: self)
    }
}

struct NativePointerSearchTests {
    @Test func automaticAndRawInspectionPreserveOriginalEvidence() throws {
        let owner = try DiscoveryOwner()
        owner.slots[1] = owner.objectAddress
        let region = try owner.region()
        let table = try owner.addressPoint
        let offset = MemoryLayout<UInt>.size
        let automatic = try #require(try region.pointers(toVTable: table).uniqueCandidate)
        let explicit = try #require(try region.pointers(toVTable: table, options: .init(normalization: .automatic)).uniqueCandidate)
        let raw = try #require(try region.pointers(toVTable: table, options: .init(normalization: .none)).uniqueCandidate)
        for candidate in [automatic, explicit, raw] {
            #expect(candidate.offset == offset)
            #expect(candidate.pointerBits == owner.slots[1])
            #expect(candidate.vptrBits == table)
        }
        let single = try #require(try region.pointer(at: offset, toVTable: table))
        #expect(single.addressForInspection == automatic.addressForInspection)
        #expect(single.pointerBits == automatic.pointerBits && single.vptrBits == automatic.vptrBits)
    }

    @Test func singleOffsetRevalidationDoesNotSearchOtherSlots() throws {
        let owner = try DiscoveryOwner()
        let region = try owner.region()
        let table = try owner.addressPoint
        let word = MemoryLayout<UInt>.size
        owner.slots[1] = owner.objectAddress
        owner.slots[3] = 1 // Unreadable pointee outside the requested slot.
        #expect(try region.pointer(at: 0, toVTable: table) == nil)
        let candidate = try #require(try region.pointer(at: word, toVTable: table))
        #expect(candidate.offset == word && candidate.pointerBits == owner.objectAddress)
        #expect(try region.pointer(at: word, toVTable: table + 1) == nil)
        owner.slots[1] = 0
        owner.slots[2] = owner.objectAddress
        #expect(try region.pointer(at: word, toVTable: table) == nil)
        #expect(try region.pointers(toVTable: table).candidates.first?.offset == 2 * word)
    }

    @Test func singleOffsetFailuresKeepTheirStageAndReadResult() throws {
        let owner = try DiscoveryOwner()
        let region = try owner.region()
        let table = try owner.addressPoint
        owner.slots[0] = 1
        do {
            _ = try region.pointer(at: 0, toVTable: table)
            Issue.record("Unreadable pointees must throw")
        } catch let failure as NativePointerSearchFailure {
            #expect(failure.stage == .vptr && failure.address == 1 && failure.offset == 0)
            #expect(failure.systemErrorCode == KERN_INVALID_ADDRESS)
        }
        let unreadable = try NativeMemoryRegion(address: 1, byteCount: MemoryLayout<UInt>.size)
        do {
            _ = try unreadable.pointer(at: 0, toVTable: table)
            Issue.record("Unreadable source slots must throw")
        } catch let failure as NativePointerSearchFailure {
            #expect(failure.stage == .slot && failure.address == 1 && failure.copiedByteCount == 0)
        }
        owner.slots[0] = UInt.max
        do {
            _ = try region.pointer(at: 0, toVTable: table, vptrOffset: 1, normalization: .none)
            Issue.record("An overflowing vptr address must report a read failure")
        } catch let failure as NativePointerSearchFailure {
            #expect(failure.stage == .vptr && failure.status == .invalidRange)
        }
        for offset in [-1, region.byteCount - 1, region.byteCount, Int.max] {
            #expect(throws: NativePointerSearchError.self) { try region.pointer(at: offset, toVTable: table) }
        }
        #expect(throws: NativePointerSearchError.self) { try region.pointer(at: 0, toVTable: 0) }
        #expect(throws: NativePointerSearchError.self) { try region.pointer(at: 0, toVTable: table, vptrOffset: -1) }
    }

    @Test func singleOffsetCandidateRetainsAndReleasesItsOwner() throws {
        var owner: DiscoveryOwner? = try DiscoveryOwner()
        weak var weakOwner = owner
        owner!.slots[0] = owner!.objectAddress
        var candidate = try owner!.region().pointer(at: 0, toVTable: owner!.addressPoint)
        owner = nil
        #expect(candidate != nil && weakOwner != nil)
        candidate = nil
        #expect(weakOwner == nil)
    }

    @Test func shiftedFieldsHintsAliasesAndAmbiguity() throws {
        let owner = try DiscoveryOwner()
        let region = try owner.region()
        let table = try owner.addressPoint
        let word = MemoryLayout<UInt>.size
        for index in [0, 2, 5] {
            owner.slots.initialize(repeating: 0, count: owner.slotCount)
            owner.slots[index] = owner.objectAddress
            let result = try region.pointers(toVTable: table, options: .init(hintOffset: word))
            #expect(result.isComplete && result.distinctCount == 1 && result.visitedCount == 6)
            #expect(result.uniqueCandidate?.offset == index * word)
        }
        owner.slots[1] = owner.objectAddress
        var result = try region.pointers(toVTable: table, options: .init(hintOffset: 5 * word))
        #expect(result.candidates.map(\.offset) == [word, 5 * word])
        #expect(result.distinctCount == 1 && result.uniqueCandidate != nil)
        let another = try DiscoveryOwner()
        owner.slots[3] = another.objectAddress
        result = try withExtendedLifetime(another) { try region.pointers(toVTable: table, options: .init(hintOffset: word)) }
        #expect(result.isComplete && result.distinctCount == 2 && result.uniqueCandidate == nil)
        #expect(result.candidates.count == 3)
    }

    @Test func firstMatchRevalidatesHintsWithoutClaimingUniqueness() throws {
        let owner = try DiscoveryOwner()
        let region = try owner.region()
        let word = MemoryLayout<UInt>.size
        owner.slots[4] = owner.objectAddress
        let options = NativePointerSearchOptions(policy: .first, hintOffset: word * 4)
        let fast = try region.pointers(toVTable: owner.addressPoint, options: options)
        #expect(fast.visitedCount == 1 && fast.candidates.first?.offset == 4 * word)
        #expect(!fast.isComplete && fast.uniqueCandidate == nil)
        owner.slots[4] = 0
        owner.slots[2] = owner.objectAddress
        let fallback = try region.pointers(toVTable: owner.addressPoint, options: options)
        #expect(fallback.candidates.first?.offset == 2 * word && fallback.visitedCount == 4)
        for hint in [-1, 1, Int.max] {
            let result = try region.pointers(toVTable: owner.addressPoint, options: .init(hintOffset: hint))
            #expect(result.isComplete && result.uniqueCandidate?.offset == 2 * word && result.visitedCount == 6)
        }
        owner.slots[2] = 0
        let missing = try region.pointers(toVTable: owner.addressPoint, options: options)
        #expect(missing.isComplete && missing.candidates.isEmpty && missing.failures.isEmpty)
    }

    @Test func readFailuresKeepCandidatesButPreventUniqueness() throws {
        let owner = try DiscoveryOwner()
        owner.slots[1] = 1
        owner.slots[3] = owner.objectAddress
        let result = try owner.region().pointers(toVTable: owner.addressPoint)
        #expect(!result.isComplete && result.uniqueCandidate == nil && result.distinctCount == 1)
        #expect(result.visitedCount == 6 && result.failures.count == 1)
        #expect(result.failures.first?.stage == .vptr)
        #expect(result.failures.first?.systemErrorCode == KERN_INVALID_ADDRESS)
        owner.slots[1] = UInt.max
        let overflow = try owner.region().pointers(toVTable: owner.addressPoint, options: .init(vptrOffset: 1, normalization: .none))
        #expect(overflow.failures.first?.status == .invalidRange)
    }

    @Test func explicitVPtrOffsetAndUnalignedSlots() throws {
        let owner = try DiscoveryOwner()
        let secondaryOffset = unsafe owner.object.withUnsafeBytes { ABICXXSecondaryOffset($0.baseAddress) }
        let secondaryTable = try unsafe owner.object.read(as: UInt.self, at: secondaryOffset)
        let word = MemoryLayout<UInt>.size
        var bytes = [UInt8](repeating: 0, count: word + 2)
        var address = owner.objectAddress
        withUnsafeBytes(of: &address) { source in bytes.replaceSubrange(1..<(1 + word), with: source) }
        try bytes.withUnsafeBytes { storage in
            let region = try NativeMemoryRegion(address: UInt(bitPattern: storage.baseAddress!), byteCount: storage.count, retaining: owner)
            let result = try region.pointers(
                toVTable: secondaryTable,
                options: .init(firstOffset: 1, alignment: 1, vptrOffset: secondaryOffset)
            )
            #expect(result.uniqueCandidate?.vptrAddress == owner.objectAddress + UInt(secondaryOffset))
            #expect(result.uniqueCandidate?.pointerBits == owner.objectAddress)
            #expect(result.visitedCount == 1)
            let inspected = try #require(try region.pointer(at: 1, toVTable: secondaryTable, vptrOffset: secondaryOffset))
            #expect(inspected.vptrAddress == result.uniqueCandidate?.vptrAddress)
            #expect(inspected.slotAddress == UInt(bitPattern: storage.baseAddress!) + 1)
        }
    }

    @Test func invalidOptionsAndTinyRegions() throws {
        let region = try NativeMemoryRegion(address: 0, byteCount: 0)
        for options in [
            NativePointerSearchOptions(stride: 0), .init(alignment: 3),
            .init(firstOffset: -1), .init(vptrOffset: -1), .init(firstOffset: 1)
        ] {
            #expect(throws: NativePointerSearchError.self) { try region.pointers(toVTable: 1, options: options) }
        }
        #expect(throws: NativePointerSearchError.self) { try region.pointers(toVTable: 0) }
        #expect(try region.pointers(toVTable: 1).isComplete)
        let tiny = try NativeMemoryRegion(address: 0, byteCount: 1).pointers(toVTable: 1)
        #expect(tiny.isComplete && tiny.visitedCount == 0)
    }

    @Test func selectedCandidateRetainsOwnerAndFeedsExistingInvocation() async throws {
        var owner: DiscoveryOwner? = try DiscoveryOwner()
        weak var weakOwner = owner
        owner!.slots[2] = owner!.objectAddress
        var candidate: NativePointerCandidate? = try #require(
            try owner!.region().pointers(toVTable: owner!.addressPoint).uniqueCandidate
        )
        owner = nil
        #expect(weakOwner != nil)
        let evidence = candidate!
        let type = try NativeType.opaque(named: "Derived", size: ABICXXDerivedSize(), alignment: ABICXXDerivedAlignment())
        let storage = unsafe NativeValue(
            borrowing: try #require(UnsafeMutableRawPointer(bitPattern: evidence.addressForInspection)),
            as: type, retaining: evidence
        )
        let method = try await ABIRuntime.shared.cxxObject(storage, typeNamed: "ABICXXFixture::Derived")
            .method(named: "value() const", as: (() -> Int32).self)
        candidate = nil
        #expect(try unsafe method.unsafeInvoke() == 110)
        #expect(weakOwner != nil)
    }
}
