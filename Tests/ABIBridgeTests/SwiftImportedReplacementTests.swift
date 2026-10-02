#if os(macOS) && DEBUG
@testable import ABIBridge
import ABIBridgeCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct SwiftImportedReplacementTests {
    @Test func sendableFunctionSignaturesCanReplaceEitherAnnotation() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let sendableTarget = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: (@Sendable (Int64) -> Int64).self, in: fixture.providerScope)
        let replacement = try await fixture.runtime.swiftFunction(named: fixture.module + ".replacementScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let sendableReplacement = try await fixture.runtime.swiftFunction(named: fixture.module + ".replacementScalar(_:)", as: (@Sendable (Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let ordinary = [
            try await unsafe target.prepareImportedReplacement(with: replacement, in: fixture.callerScope),
            try await unsafe target.prepareImportedReplacement(with: sendableReplacement, in: fixture.callerScope),
        ]
        for plan in ordinary {
            try unsafe plan.install(); defer { try? plan.restore() }
            #expect(try unsafe oracle.unsafeInvoke(40) == 140)
            #expect(try unsafe plan.slots[0].original!.unsafeInvoke(40) == 41)
            try plan.restore()
        }
        let sendable = [
            try await unsafe sendableTarget.prepareImportedReplacement(with: replacement, in: fixture.callerScope),
            try await unsafe sendableTarget.prepareImportedReplacement(with: sendableReplacement, in: fixture.callerScope),
        ]
        for plan in sendable {
            try unsafe plan.install(); defer { try? plan.restore() }
            #expect(try unsafe oracle.unsafeInvoke(40) == 140)
            #expect(try unsafe plan.slots[0].original!.unsafeInvoke(40) == 41)
            try plan.restore()
        }
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
    }

    @Test func sendableImportedMembersKeepTheirReceiverAndOriginal() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".ReplacementValue", as: Int64.self, in: fixture.providerScope)
        let target = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
        let sendableTarget = try await type.method(named: "scalar(_:)", as: (@Sendable (Int64) -> Int64).self)
        let replacement = try await type.method(named: "replacementScalar(_:)", as: ((Int64) -> Int64).self)
        let sendableReplacement = try await type.method(named: "replacementScalar(_:)", as: (@Sendable (Int64) -> Int64).self)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedValueMethod(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let ordinary = [
            try await unsafe target.prepareImportedReplacement(with: replacement, in: fixture.callerScope),
            try await unsafe target.prepareImportedReplacement(with: sendableReplacement, in: fixture.callerScope),
        ]
        for plan in ordinary {
            try unsafe plan.install(); defer { try? plan.restore() }
            #expect(try unsafe oracle.unsafeInvoke(2) == 142)
            #expect(try unsafe plan.slots[0].original!.unsafeInvoke(on: Int64(40), 2) == 42)
            try plan.restore()
        }
        let sendable = [
            try await unsafe sendableTarget.prepareImportedReplacement(with: replacement, in: fixture.callerScope),
            try await unsafe sendableTarget.prepareImportedReplacement(with: sendableReplacement, in: fixture.callerScope),
        ]
        for plan in sendable {
            try unsafe plan.install(); defer { try? plan.restore() }
            #expect(try unsafe oracle.unsafeInvoke(2) == 142)
            #expect(try unsafe plan.slots[0].original!.unsafeInvoke(on: Int64(40), 2) == 42)
            try plan.restore()
        }
        #expect(try unsafe oracle.unsafeInvoke(2) == 42)
    }

    @Test func preparesTypedOriginalsBeforePublicationAndRestores() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let runtime = fixture.runtime
        let target = try await runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let replacement = try await runtime.swiftFunction(named: fixture.module + ".replacementScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let plan = try await unsafe target.prepareImportedReplacement(with: replacement, in: fixture.callerScope, using: runtime)
        #expect(plan.slots.count == 1 && plan.slots[0].status == .prepared)
        let original = try #require(plan.slots[0].original)
        #expect(try unsafe original.unsafeInvoke(40) == 41)
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
        try unsafe plan.install()
        #expect(plan.slots[0].status == .installed)
        #expect(try unsafe oracle.unsafeInvoke(40) == 140)
        #expect(try unsafe original.unsafeInvoke(40) == 41)
        try plan.restore(); try plan.restore()
        #expect(plan.slots[0].status == .restored)
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
        try unsafe plan.install(); try plan.restore()
    }

    @Test func capturesTheActualPredecessorAndDoesNotOverwriteAnotherWriter() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let replacement = try await fixture.runtime.swiftFunction(named: fixture.module + ".replacementScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let first = try await unsafe target.prepareImportedReplacement(with: replacement, in: fixture.callerScope)
        try unsafe first.install()
        defer { try? first.restore() }
        let third = try await fixture.runtime.swiftFunction(named: fixture.module + ".dynamicScalar(_:)",
            as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let second = try await unsafe target.prepareImportedReplacement(with: third, in: fixture.callerScope)
        #expect(try unsafe second.slots[0].original!.unsafeInvoke(40) == 140)
        try unsafe second.install()
        #expect(throws: NativeSwiftReplacementError.self) { try first.restore() }
        #expect(first.slots[0].status == .displaced && first.slots[0].restoration?.didWrite == false)
        try second.restore()
        #expect(try unsafe second.slots[0].original!.unsafeInvoke(40) == 140)
        try first.restore()

    }

    @Test func stringAndValueMethodOriginalsUseTheirSwiftContracts() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let text = try await fixture.runtime.swiftFunction(named: fixture.module + ".text(_:)", as: ((String) -> String).self, in: fixture.providerScope)
        let newText = try await fixture.runtime.swiftFunction(named: fixture.module + ".replacementText(_:)", as: ((String) -> String).self, in: fixture.providerScope)
        let textOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedText(_:)", as: ((String) -> String).self, in: fixture.callerScope)
        let plan = try await unsafe text.prepareImportedReplacement(with: newText, in: fixture.callerScope)
        try unsafe plan.install()
        let input = String(repeating: "owned", count: 200)
        #expect(try unsafe textOracle.unsafeInvoke(input) == "replacement:" + input)
        #expect(try unsafe plan.slots[0].original!.unsafeInvoke(input) == "original:" + input)
        try plan.restore()
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".ReplacementValue", as: Int64.self, in: fixture.providerScope)
        let target = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
        let replacement = try await type.method(named: "replacementScalar(_:)", as: ((Int64) -> Int64).self)
        let member = try await unsafe target.prepareImportedReplacement(with: replacement, in: fixture.callerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedValueMethod(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        try unsafe member.install()
        #expect(try unsafe oracle.unsafeInvoke(2) == 142)
        #expect(try unsafe member.slots[0].original!.unsafeInvoke(on: Int64(40), 2) == 42)
        try member.restore()
        #expect(try unsafe oracle.unsafeInvoke(2) == 42)
    }

    @Test func indirectResultKeepsTheOriginalSwiftLowering() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let suffix = "(Swift.Int64) -> " + fixture.module + ".ReplacementPayload"
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".payload" + suffix,
            as: ((Int64) -> SwiftABIFive).self, in: fixture.providerScope)
        let replacement = try await fixture.runtime.swiftFunction(named: fixture.module + ".replacementPayload" + suffix,
            as: ((Int64) -> SwiftABIFive).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedPayload(_:)",
            as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let plan = try await unsafe target.prepareImportedReplacement(with: replacement, in: fixture.callerScope)
        try unsafe plan.install()
        #expect(try unsafe oracle.unsafeInvoke(40) == 710)
        let original = try unsafe plan.slots[0].original!.unsafeInvoke(40)
        #expect(original.a == 40 && original.e == 44)
        try plan.restore()
        #expect(try unsafe oracle.unsafeInvoke(40) == 210)
    }

    @Test func partialPublicationPreservesRollbackFailuresForRetry() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let replacement = try await fixture.runtime.swiftFunction(named: fixture.module + ".replacementScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let words = UnsafeMutablePointer<UInt>.allocate(capacity: 2)
        defer { words.deallocate() }
        let before = unsafe target.symbol.withUnsafeAddress { UInt(bitPattern: $0) }
        words.initialize(repeating: before, count: 2)
        let count = Mutex(0)
        let transport = SwiftReplacementTransport(exchange: { address, old, next in
            let ordinal = count.withLock { $0 += 1; return $0 }
            if ordinal == 2 || ordinal == 3 {
                var result = ABIPointerSlotResult(); result.status = Int32(ABIPointerSlotProtectFailed)
                result.systemErrorCode = KERN_PROTECTION_FAILURE; return result
            }
            return ABICompareExchangePointerSlot(UnsafeMutableRawPointer(bitPattern: address), old, next)
        }, repair: SwiftReplacementTransport.live.repair)
        let slots = (0..<2).map { (UInt(bitPattern: words.advanced(by: $0)), NativePointerAuthentication.unsigned) }
        let storage = try SwiftReplacementStorage(slots: slots, replacement: replacement.symbol,
            retaining: fixture, codeOwner: nil, transport: transport)
        let plan = NativeSwiftImportedReplacement(storage: storage) { NativeSwiftFunctionImplementation(target, $0) }
        do { try unsafe plan.install(); Issue.record("Expected publication failure") }
        catch let error as NativeSwiftReplacementError {
            #expect(error.failedIndices == [1] && error.restorationFailedIndices == [0])
        }
        #expect(plan.slots[0].status == .installed && plan.slots[1].status == .prepared)
        #expect(words[0] != before && words[1] == before)
        try plan.restore()
        #expect(words[0] == before && words[1] == before)
    }

    @Test func publicationPinsCodeAndReleasingThePlanDoesNotRestore() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let other = try FixtureLibrary(swiftModule: fixture.module + "Other", swiftSource: "public func replacement(_ value: Int64) -> Int64 { value + 300 }")
        let runtime = ABIRuntime()
        let target = try await runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let generation: UInt64
        let slot: UInt
        let before: UInt
        do {
            let replacement = try await runtime.swiftFunction(named: fixture.module + "Other.replacement(_:)",
                as: ((Int64) -> Int64).self, in: .path(other.libraryURL))
            generation = replacement.symbol.image.identity.loadGeneration
            let plan = try await unsafe target.prepareImportedReplacement(with: replacement, in: fixture.callerScope, using: runtime)
            slot = plan.slots[0].address
            before = UnsafeRawPointer(bitPattern: slot)!.load(as: UInt.self)
            try unsafe plan.install()
        }
        other.cleanup()
        await runtime.removeCachedResults()
        #expect(try unsafe oracle.unsafeInvoke(40) == 340)
        let lease = try #require(ABIRetainLoadedImage(generation)); ABIReleaseImage(lease)
        let current = UnsafeRawPointer(bitPattern: slot)!.load(as: UInt.self)
        #expect(ABICompareExchangePointerSlot(UnsafeMutableRawPointer(bitPattern: slot), current, before).status == ABIPointerSlotComplete)
    }

    @Test func failedProtectionRestorationRemainsRetryableAfterPointerRestoration() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let replacement = try await fixture.runtime.swiftFunction(named: fixture.module + ".replacementScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let size = Int(getpagesize())
        let page = try #require(mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
        try #require(page != MAP_FAILED)
        defer { munmap(page, size) }
        unsafe target.symbol.withUnsafeAddress { page.storeBytes(of: UInt(bitPattern: $0), as: UInt.self) }
        try #require(mprotect(page, size, PROT_READ) == 0)
        let exchanges = Mutex(0), repairs = Mutex(0)
        let transport = SwiftReplacementTransport(exchange: { address, old, next in
            let ordinal = exchanges.withLock { $0 += 1; return $0 }
            var result = ABICompareExchangePointerSlot(UnsafeMutableRawPointer(bitPattern: address), old, next)
            if ordinal == 2 {
                #expect(mprotect(UnsafeMutableRawPointer(bitPattern: address), size, PROT_READ | PROT_WRITE) == 0)
                result.status = Int32(ABIPointerSlotRestoreFailed)
                result.restoreProtectionError = KERN_PROTECTION_FAILURE
            }
            return result
        }, repair: { address, expected, protection, maximum, current, max in
            if repairs.withLock({ $0 += 1; return $0 }) == 1 {
                var result = ABIPointerSlotResult(); result.status = Int32(ABIPointerSlotRestoreFailed)
                result.restoreProtectionError = KERN_PROTECTION_FAILURE; return result
            }
            return ABIRestorePointerSlotProtection(UnsafeMutableRawPointer(bitPattern: address), expected, protection, maximum, current, max)
        })
        let storage = try SwiftReplacementStorage(slots: [(UInt(bitPattern: page), .unsigned)], replacement: replacement.symbol,
            retaining: fixture, codeOwner: nil, transport: transport)
        let plan = NativeSwiftImportedReplacement(storage: storage) { NativeSwiftFunctionImplementation(target, $0) }
        try unsafe plan.install()
        #expect(throws: NativeSwiftReplacementError.self) { try plan.restore() }
        #expect(plan.slots[0].status == .restorationRequired)
        #expect(plan.slots[0].restoration?.didWrite == true)
        try plan.restore()
        #expect(plan.slots[0].status == .restored)
        #expect(plan.slots[0].protectionRecovery?.status == Int32(ABIPointerSlotComplete))
        let originalBits = page.load(as: UInt.self)
        #expect(ABICompareExchangePointerSlot(page, originalBits, originalBits).protectionBefore == VM_PROT_READ)
    }
}
#endif
