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

private struct RuntimeWordResult: ABIBridgeValue {
    static let abiType = NativeType.int64
    let storage: NativeValue
    init(nativeValue: NativeValue) { storage = nativeValue }
    static func nativeValue(from value: Self) -> NativeValue { value.storage }
    func read() throws -> Int64 { try unsafe storage.read(as: Int64.self) }
}

private struct RuntimeRejectedArgument: ABIBridgeValue {
    enum Failure: Error { case rejected }
    static let abiType = NativeType.int64
    init() {}
    init(nativeValue: NativeValue) { }
    static func nativeValue(from value: Self) throws -> NativeValue { throw Failure.rejected }
}

@Suite struct SwiftRuntimeValueTests {
    @Test func runtimeResultsRestoreElidedSingletonMetatypes() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.valueMetatypeGeneric<A>(ManagedSwiftFixtures.GenericMetatypeValue<A>.Type, Swift.Int64) -> (ManagedSwiftFixtures.GenericMetatypeValue<A>.Type, Swift.Int64)",
            as: ((GenericMetatypeValue<String>.Type, Int64) -> NativeSwiftValue).self,
            genericArguments: [.type(String.self)])
        let result = try unsafe function.unsafeInvoke(GenericMetatypeValue<String>.self, Int64(40))
        let value = try result.take(as: (GenericMetatypeValue<String>.Type, Int64).self)
        #expect(unsafeBitCast(value.0, to: UInt.self) == unsafeBitCast(GenericMetatypeValue<String>.self, to: UInt.self))
        #expect(value.1 == 41)
    }
    @Test func genericRuntimeArgumentsAndResultsPreserveNativeOwnership() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        let original = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let arguments: [NativeSwiftGenericArgument] = [.type(original.type)]
        let borrow = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.borrowRuntimeValue<A where A: ~Swift.Copyable>(A) -> Swift.Int64",
            as: ((NativeSwiftValue) -> Int64).self, genericArguments: arguments)
        #expect(try unsafe borrow.unsafeInvoke(original) == Int64(MemoryLayout<RuntimeTicket>.size))
        let borrowed = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.borrowRuntimeValue<A where A: ~Swift.Copyable>(A) -> Swift.Int64",
            as: ((NativeSwiftBorrowedValue) -> Int64).self, genericArguments: arguments)
        try original.withBorrowedValue { value throws -> Void in
            #expect(try unsafe borrowed.unsafeInvoke(value) == Int64(MemoryLayout<RuntimeTicket>.size))
        }
        #expect(!original.isConsumed && counts.destructions == 0)
        do {
            _ = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: arguments)
            Issue.record("A Copyable generic declaration accepted a noncopyable substitution")
        } catch ABIResolutionError.signatureMismatch(let detail) {
            #expect(detail.expected == "A: Swift.Copyable")
        }
        let move = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.moveRuntimeValue<A where A: ~Swift.Copyable>(__owned A) -> A",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self, genericArguments: arguments)
        let moved = try unsafe move.unsafeInvoke(NativeSwiftConsuming(original))
        #expect(original.isConsumed && !moved.isConsumed && !moved.isCopyable)
        #expect(counts.destructions == 0)
        let consume = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.consumeRuntimeValueAndThrow<A where A: ~Swift.Copyable>(__owned A) throws -> ()",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) throws -> Void).self, genericArguments: arguments)
        do {
            try unsafe consume.unsafeInvoke(NativeSwiftConsuming(moved))
            Issue.record("The native error was not propagated")
        } catch let error as NativeSwiftError {
            error.withUnderlyingError { #expect($0 is RuntimeTicketFailure) }
        }
        #expect(moved.isConsumed && counts.destructions == 1)
    }

    @Test func runtimeInoutTransfersTheReplacementAndProtectsConflictingAliases() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        let first = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let second = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let replace = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.replaceRuntimeValue<A where A: ~Swift.Copyable>(inout A, __owned A) -> ()",
            as: ((NativeSwiftInout<NativeSwiftValue>, NativeSwiftConsuming<NativeSwiftValue>) -> Void).self,
            genericArguments: [.type(first.type)])
        let buffer = NativeSwiftInout(first)
        #expect(throws: NativeSwiftValueError.valueInUse) {
            try unsafe replace.unsafeInvoke(buffer, NativeSwiftConsuming(first))
        }
        #expect(!first.isConsumed && counts.destructions == 0)
        try unsafe replace.unsafeInvoke(buffer, NativeSwiftConsuming(second))
        #expect(!first.isConsumed && second.isConsumed && counts.destructions == 1)
        do {
            let value = try first.take(as: RuntimeTicket.self)
            #expect(value.number == 42)
        }
        #expect(first.isConsumed && counts.destructions == 2)
    }

    @Test func runtimeTransferSurvivesALaterArgumentConversionFailure() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let move = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.moveRuntimeValueAfterArgument<A where A: ~Swift.Copyable>(__owned A, Swift.Int64) -> A",
            as: ((NativeSwiftConsuming<NativeSwiftValue>, RuntimeRejectedArgument) -> NativeSwiftValue).self,
            genericArguments: [.type(value.type)])
        #expect(throws: RuntimeRejectedArgument.Failure.rejected) {
            try unsafe move.unsafeInvoke(NativeSwiftConsuming(value), RuntimeRejectedArgument())
        }
        #expect(!value.isConsumed && counts.destructions == 0)
        do {
            let native = try value.take(as: RuntimeTicket.self)
            #expect(native.number == 42)
        }
        #expect(counts.destructions == 1)
    }

    @Test func copyableRuntimeResultsAndMismatchedArgumentsPreserveTheirOwners() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
            as: ((Int64) -> NativeSwiftValue).self)
        let original = try unsafe make.unsafeInvoke(42)
        let copy = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(original.type)])
        let copied = try unsafe copy.unsafeInvoke(original)
        #expect(try copied.take(as: Int64.self) == 42)
        #expect(!original.isConsumed)
        let makeTicket = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let ticket = try unsafe makeTicket.unsafeInvoke(ErrorLifetimeToken {})
        do {
            _ = try unsafe copy.unsafeInvoke(ticket)
            Issue.record("A runtime argument with different native metadata was accepted")
        } catch ABIInvocationError.incompatibleValue { }
        #expect(!ticket.isConsumed)
        #expect(try original.take(as: Int64.self) == 42)
    }

    @Test func noncopyableNominalContextsPreserveTheirSuppressedRequirements() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeRuntimeTicket(_:)",
            as: ((AnyObject) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        let ticket = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.RuntimeValueBox",
            genericArguments: [.type(ticket.type)])
        let initialize = try await type.initializer(named: "init(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self)
        let box = try unsafe initialize.unsafeInvoke(NativeSwiftConsuming(ticket))
        #expect(ticket.isConsumed && !box.isConsumed && !box.isCopyable)
        #expect(throws: NativeSwiftValueError.noncopyableType) { try box.copy() }
        #expect(throws: NativeSwiftValueError.noncopyableType) { try box.withCopy { _ in } }
        let take = try await type.method(named: "takeValue()", as: (() -> NativeSwiftValue).self,
            consuming: true)
        let result = try unsafe take.unsafeInvoke(on: box)
        #expect(box.isConsumed && !result.isConsumed && counts.destructions == 0)
        do {
            let native = try result.take(as: RuntimeTicket.self)
            #expect(native.number == 42)
        }
        #expect(counts.destructions == 1)
    }

    @Test func runtimeCopyabilityEvaluatesConditionalConformance() async throws {
        let runtime = ABIRuntime.shared
        let makeInteger = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
            as: ((Int64) -> NativeSwiftValue).self)
        let integer = try unsafe makeInteger.unsafeInvoke(42)
        let copyableType = try await runtime.swiftType(named: "ManagedSwiftFixtures.RuntimeConditionalValueBox",
            genericArguments: [.type(integer.type)])
        let makeCopyable = try await copyableType.initializer(named: "init(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self)
        let copyable = try unsafe makeCopyable.unsafeInvoke(NativeSwiftConsuming(integer))
        #expect(copyable.isCopyable)
        let copy = try copyable.copy()
        #expect(try copy.take(as: RuntimeConditionalValueBox<Int64>.self).value == 42)
        let makeTicket = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeRuntimeTicket(_:)",
            as: ((AnyObject) -> NativeSwiftValue).self)
        let ticket = try unsafe makeTicket.unsafeInvoke(NSObject())
        let noncopyableType = try await runtime.swiftType(named: "ManagedSwiftFixtures.RuntimeConditionalValueBox",
            genericArguments: [.type(ticket.type)])
        let makeNoncopyable = try await noncopyableType.initializer(named: "init(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self)
        let noncopyable = try unsafe makeNoncopyable.unsafeInvoke(NativeSwiftConsuming(ticket))
        #expect(!noncopyable.isCopyable)
        #expect(throws: NativeSwiftValueError.noncopyableType) { try noncopyable.copy() }
        do {
            _ = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(noncopyable.type)])
            Issue.record("A conditional Copyable constraint accepted a noncopyable argument")
        } catch ABIResolutionError.signatureMismatch { }
    }

    @Test @MainActor func runtimeArgumentsKeepAccessThroughAsyncCompletion() async throws {
        guard #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else { return }
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let arguments: [NativeSwiftGenericArgument] = [.type(value.type)]
        let borrow = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.borrowRuntimeValueAsync<A where A: ~Swift.Copyable>(A, ManagedSwiftFixtures.AsyncGate) async -> Swift.Int64",
            as: ((NativeSwiftBorrowedValue, AsyncGate) async -> Int64).self, genericArguments: arguments)
        let gate = AsyncGate()
        let task = try value.withBorrowedValue { borrowed in
            Task.immediate { try unsafe await borrow.unsafeInvoke(borrowed, gate) }
        }
        await gate.waitUntilSuspended()
        #expect(throws: NativeSwiftValueError.valueInUse) { _ = try value.take(as: RuntimeTicket.self) }
        await gate.open()
        #expect(try await task.value == Int64(MemoryLayout<RuntimeTicket>.size))
        let move = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.moveRuntimeValueAsync<A where A: ~Swift.Copyable>(__owned A) async -> A",
            as: ((NativeSwiftConsuming<NativeSwiftValue>) async -> NativeSwiftValue).self, genericArguments: arguments)
        let moved = try unsafe await move.unsafeInvoke(NativeSwiftConsuming(value))
        #expect(value.isConsumed && counts.destructions == 0)
        do {
            let native = try moved.take(as: RuntimeTicket.self)
            #expect(native.number == 42)
        }
        #expect(moved.isConsumed && counts.destructions == 1)
    }
    #if DEBUG && os(macOS)
    @Test func anOpaqueFactoryKeepsItsOwnCodeAndUsesTheUnderlyingTypeImage() async throws {
        let module = "OpaqueType_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let provider = try FixtureLibrary(load: false, swiftModule: module, swiftSource: """
            public final class Box {
                private let body: () -> Int64
                public init(_ body: @escaping () -> Int64) { self.body = body }
                public var value: Int64 { body() }
                public consuming func take() -> Int64 { body() }
            }
            private final class HiddenBox {
                private let body: () -> Int64
                init(_ body: @escaping () -> Int64) { self.body = body }
                var value: Int64 { body() }
                consuming func take() -> Int64 { body() }
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
            #expect(try unsafe getter.unsafeInvoke(on: value) == number)
            weak var observed: AnyObject?
            try value.withCopy { observed = $0 as AnyObject }
            let take = try await value.type.method(named: "take()", as: (() -> Int64).self, consuming: true)
            #expect(try unsafe take.unsafeInvoke(on: value) == number)
            #expect(value.isConsumed && observed == nil)
        }
    }
    #endif

    @Test func runtimeValuesUseOrdinaryMembersWithExplicitOwnership() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let abi = try NativeType.opaque(named: value.type.name)
        let read = try await value.type.method(named: "read()", as: (() -> Int64).self, receiverABI: abi)
        let getter = try await value.type.getter(named: "number", as: (() -> Int64).self, receiverABI: abi)
        let add = try await value.type.method(named: "add(_:)", as: ((Int64) -> Void).self,
            receiverABI: abi, mutating: true)
        let take = try await value.type.method(named: "takeNumber()", as: (() -> Int64).self,
            receiverABI: abi, consuming: true)
        #expect(try unsafe read.unsafeInvoke(on: value) == 42)
        try unsafe add.unsafeInvoke(on: value, 5)
        #expect(try unsafe getter.unsafeInvoke(on: value) == 47)
        var escaped: NativeSwiftBorrowedValue?
        try value.withBorrowedValue { borrowed in
            escaped = borrowed
            let number = try unsafe read.unsafeInvoke(on: borrowed)
            #expect(number == 47)
            #expect(throws: NativeSwiftValueError.valueInUse) { try unsafe add.unsafeInvoke(on: value, 1) }
            #expect(throws: NativeSwiftValueError.valueInUse) { try unsafe take.unsafeInvoke(on: borrowed) }
            #expect(throws: NativeSwiftValueError.valueInUse) { try unsafe take.unsafeInvoke(on: value) }
        }
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try unsafe read.unsafeInvoke(on: escaped!) }
        #expect(try unsafe take.unsafeInvoke(on: value) == 47)
        #expect(value.isConsumed && counts.destructions == 1)
        #expect(throws: NativeSwiftValueError.consumedValue) { try unsafe read.unsafeInvoke(on: value) }
    }

    @Test(arguments: [false, true]) @MainActor func aStartedAsyncBorrowRetainsItsOwnerAccessAfterScopeExit(_ inoutReceiver: Bool) async throws {
        guard #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else { return }
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let abi = try NativeType.opaque(named: value.type.name)
        let read = try await value.type.method(named: "readAfter(_:)", as: ((AsyncGate) async -> Int64).self,
            receiverABI: abi)
        let add = try await value.type.method(named: "add(_:)", as: ((Int64) -> Void).self,
            receiverABI: abi, mutating: true)
        let gate = AsyncGate()
        let task = try value.withBorrowedValue { borrowed in
            Task.immediate { @MainActor in
                var receiver = borrowed
                if inoutReceiver { return try unsafe await read.unsafeInvoke(on: &receiver, gate) }
                return try unsafe await read.unsafeInvoke(on: receiver, gate)
            }
        }
        await gate.waitUntilSuspended()
        #expect(throws: NativeSwiftValueError.valueInUse) { try unsafe add.unsafeInvoke(on: value, 1) }
        await gate.open()
        #expect(try await task.value == 42)
        do {
            let ticket = try value.take(as: RuntimeTicket.self)
            #expect(ticket.number == 42)
        }
        #expect(value.isConsumed && counts.destructions == 1)
    }

    @Test func resultAdaptersDoNotRetainReceiverAccess() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let abi = try NativeType.opaque(named: value.type.name)
        let read = try await value.type.method(named: "read() -> Swift.Int64", as: (() -> RuntimeWordResult).self,
            receiverABI: abi)
        let readAsync = try await value.type.method(named: "readAsync() async -> Swift.Int64",
            as: (() async -> RuntimeWordResult).self, receiverABI: abi)
        let add = try await value.type.method(named: "add(_:)", as: ((Int64) -> Void).self,
            receiverABI: abi, mutating: true)
        let take = try await value.type.method(named: "takeNumberAsync() async -> Swift.Int64",
            as: (() async -> RuntimeWordResult).self, receiverABI: abi, consuming: true)
        let first = try unsafe read.unsafeInvoke(on: value)
        try unsafe add.unsafeInvoke(on: value, 1)
        let second = try unsafe await readAsync.unsafeInvoke(on: value)
        try unsafe add.unsafeInvoke(on: value, 1)
        let final = try unsafe await take.unsafeInvoke(on: value)
        #expect(try first.read() == 42 && second.read() == 43 && final.read() == 44)
        #expect(value.isConsumed && counts.destructions == 1)
    }

    @Test @MainActor func borrowedResultAdaptersRetainResourcesAfterAccessEnds() async throws {
        guard #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else { return }
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        var results: [RuntimeWordResult] = []
        do {
            let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
            let abi = try NativeType.opaque(named: value.type.name)
            let read = try await value.type.method(named: "read() -> Swift.Int64", as: (() -> RuntimeWordResult).self,
                receiverABI: abi)
            let readAsync = try await value.type.method(named: "readAsync() async -> Swift.Int64",
                as: (() async -> RuntimeWordResult).self, receiverABI: abi)
            let add = try await value.type.method(named: "add(_:)", as: ((Int64) -> Void).self,
                receiverABI: abi, mutating: true)
            results.append(try value.withBorrowedValue { try unsafe read.unsafeInvoke(on: $0) })
            let operation = try value.withBorrowedValue { borrowed in
                Task.immediate { @MainActor in
                    results.append(try unsafe await readAsync.unsafeInvoke(on: borrowed))
                }
            }
            try await operation.value
            try unsafe add.unsafeInvoke(on: value, 1)
        }
        #expect(counts.destructions == 0)
        #expect(try results.map { try $0.read() } == [42, 42])
        results.removeAll()
        #expect(counts.destructions == 1)
    }

    @Test func runtimeMemberAccessSurvivesSuspensionAndNativeFailure() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
            as: ((ErrorLifetimeToken) -> NativeSwiftValue).self)
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let abi = try NativeType.opaque(named: value.type.name)
        let read = try await value.type.method(named: "readAsync()", as: (() async -> Int64).self, receiverABI: abi)
        let add = try await value.type.method(named: "addThenThrow(_:)", as: ((Int64) async throws -> Void).self,
            receiverABI: abi, mutating: true)
        let take = try await value.type.method(named: "takeNumberAsync()", as: (() async -> Int64).self,
            receiverABI: abi, consuming: true)
        #expect(try unsafe await read.unsafeInvoke(on: value) == 42)
        do {
            try unsafe await add.unsafeInvoke(on: value, 5)
            Issue.record("Native failure was not propagated")
        } catch is NativeSwiftError { }
        #expect(try unsafe await read.unsafeInvoke(on: value) == 47)
        #expect(!value.isConsumed && counts.destructions == 0)
        #expect(try unsafe await take.unsafeInvoke(on: value) == 47)
        #expect(value.isConsumed && counts.destructions == 1)
    }

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
        let source = UnsafeMutablePointer<RuntimeCopyablePayload>.allocate(capacity: 1)
        source.initialize(to: RuntimeCopyablePayload(life: RuntimeValueLife(deaths), text: String(repeating: "owned", count: 100)))
        let copy = UnsafeMutableRawPointer.allocate(byteCount: layout.stride, alignment: layout.alignment)
        defer { source.deallocate(); copy.deallocate() }
        ABISwiftCopyValue(metadata, copy, source)
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
        let source = UnsafeMutablePointer<RuntimeMoveOnlyPayload>.allocate(capacity: 1)
        source.initialize(to: RuntimeMoveOnlyPayload(life: RuntimeValueLife(deaths), text: String(repeating: "moved", count: 100)))
        let destination = UnsafeMutableRawPointer.allocate(byteCount: layout.stride, alignment: layout.alignment)
        destination.initializeMemory(as: UInt8.self, repeating: 0xa5, count: layout.stride)
        defer { source.deallocate(); destination.deallocate() }
        #expect(source.pointee.text == String(repeating: "moved", count: 100))
        ABISwiftTakeValue(metadata, destination, source)
        #expect(deaths.count.withLock { $0 } == 0)
        #expect(destination.assumingMemoryBound(to: RuntimeMoveOnlyPayload.self).pointee.text == String(repeating: "moved", count: 100))
        ABISwiftDestroyValue(metadata, destination)
        #expect(deaths.count.withLock { $0 } == 1)
    }
}
