import ABIBridge
import ABIBridgeCore
import ManagedSwiftFixtures
import Foundation
import Synchronization
import Testing

private final class RuntimeValueDeaths: Sendable {
    let count = Mutex(0)
}
private final class RuntimeValueLife {
    let deaths: RuntimeValueDeaths
    init(_ deaths: RuntimeValueDeaths) { self.deaths = deaths }
    deinit { deaths.count.withLock { $0 += 1 } }
}
private struct RuntimeCopyablePayload {
    let life: RuntimeValueLife
    let text: String
}
private struct RuntimeMoveOnlyPayload: ~Copyable {
    let life: RuntimeValueLife
    let text: String
}

@Suite struct SwiftRuntimeValueTests {
    #if DEBUG && os(macOS)
    @Test func anOpaqueFactoryKeepsItsOwnCodeAndUsesTheUnderlyingTypeImage() async throws {
        let module = "OpaqueType_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let provider = try FixtureLibrary(load: false, swiftModule: module, swiftSource: """
            public final class Box {
                private let body: () -> Int64
                public init(_ body: @escaping () -> Int64) { self.body = body }
                public var value: Int64 { body() }
            }
            private final class HiddenBox {
                private let body: () -> Int64
                init(_ body: @escaping () -> Int64) { self.body = body }
                var value: Int64 { body() }
            }
            public func hidden(_ body: @escaping () -> Int64) -> some AnyObject { HiddenBox(body) }
            """, linkArguments: ["-swift-version", "6", "-emit-module", "-enable-library-evolution"])
        defer { provider.cleanup() }
        let factory = try FixtureLibrary(load: false, swiftModule: module + "Factory", swiftSource: """
            import \(module)
            public func make() -> some AnyObject { Box { 42 } }
            public func makeHidden() -> some AnyObject { hidden { 43 } }
            """, linkArguments: ["-swift-version", "6", "-I", provider.directory.path, provider.libraryURL.path])
        defer { factory.cleanup() }
        try factory.load()
        let runtime = ABIRuntime()
        for (name, number) in [("make", Int64(42)), ("makeHidden", Int64(43))] {
            let value: NativeSwiftValue
            do {
                let make = try await runtime.swiftFunction(named: module + "Factory." + name + "()",
                    as: (() -> NativeSwiftValue).self, in: .path(factory.libraryURL))
                value = try unsafe make.unsafeInvoke().copy()
            }
            await runtime.removeCachedResults()
            factory.close()
            let expected = try #require(try await runtime.images(matching: .path(provider.libraryURL)).first)
            #expect(value.type.image.identity == expected.identity)
            let getter = try await value.type.getter(named: "value", as: (() -> Int64).self)
            try value.withCopy { object in
                let result = try unsafe getter.unsafeInvoke(on: object as AnyObject)
                #expect(result == number)
            }
        }
    }
    #endif

    @Test func aCopyOfATemporaryRetainsItsManagedPayload() async throws {
        let make = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.makeOpaque(_:_:)",
            as: ((ErrorLifetimeToken, Int64) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        var copy: NativeSwiftValue? = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() }, 42).copy()
        #expect(counts.destructions == 0)
        try copy!.withCopy { #expect(($0 as? any ExistentialValue)?.number == 42) }
        copy = nil
        #expect(counts.destructions == 1)
    }

    @Test func opaqueNoncopyableValuesMoveWithoutAnyErasure() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        weak var observed: ErrorLifetimeToken?
        let value: NativeSwiftValue
        do {
            let token = ErrorLifetimeToken { counts.destroyed() }
            observed = token
            value = try unsafe make.unsafeInvoke(token)
        }
        #expect(!value.isCopyable && !value.isConsumed && observed != nil)
        #expect(throws: NativeSwiftValueError.noncopyableType) { try value.copy() }
        #expect(throws: NativeSwiftValueError.noncopyableType) { try value.withCopy { _ in } }
        try value.withBorrowedValue { borrowed in
            #expect(throws: NativeSwiftValueError.noncopyableType) { try borrowed.copy() }
        }
        do {
            let ticket = try value.take(as: RuntimeTicket.self)
            #expect(ticket.number == 42 && value.isConsumed && observed != nil)
        }
        #expect(observed == nil && counts.destructions == 1)

        let copyable = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeCopyableNoncopyableOpaque()",
            as: (() -> NativeSwiftValue).self)
        let actual = try unsafe copyable.unsafeInvoke()
        #expect(actual.isCopyable)
        let copy = try actual.copy()
        #expect(try copy.take(as: Int64.self) == 42)
        #expect(try actual.take(as: Int64.self) == 42)
    }

    @Test func ownedCopiesMovesAndScopedBorrowsHaveIndependentLifetimes() async throws {
        let make = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeOpaqueInteger(_:)", as: ((Int64) -> NativeSwiftValue).self)
        let value = try unsafe make.unsafeInvoke(42)
        #expect(value.isCopyable && !value.isConsumed)
        let copy = try value.copy()
        var escaped: NativeSwiftBorrowedValue?
        var borrowedCopy: NativeSwiftValue?
        try value.withBorrowedValue { borrowed in
            escaped = borrowed
            borrowedCopy = try borrowed.copy()
            #expect(throws: NativeSwiftValueError.valueInUse) {
                try value.take(as: Int64.self)
            }
            #expect(try copy.take(as: Int64.self) == 42)
        }
        #expect(copy.isConsumed)
        #expect(try value.take(as: Int64.self) == 42)
        #expect(value.isConsumed)
        #expect(throws: NativeSwiftValueError.consumedValue) { try value.copy() }
        #expect(throws: NativeSwiftValueError.consumedValue) { try value.take(as: Int64.self) }
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try escaped!.copy() }
        #expect(try borrowedCopy!.take(as: Int64.self) == 42)
    }

    @Test func aMismatchedTypedTakeLeavesTheOwnedValueUsable() async throws {
        let make = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeOpaqueInteger(_:)", as: ((Int64) -> NativeSwiftValue).self)
        let value = try unsafe make.unsafeInvoke(42)
        #expect(throws: ABIInvocationError.self) { try value.take(as: String.self) }
        #expect(!value.isConsumed)
        #expect(try value.take(as: Int64.self) == 42)
    }

    @Test func witnessesCopyAndDestroyManagedStorage() throws {
        let deaths = RuntimeValueDeaths()
        let metadata = unsafeBitCast(RuntimeCopyablePayload.self, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(metadata)
        #expect(layout.size == MemoryLayout<RuntimeCopyablePayload>.size)
        #expect(layout.stride == MemoryLayout<RuntimeCopyablePayload>.stride)
        #expect(layout.alignment == MemoryLayout<RuntimeCopyablePayload>.alignment)
        #expect(layout.isCopyable)
        let source = UnsafeMutablePointer<RuntimeCopyablePayload>.allocate(capacity: 1)
        source.initialize(to: RuntimeCopyablePayload(life: RuntimeValueLife(deaths), text: String(repeating: "owned", count: 100)))
        let copy = UnsafeMutableRawPointer.allocate(byteCount: layout.stride, alignment: layout.alignment)
        defer { source.deallocate(); copy.deallocate() }
        #expect(ABISwiftCopyValue(metadata, copy, source))
        ABISwiftDestroyValue(metadata, source)
        #expect(deaths.count.withLock { $0 } == 0)
        #expect(copy.load(as: RuntimeCopyablePayload.self).text == String(repeating: "owned", count: 100))
        ABISwiftDestroyValue(metadata, copy)
        #expect(deaths.count.withLock { $0 } == 1)
    }

    @Test func witnessesMoveNoncopyableStorageWithoutCopying() throws {
        let deaths = RuntimeValueDeaths()
        let metadata = unsafeBitCast(RuntimeMoveOnlyPayload.self, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(metadata)
        #expect(layout.size == MemoryLayout<RuntimeMoveOnlyPayload>.size)
        #expect(layout.stride == MemoryLayout<RuntimeMoveOnlyPayload>.stride)
        #expect(layout.alignment == MemoryLayout<RuntimeMoveOnlyPayload>.alignment)
        #expect(!layout.isCopyable)
        let source = UnsafeMutablePointer<RuntimeMoveOnlyPayload>.allocate(capacity: 1)
        source.initialize(to: RuntimeMoveOnlyPayload(life: RuntimeValueLife(deaths), text: String(repeating: "moved", count: 100)))
        let destination = UnsafeMutableRawPointer.allocate(byteCount: layout.stride, alignment: layout.alignment)
        destination.initializeMemory(as: UInt8.self, repeating: 0xa5, count: layout.stride)
        defer { source.deallocate(); destination.deallocate() }
        #expect(!ABISwiftCopyValue(metadata, destination, source))
        #expect(UnsafeRawBufferPointer(start: destination, count: layout.stride).allSatisfy { $0 == 0xa5 })
        #expect(source.pointee.text == String(repeating: "moved", count: 100))
        ABISwiftTakeValue(metadata, destination, source)
        #expect(deaths.count.withLock { $0 } == 0)
        #expect(destination.assumingMemoryBound(to: RuntimeMoveOnlyPayload.self).pointee.text == String(repeating: "moved", count: 100))
        ABISwiftDestroyValue(metadata, destination)
        #expect(deaths.count.withLock { $0 } == 1)
    }
}
