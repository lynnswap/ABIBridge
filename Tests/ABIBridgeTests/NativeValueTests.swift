import ABIBridge
import Foundation
import ObjectiveCFixtures
import Testing

private final class PairValue: ABIBridgeValue {
    static let abiType = try! NativeType.structure(named: "Pair", fields: [.double, .double])
    let left: Double
    let right: Double

    init(_ left: Double, _ right: Double) { self.left = left; self.right = right }
    init(nativeValue: NativeValue) throws {
        left = try unsafe nativeValue.field(at: 0).read(as: Double.self)
        right = try unsafe nativeValue.field(at: 1).read(as: Double.self)
    }
    static func nativeValue(from value: PairValue) -> NativeValue {
        NativeValue(type: abiType) { bytes in
            bytes.baseAddress!.storeBytes(of: value.left, toByteOffset: abiType.fields[0].offset, as: Double.self)
            bytes.baseAddress!.storeBytes(of: value.right, toByteOffset: abiType.fields[1].offset, as: Double.self)
        }
    }
}

private final class Events {
    var values: [String] = []
}
private final class TrackedOwner {
    let events: Events
    init(_ events: Events) { self.events = events }
    deinit { events.values.append("owner") }
}
private enum ConversionFailure: Error { case rejected, nullResource }

private final class ResourceValue: ABIBridgeValue {
    static let abiType = NativeType.pointer
    let storage: NativeValue

    init(nativeValue: NativeValue) throws {
        guard let pointer = try unsafe nativeValue.read(as: UnsafeMutableRawPointer?.self) else {
            throw ConversionFailure.nullResource
        }
        storage = unsafe NativeValue(
            adopting: pointer, as: try .opaque(named: "Resource"),
            release: { ABICDestroyResource($0) }
        )
    }

    static func nativeValue(from value: ResourceValue) -> NativeValue {
        .reference(to: value.storage)
    }
}

private struct BorrowedResource: ABIBridgeValue {
    static let abiType = NativeType.pointer
    let value: NativeValue
    init(nativeValue: NativeValue) { value = nativeValue }
    static func nativeValue(from value: Self) -> NativeValue { value.value }
}

private struct RejectingResource: ABIBridgeValue {
    static let abiType = NativeType.pointer
    init(nativeValue: NativeValue) throws {
        let owner = try ResourceValue(nativeValue: nativeValue)
        try withExtendedLifetime(owner) { throw ConversionFailure.rejected }
    }
    static func nativeValue(from value: Self) throws -> NativeValue { throw ConversionFailure.rejected }
}

private struct WrongPair: ABIBridgeValue {
    static let abiType = PairValue.abiType
    let events: Events
    init(_ events: Events) { self.events = events }
    init(nativeValue: NativeValue) throws { throw ConversionFailure.rejected }
    static func nativeValue(from value: Self) -> NativeValue {
        NativeValue(type: .int32, destroy: { _ in value.events.values.append("destroy") }) {
            $0.baseAddress!.storeBytes(of: Int32(1), as: Int32.self)
        }
    }
}

struct NativeValueTests {
    @Test func customWrappersUseTheirNativeLayout() async throws {
        let function = try await ABIRuntime.shared.cFunction(
            named: "ABICTransformPair", as: ((PairValue, UnsafeMutablePointer<Int32>) -> PairValue).self
        )
        var calls: Int32 = 0
        let result = try withUnsafeMutablePointer(to: &calls) {
            try unsafe function.unsafeInvoke(PairValue(2, 3), $0)
        }
        var oracleCalls: Int32 = 0
        let expected = ABICTransformPair(ABIAdapterPair(left: 2, right: 3), &oracleCalls)
        #expect(result.left == expected.left && result.right == expected.right)
        #expect(calls == 1)
        #expect(MemoryLayout<PairValue>.size != PairValue.abiType.size)
        #expect(PairValue.abiType.size == MemoryLayout<ABIAdapterPair>.size)
    }

    @Test func runtimeSignaturesReturnCastableValues() async throws {
        let function = try await ABIRuntime.shared.cFunction(
            named: "ABICTransformPair",
            signature: .init(parameters: [PairValue.abiType, .pointer], returns: PairValue.abiType)
        )
        var calls: Int32 = 0
        let result = try withUnsafeMutablePointer(to: &calls) { pointer in
            let counter = try NativeValue(copying: pointer, as: .pointer)
            return try unsafe function.unsafeInvoke(with: [PairValue.nativeValue(from: .init(4, 5)), counter])
        }
        let pair = try result.cast(to: PairValue.self)
        #expect(pair.left == 5 && pair.right == 7)
        #expect(calls == 1)
    }

    @Test func runtimeSignaturesValidateArgumentsBeforeDispatch() async throws {
        let function = try await ABIRuntime.shared.cFunction(
            named: "ABICTransformPair",
            signature: .init(parameters: [PairValue.abiType, .pointer], returns: PairValue.abiType)
        )
        #expect(throws: ABIResolutionError.self) { try unsafe function.unsafeInvoke(with: []) }
        var calls: Int32 = 0
        try withUnsafeMutablePointer(to: &calls) { pointer in
            let counter = try NativeValue(copying: pointer, as: .pointer)
            let incompatible = try NativeValue(copying: Int32(3), as: .int32)
            #expect(throws: NativeValueError.self) {
                try unsafe function.unsafeInvoke(with: [incompatible, counter])
            }
        }
        #expect(calls == 0)
    }

    @Test func fieldsReferencesAndOwnersShareLifetime() throws {
        let events = Events()
        struct Owner { let tracked: TrackedOwner }
        var owner: Owner? = Owner(tracked: TrackedOwner(events))
        weak var weakOwner = owner?.tracked
        var value: NativeValue? = NativeValue(
            type: PairValue.abiType, retaining: owner,
            destroy: { _ in
                #expect(weakOwner != nil)
                events.values.append("destroy")
            }
        ) {
            $0.baseAddress!.storeBytes(of: Double(1), as: Double.self)
            $0.baseAddress!.storeBytes(of: Double(2), toByteOffset: PairValue.abiType.fields[1].offset, as: Double.self)
        }
        var field: NativeValue? = try value!.field(at: 1)
        var reference: NativeValue? = .reference(to: value!)
        owner = nil
        value = nil
        #expect(events.values.isEmpty)
        #expect(try unsafe field!.read(as: Double.self) == 2)
        field = nil
        #expect(events.values.isEmpty)
        #expect(try unsafe reference!.read(as: UnsafeRawPointer?.self) != nil)
        reference = nil
        #expect(events.values == ["destroy", "owner"])
    }

    @Test func adoptedResourcesAndOptionalPointerWrappers() async throws {
        let make = try await ABIRuntime.shared.cFunction(
            named: "ABICCreateResource", as: ((UnsafeMutablePointer<Int32>) -> ResourceValue).self
        )
        let read = try await ABIRuntime.shared.cFunction(
            named: "ABICReadResource", as: ((ResourceValue) -> Int32).self
        )
        let echo = try await ABIRuntime.shared.cFunction(
            named: "ABICPointer", as: ((BorrowedResource?) -> BorrowedResource?).self
        )
        var live: Int32 = 0
        try withUnsafeMutablePointer(to: &live) { pointer in
            let resource = try unsafe make.unsafeInvoke(pointer)
            #expect(pointer.pointee == 1)
            #expect(try unsafe read.unsafeInvoke(resource) == 73)
            let borrowed = BorrowedResource(nativeValue: .reference(to: resource.storage))
            let echoed = try #require(try unsafe echo.unsafeInvoke(borrowed))
            #expect(try unsafe echoed.value.read(as: UnsafeRawPointer?.self) != nil)
            #expect(try unsafe echo.unsafeInvoke(nil) == nil)
        }
        #expect(live == 0)
    }

    @Test func failedConversionsReleaseAdoptedResources() async throws {
        let make = try await ABIRuntime.shared.cFunction(
            named: "ABICCreateResource", as: ((UnsafeMutablePointer<Int32>) -> RejectingResource).self
        )
        var live: Int32 = 0
        withUnsafeMutablePointer(to: &live) { pointer in
            #expect(throws: ConversionFailure.self) { try unsafe make.unsafeInvoke(pointer) }
        }
        #expect(live == 0)
    }

    @Test func invalidArgumentLayoutStopsBeforeDispatchAndCleansUp() async throws {
        let function = try await ABIRuntime.shared.cFunction(
            named: "ABICTransformPair", as: ((WrongPair, UnsafeMutablePointer<Int32>) -> PairValue).self
        )
        let events = Events()
        var calls: Int32 = 0
        withUnsafeMutablePointer(to: &calls) { pointer in
            #expect(throws: NativeValueError.self) {
                try unsafe function.unsafeInvoke(WrongPair(events), pointer)
            }
        }
        #expect(calls == 0)
        #expect(events.values == ["destroy"])
    }

    @Test func borrowedStorageKeepsItsOwnerAndSupportsUnalignedReads() throws {
        let events = Events()
        let type = try NativeType.opaque(named: "bytes", size: 9)
        var owner: NativeValue? = NativeValue(type: type, destroy: { _ in events.values.append("destroy") }) { bytes in
            let number: UInt64 = 0x1234567890
            Swift.withUnsafeBytes(of: number) { source in
                bytes.baseAddress!.advanced(by: 1).copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        let address = unsafe owner!.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: 1) }
        var borrowed: NativeValue? = unsafe NativeValue(borrowing: address, as: .uint64, retaining: owner)
        owner = nil
        #expect(try unsafe borrowed!.read(as: UInt64.self) == 0x1234567890)
        #expect(events.values.isEmpty)
        borrowed = nil
        #expect(events.values == ["destroy"])
    }

    @Test func layoutAliasesCanBeCastAndOverflowingLayoutsFail() throws {
        let alias = try NativeType.structure(named: "PairAlias", fields: [.double, .double])
        let value = NativeValue(type: alias) { bytes in
            bytes.baseAddress!.storeBytes(of: Double(4), as: Double.self)
            bytes.baseAddress!.storeBytes(of: Double(6), toByteOffset: alias.fields[1].offset, as: Double.self)
        }
        let pair = try value.cast(to: PairValue.self)
        #expect(pair.left == 4 && pair.right == 6)
        var growing = NativeType.uint64
        var rejected = false
        for _ in 0..<Int.bitWidth {
            do { growing = try .structure(named: "Growing", fields: [growing, growing]) }
            catch { rejected = true; break }
        }
        #expect(rejected)
    }

    @Test func failedInitializationDoesNotDestroyUninitializedStorage() {
        let events = Events()
        #expect(throws: ConversionFailure.self) {
            _ = try NativeValue(type: .int32, destroy: { _ in events.values.append("destroy") }) { _ in
                throw ConversionFailure.rejected
            }
        }
        #expect(events.values.isEmpty)
    }

    @Test func boundsAndUnsupportedLayoutsReportErrors() async throws {
        let value = try NativeValue(copying: Int32(3), as: .int32)
        #expect(throws: NativeValueError.self) { try unsafe value.read(as: Int64.self) }
        #expect(throws: NativeValueError.self) { try unsafe value.read(as: Int32.self, at: -1) }
        #expect(throws: NativeValueError.self) { try unsafe value.read(as: Int32.self, at: Int.max) }
        #expect(throws: NativeValueError.self) { try value.field(at: 0) }
        #expect(throws: NativeValueError.self) { try value.cast(to: PairValue.self) }
        #expect(throws: NativeValueError.self) { try NativeType.opaque(named: "invalid", size: -1) }
        #expect(throws: NativeValueError.self) { try NativeType.opaque(named: "invalid", alignment: 3) }
        let opaque = try NativeType.opaque(named: "Opaque", size: 16, alignment: 8)
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.cFunction(
                named: "ABICAnswer", signature: .init(parameters: [], returns: opaque)
            )
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.cFunction(
                named: "ABICAnswer", as: (() -> PairValue?).self
            )
        }
    }
}
