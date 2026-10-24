import ABIBridge
import Foundation
import ObjectiveCFixtures
import Testing

private struct BorrowedCounterValue: ABIBridgeValue {
    static let abiType = NativeType.pointer
    let storage: NativeValue
    init(nativeValue: NativeValue) { storage = nativeValue }
    static func nativeValue(from value: Self) -> NativeValue { value.storage }
    func read() throws -> Int32 {
        let address = try unsafe storage.read(as: UnsafePointer<Int32>.self)
        return address.pointee
    }
}

private final class CXXToken: ABIBridgeValue {
    static let abiType = NativeType.pointer
    let storage: NativeValue
    init(_ value: Int32) throws {
        storage = unsafe NativeValue(
            adopting: try #require(ABICXXCreateToken(value)),
            as: try .opaque(named: "Token"),
            release: { ABICXXDeleteToken($0) }
        )
    }
    init(nativeValue: NativeValue) throws {
        storage = unsafe NativeValue(
            adopting: try #require(try unsafe nativeValue.read(as: UnsafeMutableRawPointer?.self)),
            as: try .opaque(named: "Token"),
            release: { ABICXXDeleteToken($0) }
        )
    }
    static func nativeValue(from value: CXXToken) -> NativeValue { .reference(to: value.storage) }
    var value: Int32 { unsafe storage.withUnsafeBytes { ABICXXTokenValue($0.baseAddress) } }
}

@Suite(.serialized)
struct CXXObjectInvocationTests {
    private func counter(_ value: Int32) throws -> NativeValue {
        unsafe NativeValue(
            adopting: try #require(ABICXXCreateCounter(value)),
            as: try .opaque(
                named: "Counter",
                size: ABICXXCounterSize(),
                alignment: ABICXXCounterAlignment()
            ),
            release: { ABICXXDeleteCounter($0) }
        )
    }

    @MainActor @Test func extractedDirectMethodsAndBorrowedResultsOwnOnlyTheirCurrentReceiver()
        async throws
    {
        let runtime = ABIRuntime()
        weak var observedOriginal: NativeValue?
        let add: NativeCXXMethod<Int32, Int32>
        let address: NativeCXXMethod<BorrowedCounterValue>
        do {
            let original = try counter(1)
            observedOriginal = original
            let object = runtime.cxxObject(original, typeNamed: "ABICXXFixture::Counter")
            add = try object.resolveAndWait(.cxx(.method("add(int)", as: ((Int32) -> Int32).self)))
                .method
            address = try object.resolveAndWait(
                .cxx(
                    .method(
                        "address()",
                        as: (() -> BorrowedCounterValue).self
                    )
                )
            )
            .method
        }
        runtime.removeCachedResults()
        #expect(observedOriginal == nil)
        var second: NativeValue? = try counter(40)
        weak let observedSecond = second
        var bound: NativeBoundCXXMethod<Int32, Int32>? = add.bind(to: second!)
        #expect(try unsafe add.unsafeInvoke(on: second!, 1) == 41)
        #expect(try unsafe bound!.unsafeInvoke(1) == 42)
        var result: BorrowedCounterValue? = try unsafe address.unsafeInvoke(on: second!)
        second = nil
        bound = nil
        #expect(observedSecond != nil)
        #expect(try result!.read() == 42)
        result = nil
        withExtendedLifetime((add, address)) { #expect(observedSecond == nil) }
        #expect(ABICXXCounterLiveCount() == 0)
    }

    @MainActor @Test func extractedSecondaryVirtualTargetsReleaseSourceStorageAndRetainCodeOwners()
        async throws
    {
        weak var observedOriginal: NativeValue?
        var codeOwner: NSObject? = NSObject()
        weak let observedCodeOwner = codeOwner
        var method: NativeCXXMethod<Int32>?
        do {
            let pointer = try #require(ABICXXCreateDerived())
            let original = unsafe NativeValue(
                adopting: pointer,
                as: try .opaque(
                    named: "Derived",
                    size: ABICXXDerivedSize(),
                    alignment: ABICXXDerivedAlignment()
                ),
                release: { ABICXXDeleteDerived($0) }
            )
            observedOriginal = original
            let view = try original.view(
                at: ABICXXSecondaryOffset(pointer),
                as: .opaque(
                    named: "Secondary",
                    size: ABICXXSecondarySize(),
                    alignment: ABICXXSecondaryAlignment()
                )
            )
            let table = try unsafe NativeVTable(
                readingFrom: view,
                entryCount: 1,
                authentication: .cxxVTablePointer(
                    discriminator: ABICXXSecondaryVTableDiscriminator()
                ),
                retainingCode: codeOwner
            )
            method = try unsafe await ABIRuntime.shared.cxxObject(
                view,
                typeNamed: "ABICXXFixture::Secondary"
            ).resolve(
                .cxx(
                    .virtualMethod(
                        at: 0,
                        in: table,
                        authentication: .cxxVirtualFunction(
                            discriminator: ABICXXSecondarySlotDiscriminator()
                        ),
                        as: (() -> Int32).self
                    )
                )
            ).method
        }
        codeOwner = nil
        #expect(observedOriginal == nil && observedCodeOwner != nil)
        let pointer = try #require(ABICXXCreateDerived())
        let second = unsafe NativeValue(
            adopting: pointer,
            as: try .opaque(
                named: "Derived",
                size: ABICXXDerivedSize(),
                alignment: ABICXXDerivedAlignment()
            ),
            release: { ABICXXDeleteDerived($0) }
        )
        let view = try second.view(
            at: ABICXXSecondaryOffset(pointer),
            as: .opaque(
                named: "Secondary",
                size: ABICXXSecondarySize(),
                alignment: ABICXXSecondaryAlignment()
            )
        )
        #expect(try unsafe method!.unsafeInvoke(on: view) == ABICXXSecondaryOracle(pointer))
        method = nil
        #expect(observedCodeOwner == nil)
    }

    @MainActor @Test func directMethodsSupplyReceiverAndKeepCallerIsolation() async throws {
        let storage = try counter(10)
        let object = ABIRuntime.shared.cxxObject(storage, typeNamed: "ABICXXFixture::Counter")
        let request = NativeRequest.cxx(.method("add(int)", as: ((Int32) -> Int32).self))
        let add = try await object.resolve(request)
        let current = try await object.resolve(
            .cxx(
                .method(
                    "current() const",
                    as: (() -> Int32).self
                )
            )
        )
        #expect(try unsafe add.unsafeInvoke(5) == 15)
        #expect(try unsafe current.unsafeInvoke() == 15)
        let many = try await object.resolve(
            .cxx(
                .method(
                    "many(int, int, int, int, int, int, int, int, double) const",
                    as: ((Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Double) -> Double)
                        .self
                )
            )
        )
        let result = try unsafe many.unsafeInvoke(1, 2, 3, 4, 5, 6, 7, 8, 2)
        #expect(result == 102)
    }

    @Test func borrowedWrapperResultRetainsReceiverBinding() async throws {
        var storage: NativeValue? = try counter(42)
        weak let weakStorage = storage
        var method: NativeBoundCXXMethod<BorrowedCounterValue>? = try ABIRuntime.shared.cxxObject(
            storage!,
            typeNamed: "ABICXXFixture::Counter"
        ).resolveAndWait(.cxx(.method("address()", as: (() -> BorrowedCounterValue).self)))
        var result: BorrowedCounterValue? = try unsafe method!.unsafeInvoke()
        storage = nil
        method = nil
        #expect(weakStorage != nil)
        #expect(try result!.read() == 42)
        result = nil
        #expect(weakStorage == nil)
        #expect(ABICXXCounterLiveCount() == 0)
    }

    @Test func nativeAdapterHandlesNontrivialArgumentsAndResults() async throws {
        let storage = try counter(10)
        let object = ABIRuntime.shared.cxxObject(storage, typeNamed: "ABICXXFixture::Counter")
        let adapter = try ABIRuntime.shared.resolveAndWait(
            .init(name: "ABICXXTransformAdapter", language: .c)
        )
        let method = try object.resolveAndWait(
            .cxx(
                .method(
                    "transform(ABICXXFixture::Token) const",
                    as: ((CXXToken) -> CXXToken).self,
                    using: adapter
                )
            )
        )
        var input: CXXToken? = try CXXToken(7)
        var result: CXXToken? = try unsafe method.unsafeInvoke(input!)
        #expect(input!.value == 7)
        #expect(result!.value == 17)
        #expect(ABICXXTokenLiveCount() == 2)
        result = nil
        result = try unsafe method.method.unsafeInvoke(on: storage, input!)
        #expect(result!.value == 17 && ABICXXTokenLiveCount() == 2)
        input = nil
        result = nil
        #expect(ABICXXTokenLiveCount() == 0)
    }

    @Test func adaptersRequireExecutableSymbols() async throws {
        let object = ABIRuntime.shared.cxxObject(
            try counter(1),
            typeNamed: "ABICXXFixture::Counter"
        )
        #expect(ABICXXFixtureData == 3)
        let data = try ABIRuntime.shared.resolveAndWait(
            .init(name: "ABICXXFixtureData", language: .c, kind: .data)
        )
        #expect(throws: ABIResolutionError.self) {
            _ = try object.resolveAndWait(
                .cxx(
                    .method(
                        "current() const",
                        as: (() -> Int32).self,
                        using: data
                    )
                )
            )
        }
    }

    @MainActor @Test func virtualDispatchAndExplicitSecondarySubobject() async throws {
        let address = try #require(ABICXXCreateDerived())
        let storage = unsafe NativeValue(
            adopting: address,
            as: try .opaque(
                named: "Derived",
                size: ABICXXDerivedSize(),
                alignment: ABICXXDerivedAlignment()
            ),
            release: { ABICXXDeleteDerived($0) }
        )
        let primary = ABIRuntime.shared.cxxObject(storage, typeNamed: "ABICXXFixture::Base")
        let direct = try primary.resolveAndWait(
            .cxx(
                .method(
                    "value() const",
                    as: (() -> Int32).self
                )
            )
        )
        #expect(try unsafe direct.unsafeInvoke() == 10)
        let table = try unsafe NativeVTable(
            readingFrom: storage,
            entryCount: 1,
            authentication: .cxxVTablePointer(discriminator: ABICXXBaseVTableDiscriminator())
        )
        let virtual = try unsafe await primary.resolve(
            .cxx(
                .virtualMethod(
                    at: 0,
                    in: table,
                    authentication: .cxxVirtualFunction(
                        discriminator: ABICXXBaseSlotDiscriminator()
                    ),
                    as: (() -> Int32).self
                )
            )
        )
        #expect(try unsafe virtual.unsafeInvoke() == ABICXXBaseOracle(address))
        let offset = ABICXXSecondaryOffset(address)
        #expect(offset > 0)
        let view = try storage.view(
            at: offset,
            as: .opaque(
                named: "Secondary",
                size: ABICXXSecondarySize(),
                alignment: ABICXXSecondaryAlignment()
            )
        )
        let secondary = ABIRuntime.shared.cxxObject(view, typeNamed: "ABICXXFixture::Secondary")
        let other = try secondary.resolveAndWait(
            .cxx(
                .method(
                    "other() const",
                    as: (() -> Int32).self
                )
            )
        )
        #expect(try unsafe other.unsafeInvoke() == 20)
        let secondaryTable = try unsafe NativeVTable(
            readingFrom: view,
            entryCount: 1,
            authentication: .cxxVTablePointer(discriminator: ABICXXSecondaryVTableDiscriminator())
        )
        let secondaryVirtual = try unsafe secondary.resolveAndWait(
            .cxx(
                .virtualMethod(
                    at: 0,
                    in: secondaryTable,
                    authentication: .cxxVirtualFunction(
                        discriminator: ABICXXSecondarySlotDiscriminator()
                    ),
                    as: (() -> Int32).self
                )
            )
        )
        #expect(try unsafe secondaryVirtual.unsafeInvoke() == ABICXXSecondaryOracle(address))
    }

    @Test func capturedVirtualMethodRetainsTableOwner() throws {
        let storage = unsafe NativeValue(
            adopting: try #require(ABICXXCreateDerived()),
            as: try .opaque(
                named: "Derived",
                size: ABICXXDerivedSize(),
                alignment: ABICXXDerivedAlignment()
            ),
            release: { ABICXXDeleteDerived($0) }
        )
        let object = ABIRuntime.shared.cxxObject(storage, typeNamed: "ABICXXFixture::Base")
        let address = try #require(
            try unsafe NativePointerAuthentication.cxxVTablePointer(
                discriminator: ABICXXBaseVTableDiscriminator()
            ).readPointer(from: storage)
        )
        var owner: NSObject? = NSObject()
        weak let weakOwner = owner
        var table: NativeVTable? = try unsafe NativeVTable(
            borrowing: address,
            entryCount: 1,
            retaining: owner
        )
        var request: NativeRequest<NativeCXXVirtualMethodRequest<Int32>>? = .cxx(
            .virtualMethod(
                at: 0,
                in: table!,
                authentication: .cxxVirtualFunction(discriminator: ABICXXBaseSlotDiscriminator()),
                as: (() -> Int32).self
            )
        )
        owner = nil
        table = nil
        #expect(weakOwner != nil)
        var method: NativeBoundCXXMethod<Int32>? = try unsafe object.resolveAndWait(request!)
        request = nil
        #expect(weakOwner != nil)
        #expect(try unsafe method!.unsafeInvoke() == 110)
        method = nil
        #expect(weakOwner == nil)
    }

    @Test func boundedTablesAndNullEntriesReportErrors() throws {
        let cell = try NativeValue(copying: UnsafeRawPointer?.none, as: .pointer)
        #expect(throws: NativeDispatchError.missingVTable) {
            try unsafe NativeVTable(readingFrom: cell, entryCount: 1, authentication: .unsigned)
        }
        let table = try unsafe cell.withUnsafeBytes {
            try unsafe NativeVTable(borrowing: $0.baseAddress!, entryCount: 1, retaining: cell)
        }
        let object = ABIRuntime.shared.cxxObject(cell, typeNamed: "Unused")
        let pastEnd = NativeRequest.cxx(
            .virtualMethod(
                at: 1,
                in: table,
                authentication: .unsigned,
                as: (() -> Void).self
            )
        )
        #expect(throws: NativeDispatchError.entryOutOfBounds(index: 1, count: 1)) {
            try unsafe object.resolveAndWait(pastEnd)
        }
        let negative = NativeRequest.cxx(
            .virtualMethod(
                at: -1,
                in: table,
                authentication: .unsigned,
                as: (() -> Void).self
            )
        )
        #expect(throws: NativeDispatchError.entryOutOfBounds(index: -1, count: 1)) {
            try unsafe object.resolveAndWait(negative)
        }
        let null = NativeRequest.cxx(
            .virtualMethod(
                at: 0,
                in: table,
                authentication: .unsigned,
                as: (() -> Void).self
            )
        )
        #expect(throws: (any Error).self) {
            try unsafe object.resolveAndWait(null)
        }
        _ = unsafe cell.withUnsafeBytes { bytes in
            #expect(throws: NativeDispatchError.invalidEntryCount(Int.max)) {
                try unsafe NativeVTable(borrowing: bytes.baseAddress!, entryCount: Int.max)
            }
        }
    }

    @Test func explicitDataPointerAuthenticationUsesOriginalStorageAddress() throws {
        var number: Int32 = 73
        try withUnsafePointer(to: &number) { pointer in
            let slot = NativeValue(type: .pointer) {
                ABICXXStoreSignedDataPointer($0.baseAddress, pointer)
            }
            let read = try unsafe NativePointerAuthentication.signed(
                key: .dataB,
                discriminator: 0x1234,
                addressDiversity: true
            ).readPointer(from: slot)
            #expect(read == UnsafeRawPointer(pointer))
        }
    }
}
