import ABIBridgeTestSupport
import ABIBridge
import ABIBridgeCore
import ABIBridgeCore.Backend
import ManagedSwiftFixtures
import Foundation
import Synchronization
import Testing

private final class RuntimeValueDeaths: Sendable {
    let count = Mutex(0)
}
private final class RuntimeValueLife: Sendable {
    let deaths: RuntimeValueDeaths
    init(_ deaths: RuntimeValueDeaths) { self.deaths = deaths }
    deinit { deaths.count.withLock { $0 += 1 } }
}
private final class RuntimeCallbackValues: @unchecked Sendable {
    var borrowed: NativeSwiftBorrowedValue?
    var owned: NativeSwiftValue?
    var nested: NativeSwiftClosure<(NativeSwiftValue) -> NativeSwiftValue>?
    var predicate: NativeSwiftClosure<() -> Bool>?
    var asyncText: NativeSwiftClosure<nonisolated(nonsending) (String) async -> String>?
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
    init(nativeValue: NativeValue) {}
    static func nativeValue(from value: Self) throws -> NativeValue { throw Failure.rejected }
}

private final class NestedRuntimePackCopies: @unchecked Sendable {
    var number: NativeSwiftClosure<(Int64) -> Int64>?
    var text: NativeSwiftClosure<(String) -> String>?
}

@Suite struct SwiftRuntimeValueTests {
    @Test(arguments: [false, true])
    func variadicTupleInitializersConsumeTheArrayTail(_ hasTail: Bool) async throws {
        typealias Entry = (LifetimeToken, String)
        let runtime = ABIRuntime()
        let path = try #require(Bundle(for: LifetimeToken.self).executableURL)
        let type = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.VariadicTupleSeries",
                    genericArguments: [.type(LifetimeToken.self)]
                )
            ),
            in: .path(path)
        )
        let initialize = try await type.resolve(
            .swift(
                .initializer(
                    "init((A, Swift.String), (A, Swift.String)...) -> ManagedSwiftFixtures.VariadicTupleSeries<A>",
                    as: ((NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
                    valueABIs: [type: .opaque(named: type.name)]
                )
            )
        )
        let ownEntry = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((Entry) -> NativeSwiftValue).self,
                    genericArguments: [.type(Entry.self)]
                )
            ),
            in: .path(path)
        )
        let ownTail = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: (([Entry]) -> NativeSwiftValue).self,
                    genericArguments: [.type([Entry].self)]
                )
            ),
            in: .path(path)
        )
        weak var observed: LifetimeToken?
        var deaths = 0
        var result: NativeSwiftValue?
        do {
            let token = LifetimeToken { deaths += 1 }
            observed = token
            let first = try unsafe ownEntry.unsafeInvoke((token, "first"))
            let remaining = try unsafe ownTail.unsafeInvoke(hasTail ? [(token, "tail")] : [])
            result = try unsafe initialize.unsafeInvoke(first, remaining)
            #expect(first.isConsumed && remaining.isConsumed)
        }
        #expect(observed != nil && deaths == 0)
        try result?.withCopy {
            let series = try #require($0 as? VariadicTupleSeries<LifetimeToken>)
            #expect(series.values.map(\.1) == (hasTail ? ["first", "tail"] : ["first"]))
            #expect(series.values.allSatisfy { $0.0 === observed })
        }
        result = nil
        #expect(observed == nil && deaths == 1)
    }

    @Test func ordinaryRuntimeResultsRequireScopedInvocation() async throws {
        let runtime = ABIRuntime.shared
        let copy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((Int64) -> NativeSwiftBorrowedValue).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        #expect(throws: ABIResolutionError.self) { try unsafe copy.unsafeInvoke(42) }
        typealias Producer = NativeSwiftClosure<() -> NativeSwiftBorrowedValue>
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProducer<A>(A) -> () -> A",
                    as: ((Int64) -> Producer).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let producer = try unsafe make.unsafeInvoke(42)
        #expect(throws: ABIResolutionError.self) { try unsafe producer.unsafeInvoke() }
    }

    @Test func composedTuplesUseNativeFieldLayoutsAndOwnership() async throws {
        typealias Callback = NativeSwiftClosure<(Int64) -> Int64>
        typealias Snapshot = (
            lead: Int8, record: NativeSwiftValue,
            nested: (callback: Callback, text: String, tail: Int8)
        )
        typealias BorrowedSnapshot = (
            lead: Int8, record: NativeSwiftBorrowedValue,
            nested: (callback: Callback, text: String, tail: Int8)
        )
        typealias Inspect = NativeSwiftClosure<(BorrowedSnapshot) throws -> Int64>
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolve(.swift(.type("ManagedSwiftFixtures.RuntimeFixedPair")))
        let abi = try NativeType.structure(named: type.name, fields: [.int64, .int64])
        let abis = [type: abi]
        let nativeSnapshot =
            "(lead: Swift.Int8, record: ManagedSwiftFixtures.RuntimeFixedPair, nested: (callback: (Swift.Int64) -> Swift.Int64, text: Swift.String, tail: Swift.Int8))"
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeCompositionSnapshot(Swift.AnyObject, Swift.Int64, Swift.Int64, Swift.String) -> "
                        + nativeSnapshot,
                    as: ((AnyObject, Int64, Int64, String) -> Snapshot).self,
                    valueABIs: abis
                )
            )
        )
        let echo = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.echoCompositionSnapshot(\(nativeSnapshot)) -> "
                        + nativeSnapshot,
                    as: ((Snapshot) -> Snapshot).self,
                    valueABIs: abis
                )
            )
        )
        let consume = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.consumeCompositionSnapshot(__owned \(nativeSnapshot)) -> "
                        + nativeSnapshot,
                    as: ((NativeSwiftConsuming<Snapshot>) -> Snapshot).self,
                    valueABIs: abis
                )
            )
        )
        let inspect = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.inspectCompositionSnapshot(\(nativeSnapshot), (\(nativeSnapshot)) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((Snapshot, Inspect) throws -> Int64).self,
                    valueABIs: abis
                )
            )
        )
        let sum = try await type.resolve(
            .swift(
                .method(
                    "sum()",
                    as: (() -> Int64).self,
                    receiverABI: abi
                )
            )
        )
        let text = String(repeating: "composed tuple ", count: 80)
        let deaths = RuntimeValueDeaths()
        #expect(MemoryLayout<NativeSwiftValue>.size != MemoryLayout<RuntimeFixedPair>.size)
        do {
            let life = RuntimeValueLife(deaths)
            let snapshot = try unsafe make.unsafeInvoke(life, 35, 7, text)
            let control = echoCompositionSnapshot(makeCompositionSnapshot(life, 35, 7, text))
            let echoed = try unsafe echo.unsafeInvoke(snapshot)
            #expect(echoed.lead == control.lead && echoed.nested.tail == control.nested.tail)
            #expect(echoed.nested.text == control.nested.text)
            #expect(try unsafe sum.unsafeInvoke(on: echoed.record) == control.record.sum())
            #expect(try unsafe echoed.nested.callback.unsafeInvoke(3) == control.nested.callback(3))
            #expect(!snapshot.record.isConsumed)
            let body = try Inspect { value in
                #expect(value.lead == 11 && value.nested.tail == -7 && value.nested.text == text)
                return try unsafe sum.unsafeInvoke(on: value.record)
                    + value.nested.callback.unsafeInvoke(0)
            }
            #expect(try unsafe inspect.unsafeInvoke(snapshot, body) == 84)
            let moved = try unsafe consume.unsafeInvoke(NativeSwiftConsuming(echoed))
            #expect(echoed.record.isConsumed && !snapshot.record.isConsumed)
            #expect(moved.lead == 11 && moved.nested.tail == -7 && moved.nested.text == text)
            #expect(try unsafe sum.unsafeInvoke(on: moved.record) == 42)
            #expect(try unsafe moved.nested.callback.unsafeInvoke(0) == 42)
            #expect(try unsafe echoed.nested.callback.unsafeInvoke(0) == 42)
            #expect(deaths.count.withLock { $0 } == 0)
        }
        #expect(deaths.count.withLock { $0 } == 1)
    }

    @Test func wholeRuntimeTuplesUseSwiftStorageForCopyTakeAndInout() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolve(.swift(.type("ManagedSwiftFixtures.RuntimeFixedPair")))
        let abi = try NativeType.structure(named: type.name, fields: [.int64, .int64])
        let native =
            "(lead: Swift.Int8, record: ManagedSwiftFixtures.RuntimeFixedPair, nested: (callback: (Swift.Int64) -> Swift.Int64, text: Swift.String, tail: Swift.Int8))"
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeCompositionSnapshot(Swift.AnyObject, Swift.Int64, Swift.Int64, Swift.String) -> "
                        + native,
                    as: ((AnyObject, Int64, Int64, String) -> NativeSwiftValue).self,
                    valueABIs: [type: abi]
                )
            )
        )
        let echo = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.echoCompositionSnapshot(\(native)) -> " + native,
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    valueABIs: [type: abi]
                )
            )
        )
        let copy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    genericArguments: [.type(CompositionSnapshot.self)]
                )
            )
        )
        let mutate = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.mutateCompositionSnapshot(inout \(native), Swift.Int64) -> ()",
                    as: ((NativeSwiftInout<NativeSwiftValue>, Int64) -> Void).self,
                    valueABIs: [type: abi]
                )
            )
        )
        let mutateBorrow = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.mutateCompositionSnapshot(inout \(native), Swift.Int64) -> ()",
                    as: ((NativeSwiftInout<NativeSwiftBorrowedValue>, Int64) -> Void).self,
                    valueABIs: [type: abi]
                )
            )
        )
        typealias Edit = NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Void>
        let edit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.editCompositionSnapshot(inout \(native), (inout \(native)) throws -> ()) throws -> ()",
                    as: ((NativeSwiftInout<NativeSwiftValue>, Edit) throws -> Void).self,
                    valueABIs: [type: abi]
                )
            )
        )
        let deaths = RuntimeValueDeaths()
        let captured = RuntimeCallbackValues()
        do {
            let original = try unsafe make.unsafeInvoke(
                RuntimeValueLife(deaths),
                35,
                7,
                "whole tuple"
            )
            let value = try unsafe echo.unsafeInvoke(original)
            let copied = try unsafe copy.unsafeInvoke(value)
            try copied.withCopy { value in
                let tuple = try #require(value as? CompositionSnapshot)
                #expect(tuple.nested.callback(3) == 45)
                #expect(tuple.record.sum() == 42 && tuple.nested.text == "whole tuple")
            }
            let slot = NativeSwiftInout(value)
            try unsafe mutate.unsafeInvoke(slot, 5)
            let body = try Edit { value in
                captured.borrowed = value
                try unsafe mutateBorrow.unsafeInvoke(NativeSwiftInout(value), 7)
                throw RuntimeRejectedArgument.Failure.rejected
            }
            do {
                try unsafe edit.unsafeInvoke(slot, body)
                Issue.record("Missing callback error")
            } catch let error as NativeSwiftError {
                #expect(error.withUnderlyingError { $0 is RuntimeRejectedArgument.Failure })
            }
            #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try captured.borrowed!.copy() }
            let changed = try slot.value.take(as: CompositionSnapshot.self)
            let unchanged = try original.take(as: CompositionSnapshot.self)
            #expect(changed.nested.callback(3) == 57 && changed.nested.tail == -9)
            #expect(unchanged.nested.callback(3) == 45 && unchanged.nested.tail == -7)
            #expect(deaths.count.withLock { $0 } == 0)
        }
        #expect(deaths.count.withLock { $0 } == 1)
    }

    @MainActor @Test func genericFunctionDataDoesNotRequireCallablePreparation() async throws {
        typealias Value = @MainActor (Int64) -> Int64
        let runtime = ABIRuntime.shared
        let copy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((@escaping Value) -> NativeSwiftValue).self,
                    genericArguments: [.type(Value.self)]
                )
            )
        )
        let first: Value = { $0 + 7 }
        let value = try unsafe copy.unsafeInvoke(first)
        let callable = try value.take(as: Value.self)
        #expect(callable(35) == 42)
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProducer<A>(A) -> () -> A",
                    as: ((@escaping Value) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
                    genericArguments: [.type(Value.self)]
                )
            )
        )
        let second: Value = { $0 + 9 }
        let producer = try unsafe make.unsafeInvoke(second)
        let returned = try unsafe producer.unsafeInvoke().take(as: Value.self)
        #expect(returned(33) == 42)
        typealias Extended = @MainActor (any Collection<Int>) -> Int
        let extendedCopy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((@escaping Extended) -> NativeSwiftValue).self,
                    genericArguments: [.type(Extended.self)]
                )
            )
        )
        let extended: Extended = { $0.reduce(0, +) }
        let extendedValue = try unsafe extendedCopy.unsafeInvoke(extended).take(as: Extended.self)
        #expect(extendedValue([40, 2]) == 42)
        typealias Metatype = @MainActor (any RuntimeClassLeft<Int>.Type) -> Int
        let metatypeCopy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((@escaping Metatype) -> NativeSwiftValue).self,
                    genericArguments: [.type(Metatype.self)]
                )
            )
        )
        let metatype: Metatype = {
            ObjectIdentifier($0) == ObjectIdentifier(RuntimeClassBoth<Int>.self) ? 42 : -1
        }
        let copiedMetatype = try unsafe metatypeCopy.unsafeInvoke(metatype).take(as: Metatype.self)
        #expect(copiedMetatype(RuntimeClassBoth<Int>.self) == 42)
    }

    @Test func nonescapingRuntimeClosureViewsUseScopedAdapters() async throws {
        let runtime = ABIRuntime.shared
        typealias Callback = NativeSwiftClosure<(Int64) -> Int64>
        typealias Inspect = NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Int64>
        let invoke = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.invokeCompositionClosure((Swift.Int64) -> Swift.Int64, Swift.Int64) -> Swift.Int64",
                    as: ((NativeSwiftBorrowedValue, Int64) -> Int64).self
                )
            )
        )
        let inspect = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.inspectCompositionClosure((Swift.Int64) -> Swift.Int64, ((Swift.Int64) -> Swift.Int64) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((Callback, Inspect) throws -> Int64).self
                )
            )
        )
        let captured = RuntimeCallbackValues()
        let body = try Inspect { value in
            captured.borrowed = value
            #expect(throws: ABIResolutionError.self) { try value.copy() }
            return try unsafe invoke.unsafeInvoke(value, 35)
        }
        #expect(try unsafe inspect.unsafeInvoke(Callback { $0 + 7 }, body) == 42)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe invoke.unsafeInvoke(captured.borrowed!, 35) as Int64
        }
    }

    @Test func closureInoutReabstractsSwapsAndWritesBackThrowingCallbacks() async throws {
        typealias Callback = NativeSwiftClosure<(Int64) -> Int64>
        typealias Edit = NativeSwiftClosure<(NativeSwiftInout<Callback>) throws -> Void>
        let runtime = ABIRuntime.shared
        let swap = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.swapRuntimeClosures<A>(inout (A) -> A, inout (A) -> A) -> ()",
                    as: ((NativeSwiftInout<Callback>, NativeSwiftInout<Callback>) -> Void).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeClosure<A>(inout (A) -> A, (inout (A) -> A) throws -> ()) throws -> ()",
                    as: ((NativeSwiftInout<Callback>, Edit) throws -> Void).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let first = NativeSwiftInout(try Callback { $0 + 7 })
        let second = NativeSwiftInout(try Callback { $0 * 2 })
        try unsafe swap.unsafeInvoke(first, second)
        #expect(try unsafe first.value.unsafeInvoke(21) == 42)
        #expect(try unsafe second.value.unsafeInvoke(35) == 42)
        let unchanged: @Sendable (NativeSwiftInout<Callback>) throws -> Void = { value in
            let result = try unsafe value.value.unsafeInvoke(21)
            #expect(result == 42)
        }
        try unsafe visit.unsafeInvoke(first, Edit(unchanged))
        #expect(try unsafe first.value.unsafeInvoke(21) == 42)
        let change = try Edit { value in
            value.value = try Callback { $0 + 1 }
            throw RuntimeTicketFailure.rejected
        }
        do {
            try unsafe visit.unsafeInvoke(first, change); Issue.record("Missing callback error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is RuntimeTicketFailure })
        }
        #expect(try unsafe first.value.unsafeInvoke(41) == 42)
        #expect(try unsafe second.value.unsafeInvoke(35) == 42)
    }

    @Test(arguments: [false, true])
    func failedClosureWritebackPreservesEverySlotAndBodyError(_ bodyFails: Bool) async throws {
        typealias Callback = NativeSwiftClosure<(Int64) -> Int64>
        typealias Capture = NativeSwiftClosure<(Callback) throws -> Int64>
        typealias Edit = NativeSwiftClosure<
            (NativeSwiftInout<Callback>, NativeSwiftInout<Callback>) throws -> Int64
        >
        let runtime = ABIRuntime.shared
        let acquire = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitNestedClosure(((Swift.Int64) -> Swift.Int64) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((Capture) throws -> Int64).self
                )
            )
        )
        let saved = NestedRuntimePackCopies()
        let capture: @Sendable (Callback) throws -> Int64 = { value in
            saved.number = value
            return try unsafe value.unsafeInvoke(0)
        }
        _ = try unsafe acquire.unsafeInvoke(Capture(capture))
        let expired = try #require(saved.number)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try expired.copy() }
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeClosurePair<A>(inout (A) -> A, inout (A) -> A, (inout (A) -> A, inout (A) -> A) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((NativeSwiftInout<Callback>, NativeSwiftInout<Callback>, Edit) throws
                        -> Int64)
                        .self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let first = NativeSwiftInout(try Callback { $0 + 7 })
        let second = NativeSwiftInout(try Callback { $0 * 2 })
        let deaths = RuntimeValueDeaths()
        let change:
            @Sendable (NativeSwiftInout<Callback>, NativeSwiftInout<Callback>) throws -> Int64 = {
                first,
                second in
                let life = RuntimeValueLife(deaths)
                first.value = try Callback { value in withExtendedLifetime(life) { value + 100 } }
                second.value = saved.number!
                if bodyFails { throw RuntimeTicketFailure.rejected }
                return 99
            }
        do {
            _ = try unsafe visit.unsafeInvoke(first, second, Edit(change))
            Issue.record("A failed closure replacement must not return the callback result")
        } catch let error as NativeSwiftError {
            if bodyFails {
                let combined = try #require(
                    error.withUnderlyingError { $0 as? NativeSwiftWritebackError }
                )
                #expect(combined.invocationError is RuntimeTicketFailure)
                guard case ABIResolutionError.unsupportedDeclaration = combined.writebackError
                else {
                    Issue.record(combined.writebackError)
                    return
                }
            } else {
                #expect(
                    error.withUnderlyingError {
                        if case ABIResolutionError.unsupportedDeclaration = $0 { return true }
                        return false
                    }
                )
            }
        }
        #expect(try unsafe first.value.unsafeInvoke(35) == 42)
        #expect(try unsafe second.value.unsafeInvoke(21) == 42)
        #expect(deaths.count.withLock { $0 } == 1)
    }

    @MainActor @Test(arguments: [false, true])
    func weakTupleFieldsPreserveWitnessesAcrossCallbacksAndSuspension(
        _ resilient: Bool
    ) async throws {
        typealias Owned = (Int8, NativeSwiftValue, Int64)
        typealias Borrowed = (Int8, NativeSwiftBorrowedValue, Int64)
        typealias Body = NativeSwiftClosure<(Borrowed) throws -> Owned>
        typealias AsyncBody = NativeSwiftClosure<
            nonisolated(nonsending) (Borrowed) async throws -> Owned
        >
        let runtime = ABIRuntime.shared
        func make<Value>(_ value: Value) async throws -> NativeSwiftValue {
            let factory = try await runtime.resolve(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.makeRuntimeProducer<A>(A) -> () -> A",
                        as: ((Value) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
                        genericArguments: [.type(Value.self)]
                    )
                )
            )
            return try unsafe factory.unsafeInvoke(value).unsafeInvoke()
        }
        var object: NSObject? = NSObject()
        weak var observed = object
        let input: NativeSwiftValue
        if resilient {
            input = try await make(RuntimeResilientWeakRecord(object, 42))
        } else {
            input = try await make(RuntimeWeakRecord(object, 42))
        }
        let abi = try NativeType.opaque(named: input.type.name)
        let number = try await input.type.resolve(
            .swift(
                .getter(
                    "number",
                    as: (() -> Int64).self,
                    receiverABI: abi
                )
            )
        )
        let hasObject = try await input.type.resolve(
            .swift(
                .method(
                    "hasObject()",
                    as: (() -> Bool).self,
                    receiverABI: abi
                )
            )
        )
        let transform = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.transformRuntimeTuple<A>((Swift.Int8, A, Swift.Int64), ((Swift.Int8, A, Swift.Int64)) throws -> (Swift.Int8, A, Swift.Int64)) throws -> (Swift.Int8, A, Swift.Int64)",
                    as: ((Owned, Body) throws -> Owned).self,
                    genericArguments: [.type(input.type)]
                )
            )
        )
        let copy: @Sendable (Borrowed) throws -> Owned = { value in
            #expect(try unsafe number.unsafeInvoke(on: value.1) == 42)
            return (value.0 + 1, try value.1.copy(), value.2 + 1)
        }
        let output = try unsafe transform.unsafeInvoke((11, input, 90), Body { try copy($0) })
        #expect(output.0 == 12 && output.2 == 91 && !input.isConsumed)
        #expect(try unsafe hasObject.unsafeInvoke(on: output.1))
        let reject: @Sendable (Borrowed) throws -> Owned = { _ in
            throw RuntimeTicketFailure.rejected
        }
        do {
            _ = try unsafe transform.unsafeInvoke((11, input, 90), Body { try reject($0) })
            Issue.record("Missing tuple callback error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is RuntimeTicketFailure })
        }
        #expect(try unsafe hasObject.unsafeInvoke(on: input))

        let pack = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.pairedPackGeneric<each A, B where A.shape == B.shape>(repeat (A, B)) -> (repeat (B, A))",
                    as: (((Void, NativeSwiftValue)) -> (NativeSwiftValue, Void)).self,
                    genericArguments: [.pack([.type(Void.self)]), .pack([.type(input.type)])]
                )
            )
        )
        let packed = try unsafe pack.unsafeInvoke(((), input))
        #expect(try unsafe number.unsafeInvoke(on: packed.0) == 42)
        #expect(try unsafe hasObject.unsafeInvoke(on: packed.0))
        typealias PackBody = NativeSwiftClosure<
            (NativeSwiftBorrowedValue, Void) throws -> (NativeSwiftValue, Void)
        >
        let transformPack = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.transformRuntimePack<each A>((repeat A) throws -> (repeat A), repeat A) throws -> (repeat A)",
                    as: ((PackBody, NativeSwiftValue, Void) throws -> (NativeSwiftValue, Void))
                        .self,
                    genericArguments: [.pack([.type(input.type), .type(Void.self)])]
                )
            )
        )
        let packCopy:
            @Sendable (NativeSwiftBorrowedValue, Void) throws -> (NativeSwiftValue, Void) = {
                value,
                _ in
                (try value.copy(), ())
            }
        let callbackPacked = try unsafe transformPack.unsafeInvoke(PackBody(packCopy), input, ())
        #expect(try unsafe number.unsafeInvoke(on: callbackPacked.0) == 42)
        #expect(try unsafe hasObject.unsafeInvoke(on: callbackPacked.0))

        let asynchronous = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.transformRuntimeTupleAsync<A>((Swift.Int8, A, Swift.Int64), nonisolated(nonsending) ((Swift.Int8, A, Swift.Int64)) async throws -> (Swift.Int8, A, Swift.Int64)) async throws -> (Swift.Int8, A, Swift.Int64)",
                    as: (nonisolated(nonsending) (Owned, AsyncBody) async throws -> Owned).self,
                    genericArguments: [.type(input.type)]
                )
            )
        )
        let gate = AsyncGate()
        let suspendedCopy: nonisolated(nonsending) @Sendable (Borrowed) async throws -> Owned = {
            value in
            #expect(try unsafe hasObject.unsafeInvoke(on: value.1))
            await gate.wait()
            #expect(try unsafe number.unsafeInvoke(on: value.1) == 42)
            #expect(try unsafe !hasObject.unsafeInvoke(on: value.1))
            return (value.0 + 2, try value.1.copy(), value.2 + 2)
        }
        var resumedValue: Owned?
        let task = Task { @MainActor in
            resumedValue = try unsafe await asynchronous.unsafeInvoke(
                (11, input, 90),
                AsyncBody { try await suspendedCopy($0) }
            )
        }
        await gate.waitUntilSuspended()
        #expect(observed != nil && !input.isConsumed)
        object = nil
        #expect(observed == nil)
        await gate.open()
        try await task.value
        let resumed = try #require(resumedValue)
        #expect(resumed.0 == 13 && resumed.2 == 92)
        #expect(try unsafe number.unsafeInvoke(on: resumed.1) == 42)
        for value in [input, output.1, resumed.1, packed.0, callbackPacked.0] {
            #expect(try unsafe !hasObject.unsafeInvoke(on: value))
        }
    }

    @MainActor @Test(arguments: [false, true])
    func wholeRuntimeTuplesPreserveWeakAndMetatypeStorage(_ formalTuple: Bool) async throws {
        typealias Element = (Int64.Type, RuntimeWeakRecord)
        typealias Whole = (Int8, Element, Int64)
        typealias Body = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftBorrowedValue) async throws -> NativeSwiftValue
        >
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((Whole) -> NativeSwiftValue).self,
                    genericArguments: [.type(Whole.self)]
                )
            )
        )
        let name =
            formalTuple
            ? "ManagedSwiftFixtures.transformRuntimeTupleAsync<A>((Swift.Int8, A, Swift.Int64), nonisolated(nonsending) ((Swift.Int8, A, Swift.Int64)) async throws -> (Swift.Int8, A, Swift.Int64)) async throws -> (Swift.Int8, A, Swift.Int64)"
            : "ManagedSwiftFixtures.callRuntimeThrowingAsyncCopy<A>(nonisolated(nonsending) (A) async throws -> A, A) async throws -> A"
        var object: NSObject? = NSObject()
        weak var observed = object
        let control: Whole = (11, (Int64.self, RuntimeWeakRecord(object, 42)), 90)
        let input = try unsafe make.unsafeInvoke(control)
        let gate = AsyncGate()
        let body = try Body { value in
            await gate.wait()
            let copy = try value.copy()
            try copy.withCopy {
                let tuple = try #require($0 as? Whole)
                #expect(
                    tuple.1.0 == Int64.self && tuple.1.1.object == nil && tuple.1.1.number == 42
                )
            }
            return copy
        }
        var result: NativeSwiftValue?
        let task: Task<Void, any Error>
        if formalTuple {
            let call = try await runtime.resolve(
                .swift(
                    .function(
                        name,
                        as: (nonisolated(nonsending) (NativeSwiftValue, Body) async throws ->
                            NativeSwiftValue).self,
                        genericArguments: [.type(Element.self)]
                    )
                )
            )
            task = Task { @MainActor in result = try unsafe await call.unsafeInvoke(input, body) }
        } else {
            let call = try await runtime.resolve(
                .swift(
                    .function(
                        name,
                        as: (nonisolated(nonsending) (Body, NativeSwiftValue) async throws ->
                            NativeSwiftValue).self,
                        genericArguments: [.type(Whole.self)]
                    )
                )
            )
            task = Task { @MainActor in result = try unsafe await call.unsafeInvoke(body, input) }
        }
        await gate.waitUntilSuspended()
        object = nil
        #expect(observed == nil && !input.isConsumed)
        await gate.open()
        try await task.value
        let output = try #require(result).take(as: Whole.self)
        let original = try input.take(as: Whole.self)
        #expect(output.0 == control.0 && output.2 == control.2)
        #expect(output.1.0 == Int64.self && output.1.1.object == nil)
        #expect(original.1.0 == Int64.self && original.1.1.object == nil)
        #expect(
            output.1.1.number == control.1.1.number && original.1.1.number == control.1.1.number
        )
    }

    @Test func explicitRuntimeValueABIsComposeAcrossCallbacksAndMembers() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolve(.swift(.type("ManagedSwiftFixtures.RuntimeFixedPair")))
        let abi = try NativeType.structure(named: type.name, fields: [.int64, .int64])
        let abis = [type: abi]
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeFixedPair(Swift.Int64, Swift.Int64) -> ManagedSwiftFixtures.RuntimeFixedPair",
                    as: ((Int64, Int64) -> NativeSwiftValue).self,
                    valueABIs: abis
                )
            )
        )
        let value = try unsafe make.unsafeInvoke(35, 7)
        #expect(abis[value.type] == abi)
        let sum = try await type.resolve(
            .swift(
                .method(
                    "sum()",
                    as: (() -> Int64).self,
                    receiverABI: abi
                )
            )
        )
        typealias Body = NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Int64>
        let body = try Body { value in
            do { return try unsafe sum.unsafeInvoke(on: value) } catch {
                Issue.record(error); return -1
            }
        }
        let inspect = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.inspectRuntimeFixedPair(ManagedSwiftFixtures.RuntimeFixedPair, (ManagedSwiftFixtures.RuntimeFixedPair) -> Swift.Int64) -> Swift.Int64",
                    as: ((NativeSwiftValue, Body) -> Int64).self,
                    valueABIs: abis
                )
            )
        )
        #expect(try unsafe inspect.unsafeInvoke(value, body) == 42)
        let member = try await type.resolve(
            .swift(
                .method(
                    "inspect(_:)",
                    as: ((Body) -> Int64).self,
                    valueABIs: abis,
                    receiverABI: abi
                )
            )
        )
        #expect(try unsafe member.unsafeInvoke(on: value, body) == 42)
        let storeType = try await runtime.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeFixedPairStore"))
        )
        let construct = try await storeType.resolve(
            .swift(
                .initializer(
                    "init(_:)",
                    as: ((NativeSwiftValue) -> RuntimeFixedPairStore).self,
                    valueABIs: abis
                )
            )
        )
        let store = try unsafe construct.unsafeInvoke(value)
        #expect(value.isConsumed)
        let getter = try await storeType.resolve(
            .swift(
                .getter(
                    "value",
                    as: (() -> NativeSwiftValue).self,
                    valueABIs: abis
                )
            )
        )
        let first = try unsafe getter.unsafeInvoke(on: store)
        #expect(try unsafe sum.unsafeInvoke(on: first) == 42)
        let echo = try await storeType.resolve(
            .swift(
                .staticMethod(
                    "echo(_:)",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    valueABIs: abis
                )
            )
        )
        let echoed = try unsafe echo.unsafeInvoke(first)
        #expect(try unsafe sum.unsafeInvoke(on: echoed) == 42 && !first.isConsumed)
        let setter = try await storeType.resolve(
            .swift(
                .setter(
                    "value",
                    as: ((NativeSwiftValue) -> Void).self,
                    valueABIs: abis
                )
            )
        )
        let replacement = try unsafe make.unsafeInvoke(40, 10)
        try unsafe setter.unsafeInvoke(on: store, replacement)
        #expect(replacement.isConsumed)
        #expect(try unsafe sum.unsafeInvoke(on: getter.unsafeInvoke(on: store)) == 50)
        do {
            _ = try await runtime.resolve(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.makeRuntimeFixedPair(Swift.Int64, Swift.Int64) -> ManagedSwiftFixtures.RuntimeFixedPair",
                        as: ((Int64, Int64) -> NativeSwiftValue).self,
                        valueABIs: [type: .int8]
                    )
                )
            )
            Issue.record("ABI components must cover the native payload")
        } catch ABIResolutionError.unsupportedDeclaration {}
    }

    @Test func ownershipWrappersPreserveNativeGenericClosureData() async throws {
        typealias Value = NativeSwiftClosure<() -> Int64>
        typealias Consume = NativeSwiftClosure<(NativeSwiftConsuming<Value>) -> Int64>
        typealias Borrow = NativeSwiftClosure<(NativeSwiftBorrowing<Value>) throws -> Int64>
        typealias AsyncBorrow = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftBorrowing<Value>) async throws -> Int64
        >
        let runtime = ABIRuntime.shared
        let consume = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitNonthrowingConsumingRuntimeValue<A where A: ~Swift.Copyable>(__owned A, (__owned A) -> Swift.Int64) -> Swift.Int64",
                    as: ((NativeSwiftConsuming<Value>, Consume) -> Int64).self,
                    genericArguments: [.type(Value.self)]
                )
            )
        )
        let borrow = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeValue<A where A: ~Swift.Copyable>(A, (A) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((Value, Borrow) throws -> Int64).self,
                    genericArguments: [.type(Value.self)]
                )
            )
        )
        let borrowAsync = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeValueAsync<A where A: ~Swift.Copyable>(A, nonisolated(nonsending) (A) async throws -> Swift.Int64) async throws -> Swift.Int64",
                    as: (nonisolated(nonsending) (Value, AsyncBorrow) async throws -> Int64).self,
                    genericArguments: [.type(Value.self)]
                )
            )
        )
        let deaths = RuntimeValueDeaths()
        do {
            let life = RuntimeValueLife(deaths)
            let value = try Value { withExtendedLifetime(life) { Int64(42) } }
            let owned = try Consume { incoming in
                do { return try unsafe incoming.value.copy().unsafeInvoke() } catch {
                    Issue.record(error); return -1
                }
            }
            let borrowed = try Borrow { incoming in try unsafe incoming.value.copy().unsafeInvoke()
            }
            for _ in 0..<20 {
                #expect(try unsafe consume.unsafeInvoke(NativeSwiftConsuming(value), owned) == 42)
                #expect(try unsafe borrow.unsafeInvoke(value, borrowed) == 42)
            }
            #expect(try unsafe value.unsafeInvoke() == 42)
            #expect(deaths.count.withLock { $0 } == 0)
        }
        #expect(deaths.count.withLock { $0 } == 1)
        let value = try Value { Int64(42) }
        let operation:
            nonisolated(nonsending) @Sendable (NativeSwiftBorrowing<Value>) async throws -> Int64 =
                { incoming in
                    await Task.yield()
                    return try unsafe incoming.value.copy().unsafeInvoke()
                }
        #expect(try unsafe await borrowAsync.unsafeInvoke(value, AsyncBorrow(operation)) == 42)
    }

    @Test func closureCompatibilityPreservesEveryNativeArgumentPosition() async throws {
        typealias Reader = NativeSwiftClosure<(NativeSwiftValue, NativeSwiftValue) -> Int64>
        typealias AsyncReader = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftValue, NativeSwiftValue) async -> Int64
        >
        let runtime = ABIRuntime.shared
        let makeValue = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let value = try unsafe makeValue.unsafeInvoke(7)
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeMixedRuntimeReader<A, B>(A.Type, B.Type) -> (A, B) -> Swift.Int64",
                    as: ((Int64.Type, NativeSwiftValue.Type) -> Reader).self,
                    genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)]
                )
            )
        )
        let reader = try unsafe factory.unsafeInvoke(Int64.self, NativeSwiftValue.self)
        let correct = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callMixedRuntimeReader<A, B>((A, B) -> Swift.Int64, A, B) -> Swift.Int64",
                    as: ((Reader, Int64, NativeSwiftValue) -> Int64).self,
                    genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)]
                )
            )
        )
        #expect(try unsafe correct.unsafeInvoke(reader, 35, value) == 42)
        let swapped = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callMixedRuntimeReader<A, B>((A, B) -> Swift.Int64, A, B) -> Swift.Int64",
                    as: ((Reader, NativeSwiftValue, Int64) -> Int64).self,
                    genericArguments: [.type(NativeSwiftValue.self), .type(Int64.self)]
                )
            )
        )
        #expect(throws: ABIResolutionError.self) {
            try unsafe swapped.unsafeInvoke(reader, value, 35) as Int64
        }

        let packFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimePackReader<each A>(repeat A) -> (repeat A) -> Swift.Int64",
                    as: ((Int64, NativeSwiftValue) -> Reader).self,
                    genericArguments: [.pack([.type(Int64.self), .type(NativeSwiftValue.self)])]
                )
            )
        )
        let packReader = try unsafe packFactory.unsafeInvoke(35, value)
        let packCall = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.inspectRuntimePackReader<each A>((repeat A) -> Swift.Int64, repeat A) -> Swift.Int64",
                    as: ((Reader, NativeSwiftValue, Int64) -> Int64).self,
                    genericArguments: [.pack([.type(NativeSwiftValue.self), .type(Int64.self)])]
                )
            )
        )
        #expect(throws: ABIResolutionError.self) {
            try unsafe packCall.unsafeInvoke(packReader, value, 35) as Int64
        }
        #expect(try unsafe correct.unsafeInvoke(packReader, 35, value) == 42)

        let asyncFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeMixedRuntimeAsyncReader<A, B>(A.Type, B.Type) -> nonisolated(nonsending) (A, B) async -> Swift.Int64",
                    as: ((Int64.Type, NativeSwiftValue.Type) -> AsyncReader).self,
                    genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)]
                )
            )
        )
        let asyncReader = try unsafe asyncFactory.unsafeInvoke(Int64.self, NativeSwiftValue.self)
        let asyncCorrect = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callMixedRuntimeAsyncReader<A, B>(nonisolated(nonsending) (A, B) async -> Swift.Int64, A, B) async -> Swift.Int64",
                    as: (nonisolated(nonsending) (AsyncReader, Int64, NativeSwiftValue) async ->
                        Int64)
                        .self,
                    genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)]
                )
            )
        )
        #expect(try unsafe await asyncCorrect.unsafeInvoke(asyncReader, 35, value) == 42)
        let asyncSwapped = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callMixedRuntimeAsyncReader<A, B>(nonisolated(nonsending) (A, B) async -> Swift.Int64, A, B) async -> Swift.Int64",
                    as: (nonisolated(nonsending) (AsyncReader, NativeSwiftValue, Int64) async ->
                        Int64)
                        .self,
                    genericArguments: [.type(NativeSwiftValue.self), .type(Int64.self)]
                )
            )
        )
        await #expect(throws: ABIResolutionError.self) {
            try unsafe await asyncSwapped.unsafeInvoke(asyncReader, value, 35) as Int64
        }
    }

    @Test func closureResultsDistinguishRawGenericHandlesFromNativeFunctions() async throws {
        typealias Inner = NativeSwiftClosure<(Int64) -> Int64>
        typealias Producer = NativeSwiftClosure<() -> Inner>
        let runtime = ABIRuntime.shared
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProducer<A>(A) -> () -> A",
                    as: ((Inner) -> Producer).self,
                    genericArguments: [.type(Inner.self)]
                )
            )
        )
        let producer = try unsafe factory.unsafeInvoke(Inner { $0 + 7 })
        #expect(try unsafe producer.unsafeInvoke().unsafeInvoke(35) == 42)
        let call = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callNonthrowingNestedRuntimeProducer<A>(() -> (A) -> A, A) -> A",
                    as: ((Producer, Int64) -> Int64).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        #expect(throws: ABIResolutionError.self) {
            try unsafe call.unsafeInvoke(producer, 35) as Int64
        }
    }

    @Test func consumingNestedInputsRemainOwnedAfterNonthrowingCallbacks() async throws {
        let runtime = ABIRuntime.shared
        typealias Copy = NativeSwiftClosure<(String) -> String>
        typealias Body = NativeSwiftClosure<(NativeSwiftConsuming<Copy>) -> Void>
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitOwnedNested<A>(A, () -> (), (__owned (A) -> A) -> ()) -> ()",
                    as: ((String, NativeSwiftClosure<() -> Void>, Body) -> Void).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let saved = NestedRuntimePackCopies()
        let counts = ArgumentCounts()
        let body = try Body { incoming in saved.text = incoming.value }
        try unsafe visit.unsafeInvoke(
            "captured owned value",
            NativeSwiftClosure { counts.destroyed() },
            body
        )
        #expect(counts.destructions == 0)
        #expect(try unsafe saved.text!.unsafeInvoke("ignored") == "captured owned value")
        do {
            let copy = try saved.text!.copy()
            saved.text = nil
            #expect(try unsafe copy.unsafeInvoke("ignored") == "captured owned value")
            #expect(counts.destructions == 0)
        }
        #expect(counts.destructions == 1)
        typealias RuntimeCopy = NativeSwiftClosure<(NativeSwiftValue) -> NativeSwiftValue>
        typealias RuntimeBody = NativeSwiftClosure<(NativeSwiftConsuming<RuntimeCopy>) -> Void>
        let runtimeVisit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitOwnedNested<A>(A, () -> (), (__owned (A) -> A) -> ()) -> ()",
                    as: ((String, NativeSwiftClosure<() -> Void>, RuntimeBody) -> Void).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let captured = RuntimeCallbackValues()
        try unsafe runtimeVisit.unsafeInvoke(
            "runtime owned value",
            NativeSwiftClosure { counts.destroyed() },
            RuntimeBody { captured.nested = $0.value }
        )
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((String) -> NativeSwiftValue).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let input = try unsafe make.unsafeInvoke("argument")
        #expect(
            try unsafe captured.nested!.unsafeInvoke(input).take(as: String.self)
                == "runtime owned value"
        )
        captured.nested = nil
        #expect(counts.destructions == 2)
    }

    @Test func consumingNestedInputsReleaseTheirCaptureWhenTheHostThrows() async throws {
        typealias Copy = NativeSwiftClosure<(String) -> String>
        typealias Body = NativeSwiftClosure<(NativeSwiftConsuming<Copy>) throws -> Void>
        let visit = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitOwnedNestedThrowing<A>(A, () -> (), (__owned (A) -> A) throws -> ()) throws -> ()",
                    as: ((String, NativeSwiftClosure<() -> Void>, Body) throws -> Void).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let counts = ArgumentCounts()
        do {
            try unsafe visit.unsafeInvoke(
                "released",
                NativeSwiftClosure { counts.destroyed() },
                Body { _ in throw RuntimeTicketFailure.rejected }
            )
            Issue.record("The native caller must receive the callback failure")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is RuntimeTicketFailure })
        }
        #expect(counts.destructions == 1)
    }

    @Test func consumingNestedAsyncInputsSurviveCallbackSuspensionAndReturn() async throws {
        typealias Copy = NativeSwiftClosure<nonisolated(nonsending) (String) async -> String>
        typealias Body = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftConsuming<Copy>) async -> Void
        >
        let visit = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitOwnedNestedAsync<A>(A, () -> (), nonisolated(nonsending) (__owned nonisolated(nonsending) (A) async -> A) async -> ()) async -> ()",
                    as: (nonisolated(nonsending) (String, NativeSwiftClosure<() -> Void>, Body)
                        async ->
                        Void).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let counts = ArgumentCounts()
        let saved = RuntimeCallbackValues()
        let operation:
            nonisolated(nonsending) @Sendable (NativeSwiftConsuming<Copy>) async -> Void = {
                incoming in
                await Task.yield()
                saved.asyncText = incoming.value
            }
        try unsafe await visit.unsafeInvoke(
            "async owned",
            NativeSwiftClosure { counts.destroyed() },
            Body(operation)
        )
        #expect(counts.destructions == 0)
        #expect(try unsafe await saved.asyncText!.unsafeInvoke("ignored") == "async owned")
        saved.asyncText = nil
        #expect(counts.destructions == 1)
    }

    @Test func nativeConsumingNestedClosuresReabstractOwnershipInBothDirections() async throws {
        let runtime = ABIRuntime.shared
        typealias Copy = NativeSwiftClosure<(Int64) -> Int64>
        typealias Caller = NativeSwiftClosure<(NativeSwiftConsuming<Copy>, Int64) -> Int64>
        let concreteFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeConcreteOwnedNestedCaller()",
                    as: (() -> Caller).self
                )
            )
        )
        let genericFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOwnedNestedRuntimeCaller<A>(A.Type) -> (__owned (A) -> A, A) -> A",
                    as: ((Int64.Type) -> Caller).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let genericCall = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callOwnedNestedRuntimeCaller<A>((__owned (A) -> A, A) -> A, A, () -> ()) -> A",
                    as: ((Caller, Int64, NativeSwiftClosure<() -> Void>) -> Int64).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let concreteCall = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callConcreteOwnedNestedCaller(_:_:_:)",
                    as: ((Caller, Int64, NativeSwiftClosure<() -> Void>) -> Int64).self
                )
            )
        )
        let counts = ArgumentCounts()
        let destroyed = try NativeSwiftClosure { counts.destroyed() }
        #expect(
            try unsafe genericCall.unsafeInvoke(concreteFactory.unsafeInvoke(), 42, destroyed) == 42
        )
        #expect(counts.destructions == 1)
        #expect(
            try unsafe concreteCall.unsafeInvoke(
                genericFactory.unsafeInvoke(Int64.self),
                43,
                destroyed
            ) == 43
        )
        #expect(counts.destructions == 2)
        typealias AsyncCopy = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
        typealias AsyncCaller = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftConsuming<AsyncCopy>, Int64) async -> Int64
        >
        let asyncFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeConcreteOwnedNestedAsyncCaller()",
                    as: (() -> AsyncCaller).self
                )
            )
        )
        let asyncCall = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callOwnedNestedRuntimeAsyncCaller<A>(nonisolated(nonsending) (__owned nonisolated(nonsending) (A) async -> A, A) async -> A, A, () -> ()) async -> A",
                    as: (nonisolated(nonsending) (
                        AsyncCaller, Int64, NativeSwiftClosure<() -> Void>
                    )
                        async
                        -> Int64).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        #expect(
            try unsafe await asyncCall.unsafeInvoke(asyncFactory.unsafeInvoke(), 44, destroyed)
                == 44
        )
        #expect(counts.destructions == 3)
    }

    @Test func runtimeInoutCallbacksMutateNoncopyableNativeStorageAndExpire() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let read = try await value.type.resolve(
            .swift(
                .method(
                    "read()",
                    as: (() -> Int64).self,
                    receiverABI: .opaque(named: value.type.name)
                )
            )
        )
        let add = try await value.type.resolve(
            .swift(
                .method(
                    "add(_:)",
                    as: ((Int64) -> Void).self,
                    receiverABI: .opaque(named: value.type.name),
                    receiver: .mutating
                )
            )
        )
        typealias Body = NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Void>
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeInout<A where A: ~Swift.Copyable>(inout A, (inout A) throws -> ()) throws -> ()",
                    as: ((NativeSwiftInout<NativeSwiftValue>, Body) throws -> Void).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
        let captured = RuntimeCallbackValues()
        let body = try Body { view in
            captured.borrowed = view
            try unsafe add.unsafeInvoke(on: view, Int64(8))
            #expect(try unsafe read.unsafeInvoke(on: view) == 50)
            throw RuntimeTicketFailure.rejected
        }
        do {
            try unsafe visit.unsafeInvoke(NativeSwiftInout(value), body)
            Issue.record("The inout callback must preserve its failure")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is RuntimeTicketFailure })
        }
        #expect(try unsafe read.unsafeInvoke(on: value) == 50)
        #expect(!value.isConsumed && counts.destructions == 0)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe add.unsafeInvoke(on: captured.borrowed!, Int64(1))
        }
        try value.withBorrowedValue { readonly in
            #expect(throws: NativeSwiftValueError.valueInUse) {
                try unsafe add.unsafeInvoke(on: readonly, Int64(1))
            }
        }
    }

    @Test func runtimeInoutCallbacksEnforceAccessDuringNestedNativeCalls() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let value = try unsafe make.unsafeInvoke(42)
        typealias Body = NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Void>
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeInout<A where A: ~Swift.Copyable>(inout A, (inout A) throws -> ()) throws -> ()",
                    as: ((NativeSwiftInout<NativeSwiftValue>, Body) throws -> Void).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let hold = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.holdRuntimeInout<A where A: ~Swift.Copyable>(inout A, () -> Swift.Bool) -> Swift.Bool",
                    as: ((
                        NativeSwiftInout<NativeSwiftBorrowedValue>, NativeSwiftClosure<() -> Bool>
                    )
                        -> Bool).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let replace = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.replaceRuntimeValue<A where A: ~Swift.Copyable>(inout A, __owned A) -> ()",
                    as: ((
                        NativeSwiftInout<NativeSwiftBorrowedValue>,
                        NativeSwiftConsuming<NativeSwiftValue>
                    ) -> Void).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let replacement = try unsafe make.unsafeInvoke(7)
        let captured = RuntimeCallbackValues()
        captured.owned = replacement
        captured.predicate = try NativeSwiftClosure<() -> Bool> {
            do { _ = try captured.borrowed!.copy(); return false } catch NativeSwiftValueError
                .valueInUse
            { return true } catch { return false }
        }
        defer { captured.predicate = nil }
        let body = try Body { view in
            captured.borrowed = view
            #expect(try unsafe hold.unsafeInvoke(NativeSwiftInout(view), captured.predicate!))
            try unsafe replace.unsafeInvoke(
                NativeSwiftInout(view),
                NativeSwiftConsuming(captured.owned!)
            )
            #expect(try view.copy().take(as: Int64.self) == 7)
        }
        try unsafe visit.unsafeInvoke(NativeSwiftInout(value), body)
        #expect(try value.take(as: Int64.self) == 7 && replacement.isConsumed)
    }

    @Test func typedInoutCallbacksWriteBackOnErrorAndReturnedClosuresSwapOwners() async throws {
        let runtime = ABIRuntime.shared
        typealias TextBody = NativeSwiftClosure<(NativeSwiftInout<String>) throws -> Void>
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeInout<A where A: ~Swift.Copyable>(inout A, (inout A) throws -> ()) throws -> ()",
                    as: ((NativeSwiftInout<String>, TextBody) throws -> Void).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let buffer = NativeSwiftInout("before")
        let body = try TextBody { value in
            value.value += " after"; throw RuntimeTicketFailure.rejected
        }
        do {
            try unsafe visit.unsafeInvoke(buffer, body); Issue.record("Missing callback error")
        } catch is NativeSwiftError {}
        #expect(buffer.value == "before after")
        typealias Swap = NativeSwiftClosure<
            (NativeSwiftInout<NativeSwiftValue>, NativeSwiftInout<NativeSwiftValue>) -> Void
        >
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeSwap<A where A: ~Swift.Copyable>(A.Type) -> (inout A, inout A) -> ()",
                    as: ((Int64.Type) -> Swap).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let swap = try unsafe factory.unsafeInvoke(Int64.self)
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let first = try unsafe make.unsafeInvoke(42), second = try unsafe make.unsafeInvoke(7)
        try unsafe swap.unsafeInvoke(NativeSwiftInout(first), NativeSwiftInout(second))
        #expect(try first.take(as: Int64.self) == 7 && second.take(as: Int64.self) == 42)
    }

    @Test func typedAsyncInoutCallbacksWriteBackAndNativeBorrowingCannotGrantMutation() async throws
    {
        let runtime = ABIRuntime.shared
        typealias TextBody = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftInout<String>) async throws -> Void
        >
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeInoutAsync<A where A: ~Swift.Copyable>(inout A, nonisolated(nonsending) (inout A) async throws -> ()) async throws -> ()",
                    as: (nonisolated(nonsending) (NativeSwiftInout<String>, TextBody) async throws
                        ->
                        Void)
                        .self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let buffer = NativeSwiftInout("before")
        let operation:
            nonisolated(nonsending) @Sendable (NativeSwiftInout<String>) async throws -> Void = {
                value in
                await Task.yield()
                value.value += " after"
                throw RuntimeTicketFailure.rejected
            }
        do {
            try unsafe await visit.unsafeInvoke(buffer, TextBody(operation));
            Issue.record("Missing async error")
        } catch is NativeSwiftError {}
        #expect(buffer.value == "before after")
        typealias SyncBody = NativeSwiftClosure<(NativeSwiftInout<String>) -> Void>
        let concrete = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitStringInout(_:_:)",
                    as: ((NativeSwiftInout<String>, SyncBody) -> Void).self
                )
            )
        )
        try unsafe concrete.unsafeInvoke(buffer, SyncBody { $0.value += "!" })
        #expect(buffer.value == "before after!")
        typealias Reader = NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Int64>
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeInoutReader<A where A: ~Swift.Copyable>(A.Type) -> (inout A) -> Swift.Int64",
                    as: ((Int64.Type) -> Reader).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let reader = try unsafe factory.unsafeInvoke(Int64.self)
        let inspect = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.inspectRuntimeReader<A where A: ~Swift.Copyable>(A, (A) -> Swift.Int64) -> Swift.Int64",
                    as: ((Int64, Reader) -> Int64).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        #expect(throws: ABIResolutionError.self) {
            try unsafe inspect.unsafeInvoke(Int64(42), reader)
        }
    }

    @Test func runtimeAsyncInoutCallbacksPreserveMutationAfterSuspensionAndFailure() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken {})
        let add = try await value.type.resolve(
            .swift(
                .method(
                    "addThenThrow(_:)",
                    as: (nonisolated(nonsending) (Int64) async throws -> Void).self,
                    receiverABI: .opaque(named: value.type.name),
                    receiver: .mutating
                )
            )
        )
        let read = try await value.type.resolve(
            .swift(
                .method(
                    "read()",
                    as: (() -> Int64).self,
                    receiverABI: .opaque(named: value.type.name)
                )
            )
        )
        typealias Body = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftBorrowedValue) async throws -> Void
        >
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeInoutAsync<A where A: ~Swift.Copyable>(inout A, nonisolated(nonsending) (inout A) async throws -> ()) async throws -> ()",
                    as: (nonisolated(nonsending) (NativeSwiftInout<NativeSwiftValue>, Body)
                        async throws
                        ->
                        Void).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
        let captured = RuntimeCallbackValues()
        let operation:
            nonisolated(nonsending) @Sendable (NativeSwiftBorrowedValue) async throws -> Void = {
                view in
                captured.borrowed = view
                await Task.yield()
                try unsafe await add.unsafeInvoke(on: view, Int64(8))
            }
        do {
            try unsafe await visit.unsafeInvoke(NativeSwiftInout(value), Body(operation));
            Issue.record("Missing native error")
        } catch is NativeSwiftError {}
        #expect(try unsafe read.unsafeInvoke(on: value) == 50)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try captured.borrowed!.copy() }
    }

    @Test func consumingCallbackInputsTransferNoncopyableOwnership() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        typealias Body = NativeSwiftClosure<
            (NativeSwiftConsuming<NativeSwiftValue>) throws -> Int64
        >
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitConsumingRuntimeValue<A where A: ~Swift.Copyable>(__owned A, (__owned A) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>, Body) throws -> Int64).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
        let captured = RuntimeCallbackValues()
        let body = try Body { incoming in
            captured.owned = incoming.value; return 42
        }
        #expect(try unsafe visit.unsafeInvoke(NativeSwiftConsuming(value), body) == 42)
        #expect(value.isConsumed && counts.destructions == 0)
        let read = try await value.type.resolve(
            .swift(
                .method(
                    "read()",
                    as: (() -> Int64).self,
                    receiverABI: .opaque(named: value.type.name)
                )
            )
        )
        #expect(try unsafe read.unsafeInvoke(on: captured.owned!) == 42)
        captured.owned = nil
        #expect(counts.destructions == 1)
        let failing = try Body { _ in throw RuntimeTicketFailure.rejected }
        let rejected = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        do {
            _ = try unsafe visit.unsafeInvoke(NativeSwiftConsuming(rejected), failing)
            Issue.record("The callback failure must reach its native caller")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is RuntimeTicketFailure })
        }
        #expect(rejected.isConsumed && counts.destructions == 2)
    }

    @Test func nonthrowingConsumingInputsAndExplicitAsyncBorrowsShareNativeOwnership() async throws
    {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        typealias Consumer = NativeSwiftClosure<(NativeSwiftConsuming<NativeSwiftValue>) -> Int64>
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitNonthrowingConsumingRuntimeValue<A where A: ~Swift.Copyable>(__owned A, (__owned A) -> Swift.Int64) -> Swift.Int64",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>, Consumer) -> Int64).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
        #expect(
            try unsafe visit.unsafeInvoke(NativeSwiftConsuming(value), Consumer { _ in 42 }) == 42
        )
        #expect(value.isConsumed && counts.destructions == 1)
        let borrowed = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        typealias Borrower = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftBorrowing<NativeSwiftBorrowedValue>) async throws ->
                Int64
        >
        let inspect = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeValueAsync<A where A: ~Swift.Copyable>(A, nonisolated(nonsending) (A) async throws -> Swift.Int64) async throws -> Swift.Int64",
                    as: (nonisolated(nonsending) (NativeSwiftValue, Borrower) async throws -> Int64)
                        .self,
                    genericArguments: [.type(borrowed.type)]
                )
            )
        )
        let read = try await borrowed.type.resolve(
            .swift(
                .method(
                    "readAsync()",
                    as: (nonisolated(nonsending) () async -> Int64).self,
                    receiverABI: .opaque(named: borrowed.type.name)
                )
            )
        )
        let captured = RuntimeCallbackValues()
        let operation:
            nonisolated(nonsending) @Sendable (NativeSwiftBorrowing<NativeSwiftBorrowedValue>)
                async throws -> Int64 = { incoming in
                    captured.borrowed = incoming.value
                    await Task.yield()
                    return try unsafe await read.unsafeInvoke(on: incoming.value)
                }
        #expect(try unsafe await inspect.unsafeInvoke(borrowed, Borrower(operation)) == 42)
        #expect(!borrowed.isConsumed && counts.destructions == 1)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try captured.borrowed!.copy() }
    }

    @Test func consumingConcreteAndReturnedCallbacksPreserveOwnership() async throws {
        let runtime = ABIRuntime.shared
        typealias TextBody = NativeSwiftClosure<(NativeSwiftConsuming<String>) -> Int64>
        let apply = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitConsumingString(_:_:)",
                    as: ((NativeSwiftConsuming<String>, TextBody) -> Int64).self
                )
            )
        )
        let text = String(repeating: "ab", count: 21)
        let body = try TextBody { Int64($0.value.count) }
        #expect(try unsafe apply.unsafeInvoke(NativeSwiftConsuming(text), body) == 42)
        #expect(try unsafe body.unsafeInvoke(NativeSwiftConsuming(text)) == 42)
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        typealias Consumer = NativeSwiftClosure<(NativeSwiftConsuming<NativeSwiftValue>) -> Int64>
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeConsumer<A where A: ~Swift.Copyable>(A.Type) -> (__owned A) -> Swift.Int64",
                    as: ((RuntimeTicket.Type) -> Consumer).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
        let consumer = try unsafe factory.unsafeInvoke(RuntimeTicket.self)
        #expect(
            try unsafe consumer.unsafeInvoke(NativeSwiftConsuming(value))
                == MemoryLayout<RuntimeTicket>.size
        )
        #expect(value.isConsumed && counts.destructions == 1)
    }

    @Test func consumingAsyncCallbackInputsStayOwnedAcrossSuspension() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        typealias Body = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftConsuming<NativeSwiftValue>) async throws -> Int64
        >
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitConsumingRuntimeValueAsync<A where A: ~Swift.Copyable>(__owned A, nonisolated(nonsending) (__owned A) async throws -> Swift.Int64) async throws -> Swift.Int64",
                    as: (nonisolated(nonsending) (NativeSwiftConsuming<NativeSwiftValue>, Body)
                        async throws
                        -> Int64).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
        let captured = RuntimeCallbackValues()
        let operation:
            nonisolated(nonsending) @Sendable (NativeSwiftConsuming<NativeSwiftValue>) async throws
                -> Int64 = { incoming in
                    await Task.yield()
                    captured.owned = incoming.value
                    return 42
                }
        #expect(
            try unsafe await visit.unsafeInvoke(NativeSwiftConsuming(value), Body(operation)) == 42
        )
        #expect(value.isConsumed && counts.destructions == 0)
        captured.owned = nil
        #expect(counts.destructions == 1)
    }

    @Test func nestedRuntimeClosuresComposeWithParameterPacksAndAsyncBorrowScopes() async throws {
        let runtime = ABIRuntime.shared
        typealias PackBody = NativeSwiftClosure<
            (NativeSwiftClosure<(Int64) -> Int64>, NativeSwiftClosure<(String) -> String>) throws ->
                Int64
        >
        let visitPack = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitNestedRuntimePack<each A>(_: repeat A.Type, body: (repeat (A) -> A) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((Int64.Type, String.Type, PackBody) throws -> Int64).self,
                    genericArguments: [.pack([.type(Int64.self), .type(String.self)])]
                )
            )
        )
        let copied = NestedRuntimePackCopies()
        let pack = try PackBody { number, text in
            copied.number = try number.copy()
            copied.text = try text.copy()
            let count = try unsafe text.unsafeInvoke("1234567").count
            return try unsafe number.unsafeInvoke(35) + Int64(count)
        }
        #expect(try unsafe visitPack.unsafeInvoke(Int64.self, String.self, pack) == 42)
        #expect(try unsafe copied.number!.unsafeInvoke(42) == 42)
        #expect(try unsafe copied.text!.unsafeInvoke("retained pack") == "retained pack")
        typealias Copy = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftValue) async -> NativeSwiftValue
        >
        typealias Body = NativeSwiftClosure<
            nonisolated(nonsending) (Copy, NativeSwiftValue) async throws -> NativeSwiftValue
        >
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitNestedRuntimeAsync<A>(A, nonisolated(nonsending) (nonisolated(nonsending) (A) async -> A, A) async throws -> A) async throws -> A",
                    as: (nonisolated(nonsending) (String, Body) async throws -> String).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let body:
            nonisolated(nonsending) @Sendable (Copy, NativeSwiftValue) async throws ->
                NativeSwiftValue = { copy, value in
                    await Task.yield()
                    return try unsafe await copy.unsafeInvoke(value)
                }
        #expect(try unsafe await visit.unsafeInvoke("nested async", Body(body)) == "nested async")
    }

    @Test func nestedRuntimeClosuresUseNativePlansForInputsResultsAndReturnedCallers() async throws
    {
        let runtime = ABIRuntime.shared
        typealias Copy = NativeSwiftClosure<(NativeSwiftValue) -> NativeSwiftValue>
        typealias Body = NativeSwiftClosure<(Copy, NativeSwiftValue) throws -> NativeSwiftValue>
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let number = try unsafe make.unsafeInvoke(42)
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitNestedRuntime<A>(A, ((A) -> A, A) throws -> A) throws -> A",
                    as: ((NativeSwiftValue, Body) throws -> NativeSwiftValue).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let saved = RuntimeCallbackValues()
        let body = try Body { callback, value in
            saved.nested = callback
            return try unsafe callback.unsafeInvoke(value)
        }
        let result = try unsafe visit.unsafeInvoke(number, body)
        #expect(try result.take(as: Int64.self) == 42)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe saved.nested!.unsafeInvoke(number)
        }
        let makeCaller = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeNestedRuntimeCaller<A>(A.Type) -> ((A) -> A, A) -> A",
                    as: ((Int64.Type) -> NativeSwiftClosure<
                        (Copy, NativeSwiftValue) -> NativeSwiftValue
                    >)
                    .self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let copyFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeCopy<A>(A.Type) -> (A) -> A",
                    as: ((Int64.Type) -> Copy).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let copy = try unsafe copyFactory.unsafeInvoke(Int64.self)
        let caller = try unsafe makeCaller.unsafeInvoke(Int64.self)
        let called = try unsafe caller.unsafeInvoke(copy, number)
        #expect(try called.take(as: Int64.self) == 42)
        typealias Producer = NativeSwiftClosure<() throws -> NativeSwiftClosure<(Int64) -> Int64>>
        let produce = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callNestedRuntimeProducer<A>(() throws -> (A) -> A, A) throws -> A",
                    as: ((Producer, Int64) throws -> Int64).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let producer = try Producer { try NativeSwiftClosure { (value: Int64) in value + 7 } }
        #expect(try unsafe produce.unsafeInvoke(producer, 35) == 42)
    }

    @Test func nongenericRuntimeClosuresUseNativeValuePlansAcrossFunctionsAndMembers() async throws
    {
        let runtime = ABIRuntime.shared
        typealias Copy = NativeSwiftClosure<(NativeSwiftValue) -> NativeSwiftValue>
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeConcreteRuntimeCopy() -> (Swift.String) -> Swift.String",
                    as: (() -> Copy).self
                )
            )
        )
        let sourceFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProducer<A>(A) -> () -> A",
                    as: ((String) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let input = try unsafe sourceFactory.unsafeInvoke("concrete").unsafeInvoke()
        let callback = try unsafe make.unsafeInvoke()
        #expect(try unsafe callback.unsafeInvoke(input).take(as: String.self) == "concrete!")
        typealias HostCopy = NativeSwiftClosure<(NativeSwiftValue) throws -> NativeSwiftValue>
        let apply = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.applyConcreteRuntimeCopy((Swift.String) throws -> Swift.String, Swift.String) throws -> Swift.String",
                    as: ((HostCopy, String) throws -> String).self
                )
            )
        )
        let identity = try HostCopy { $0 }
        #expect(try unsafe apply.unsafeInvoke(identity, "native") == "native")
        let type = try await runtime.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeCallbackHost", as: RuntimeCallbackHost.self))
        )
        let imageApply = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.applyConcreteRuntimeCopy((Swift.String) throws -> Swift.String, Swift.String) throws -> Swift.String",
                    as: ((HostCopy, String) throws -> String).self
                )
            ),
            in: type.image
        )
        #expect(try unsafe imageApply.unsafeInvoke(identity, "image") == "image")
        let host = RuntimeCallbackHost()
        let method = try await type.resolve(.swift(.method("copy()", as: (() -> Copy).self)))
        let methodCopy = try unsafe method.unsafeInvoke(on: host)
        #expect(try unsafe methodCopy.unsafeInvoke(input).take(as: String.self) == "concrete!")
        let getter = try await type.resolve(.swift(.getter("copier", as: (() -> Copy).self)))
        #expect(
            try unsafe getter.unsafeInvoke(on: host).unsafeInvoke(input).take(as: String.self)
                == "concrete!"
        )
        let applyMethod = try await type.resolve(
            .swift(
                .method(
                    "apply(_:_:)",
                    as: ((HostCopy, String) throws -> String).self
                )
            )
        )
        #expect(try unsafe applyMethod.unsafeInvoke(on: host, identity, "method") == "method")
    }

    @Test func hostRuntimeCallbackResultsMoveValuesAndReportConversionFailures() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let original = try unsafe make.unsafeInvoke(42)
        typealias Copy = NativeSwiftClosure<(NativeSwiftValue) throws -> NativeSwiftValue>
        let apply = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callRuntimeThrowingCopy<A>((A) throws -> A, A) throws -> A",
                    as: ((Copy, NativeSwiftValue) throws -> NativeSwiftValue).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let captured = RuntimeCallbackValues()
        let identity = try Copy { value in
            captured.owned = value; return value
        }
        let result = try unsafe apply.unsafeInvoke(identity, original)
        #expect(try result.take(as: Int64.self) == 42)
        #expect(captured.owned?.isConsumed == true && !original.isConsumed)

        typealias Producer = NativeSwiftClosure<() throws -> NativeSwiftValue>
        let produce = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callRuntimeProducer<A where A: ~Swift.Copyable>(() throws -> A) throws -> A",
                    as: ((Producer) throws -> NativeSwiftValue).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let stringFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProducer<A>(A) -> () -> A",
                    as: ((String) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let text = try unsafe stringFactory.unsafeInvoke("wrong type").unsafeInvoke()
        captured.owned = text
        let invalid = try Producer { captured.owned! }
        do {
            _ = try unsafe produce.unsafeInvoke(invalid)
            Issue.record("A mismatched runtime result must throw")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is ABIInvocationError })
        }
        #expect(!text.isConsumed)
        captured.owned = original
        try original.withBorrowedValue { _ in
            do {
                _ = try unsafe produce.unsafeInvoke(invalid)
                Issue.record("An active borrow must prevent result transfer")
            } catch let error as NativeSwiftError {
                #expect(error.withUnderlyingError { ($0 as? NativeSwiftValueError) == .valueInUse })
            }
        }
        #expect(!original.isConsumed)
        let transferred = try unsafe produce.unsafeInvoke(invalid)
        let transferredNumber = try transferred.take(as: Int64.self)
        #expect(original.isConsumed && transferredNumber == 42)
        do {
            _ = try unsafe produce.unsafeInvoke(invalid)
            Issue.record("A consumed runtime result must throw")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? NativeSwiftValueError) == .consumedValue })
        }
        let throwing = try Producer { throw RuntimeTicketFailure.rejected }
        do {
            _ = try unsafe produce.unsafeInvoke(throwing)
            Issue.record("The callback error must propagate")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is RuntimeTicketFailure })
        }
    }

    @Test func hostRuntimeCallbackResultsTransferNoncopyableOwnership() async throws {
        let runtime = ABIRuntime.shared
        let deaths = ArgumentCounts()
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let source = try unsafe make.unsafeInvoke(ErrorLifetimeToken { deaths.destroyed() })
        let produce = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callRuntimeProducer<A where A: ~Swift.Copyable>(() throws -> A) throws -> A",
                    as: ((NativeSwiftClosure<() throws -> NativeSwiftValue>) throws
                        -> NativeSwiftValue)
                        .self,
                    genericArguments: [.type(source.type)]
                )
            )
        )
        let captured = RuntimeCallbackValues()
        captured.owned = source
        let body = try NativeSwiftClosure<() throws -> NativeSwiftValue> { captured.owned! }
        do {
            let result = try unsafe produce.unsafeInvoke(body)
            #expect(source.isConsumed && !result.isCopyable && deaths.destructions == 0)
            let read = try await result.type.resolve(
                .swift(
                    .method(
                        "read()",
                        as: (() -> Int64).self,
                        receiverABI: .opaque(named: result.type.name)
                    )
                )
            )
            #expect(try unsafe read.unsafeInvoke(on: result) == 42)
        }
        #expect(deaths.destructions == 1)
    }

    @Test func hostAsyncRuntimeCallbackResultsTransferAfterSuspension() async throws {
        let runtime = ABIRuntime.shared
        typealias Copy = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftValue) async throws -> NativeSwiftValue
        >
        let apply = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callRuntimeThrowingAsyncCopy<A>(nonisolated(nonsending) (A) async throws -> A, A) async throws -> A",
                    as: (nonisolated(nonsending) (Copy, String) async throws -> String).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let captured = RuntimeCallbackValues()
        let operation:
            nonisolated(nonsending) @Sendable (NativeSwiftValue) async throws -> NativeSwiftValue =
                { value in
                    await Task.yield()
                    captured.owned = value
                    return value
                }
        #expect(try unsafe await apply.unsafeInvoke(Copy(operation), "suspended") == "suspended")
        #expect(captured.owned?.isConsumed == true)
        let invalid:
            nonisolated(nonsending) @Sendable (NativeSwiftValue) async throws -> NativeSwiftValue =
                { _ in
                    await Task.yield()
                    return captured.owned!
                }
        do {
            _ = try unsafe await apply.unsafeInvoke(Copy(invalid), "invalid")
            Issue.record("Async conversion failure must reach native code")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? NativeSwiftValueError) == .consumedValue })
        }
    }

    @Test func returnedRuntimeClosuresUseNativeArgumentsAndOwnedResults() async throws {
        let runtime = ABIRuntime.shared
        let makeNumber = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let number = try unsafe makeNumber.unsafeInvoke(42)
        typealias Copy = NativeSwiftClosure<(NativeSwiftValue) -> NativeSwiftValue>
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeCopy<A>(A.Type) -> (A) -> A",
                    as: ((Int64.Type) -> Copy).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let copy = try unsafe factory.unsafeInvoke(Int64.self)
        let result = try unsafe copy.unsafeInvoke(number)
        #expect(try result.take(as: Int64.self) == 42 && !number.isConsumed)
        let invokeCopy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callRuntimeCopy<A>((A) -> A, A) -> A",
                    as: ((Copy, NativeSwiftValue) -> NativeSwiftValue).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let returned = try unsafe invokeCopy.unsafeInvoke(copy, number)
        #expect(try returned.take(as: Int64.self) == 42 && !number.isConsumed)
        let neverFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeNeverCopy<A, B where B: Swift.Error>(A.Type, B.Type) -> (A) throws(B) -> A",
                    as: ((Int64.Type, Never.Type) -> Copy).self,
                    genericArguments: [.type(Int64.self), .type(Never.self)]
                )
            )
        )
        let neverCopy = try unsafe neverFactory.unsafeInvoke(Int64.self, Never.self)
        let directNever = try unsafe neverCopy.unsafeInvoke(number)
        #expect(try directNever.take(as: Int64.self) == 42)
        let returnedNever = try unsafe invokeCopy.unsafeInvoke(neverCopy, number)
        #expect(try returnedNever.take(as: Int64.self) == 42)
        typealias ThrowingCopy = NativeSwiftClosure<
            (NativeSwiftValue) throws(RuntimeTicketFailure) -> NativeSwiftValue
        >
        let failingFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeThrowingCopy<A, B where B: Swift.Error>(A.Type, B, Swift.Bool) -> (A) throws(B) -> A",
                    as: ((Int64.Type, RuntimeTicketFailure, Bool) -> ThrowingCopy).self,
                    genericArguments: [.type(Int64.self), .type(RuntimeTicketFailure.self)]
                )
            )
        )
        let failing = try unsafe failingFactory.unsafeInvoke(
            Int64.self,
            RuntimeTicketFailure.rejected,
            true
        )
        #expect(throws: NativeSwiftError.self) { try unsafe failing.unsafeInvoke(number) }
        #expect(!number.isConsumed)
        let textFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProducer<A>(A) -> () -> A",
                    as: ((String) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let text = try unsafe textFactory.unsafeInvoke("captured")
        let string = try unsafe text.unsafeInvoke()
        #expect(try string.copy().take(as: String.self) == "captured")
        #expect(throws: ABIInvocationError.self) { try unsafe copy.unsafeInvoke(string) }
        #expect(!string.isConsumed && !number.isConsumed)
        _ = try number.take(as: Int64.self)
        #expect(throws: NativeSwiftValueError.consumedValue) {
            try unsafe copy.unsafeInvoke(number)
        }
    }

    @Test func returnedRuntimeClosuresRestoreElidedMetatypes() async throws {
        typealias Metadata = GenericMetatypeValue<String>.Type
        typealias Copy = NativeSwiftClosure<(NativeSwiftValue) -> NativeSwiftValue>
        let runtime = ABIRuntime.shared
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeCopy<A>(A.Type) -> (A) -> A",
                    as: ((Metadata.Type) -> Copy).self,
                    genericArguments: [.type(Metadata.self)]
                )
            )
        )
        let copy = try unsafe factory.unsafeInvoke(Metadata.self)
        let producer = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProducer<A>(A) -> () -> A",
                    as: ((Metadata) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
                    genericArguments: [.type(Metadata.self)]
                )
            )
        )
        let input = try unsafe producer.unsafeInvoke(GenericMetatypeValue<String>.self)
            .unsafeInvoke()
        let output = try unsafe copy.unsafeInvoke(input)
        #expect(try output.take(as: Metadata.self) == GenericMetatypeValue<String>.self)
    }

    @Test func returnedRuntimeReadersBorrowNoncopyableValuesAndReenterNativeCode() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken {})
        typealias Reader = NativeSwiftClosure<(NativeSwiftValue) -> Int64>
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeReader<A where A: ~Swift.Copyable>(A.Type) -> (A) -> Swift.Int64",
                    as: ((RuntimeTicket.Type) -> Reader).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
        let reader = try unsafe factory.unsafeInvoke(RuntimeTicket.self)
        #expect(try unsafe reader.unsafeInvoke(value) == MemoryLayout<RuntimeTicket>.size)
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.inspectRuntimeReader<A where A: ~Swift.Copyable>(A, (A) -> Swift.Int64) -> Swift.Int64",
                    as: ((NativeSwiftValue, Reader) -> Int64).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
        #expect(try unsafe visit.unsafeInvoke(value, reader) == MemoryLayout<RuntimeTicket>.size)
        #expect(!value.isConsumed)
        let calls = Mutex(0)
        let copyingBody = try Reader { _ in
            calls.withLock { $0 += 1 }; return 0
        }
        #expect(throws: NativeSwiftValueError.noncopyableType) {
            try unsafe visit.unsafeInvoke(value, copyingBody)
        }
        #expect(calls.withLock { $0 } == 0 && !value.isConsumed)
        typealias BorrowedReader = NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Int64>
        let borrowedFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeReader<A where A: ~Swift.Copyable>(A.Type) -> (A) -> Swift.Int64",
                    as: ((RuntimeTicket.Type) -> BorrowedReader).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
        let borrowedReader = try unsafe borrowedFactory.unsafeInvoke(RuntimeTicket.self)
        var escaped: NativeSwiftBorrowedValue?
        try value.withBorrowedValue { borrowed in
            escaped = borrowed
            let size = try unsafe borrowedReader.unsafeInvoke(borrowed)
            #expect(size == MemoryLayout<RuntimeTicket>.size)
        }
        let expired = try #require(escaped)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe borrowedReader.unsafeInvoke(expired)
        }
        let wrong = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.inspectRuntimeReader<A where A: ~Swift.Copyable>(A, (A) -> Swift.Int64) -> Swift.Int64",
                    as: ((Int64, Reader) -> Int64).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        #expect(throws: ABIResolutionError.self) {
            try unsafe wrong.unsafeInvoke(Int64(42), reader)
        }
    }

    @Test func returnedAsyncRuntimeClosuresRetainValuesAcrossSuspension() async throws {
        let runtime = ABIRuntime.shared
        typealias Copy = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftValue) async -> NativeSwiftValue
        >
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeAsyncCopy<A>(A.Type) -> nonisolated(nonsending) (A) async -> A",
                    as: ((String.Type) -> Copy).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let copy = try unsafe factory.unsafeInvoke(String.self)
        let producer = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProducer<A>(A) -> () -> A",
                    as: ((String) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let source = try unsafe producer.unsafeInvoke("after suspension").unsafeInvoke()
        let output = try unsafe await copy.unsafeInvoke(source)
        #expect(try output.take(as: String.self) == "after suspension" && !source.isConsumed)
        let neverFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeNeverAsyncCopy<A, B where B: Swift.Error>(A.Type, B.Type) -> nonisolated(nonsending) (A) async throws(B) -> A",
                    as: ((String.Type, Never.Type) -> Copy).self,
                    genericArguments: [.type(String.self), .type(Never.self)]
                )
            )
        )
        let neverCopy = try unsafe neverFactory.unsafeInvoke(String.self, Never.self)
        let neverOutput = try unsafe await neverCopy.unsafeInvoke(source)
        #expect(try neverOutput.take(as: String.self) == "after suspension")
        let apply = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.callRuntimeAsyncCopy<A>(nonisolated(nonsending) (A) async -> A, A) async -> A",
                    as: (nonisolated(nonsending) (Copy, NativeSwiftValue) async -> NativeSwiftValue)
                        .self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let passedBack = try unsafe await apply.unsafeInvoke(neverCopy, source)
        #expect(try passedBack.take(as: String.self) == "after suspension")
    }

    @Test func returnedRuntimePackClosuresCanBePassedBackToNativeCallers() async throws {
        let runtime = ABIRuntime.shared
        typealias Reader = NativeSwiftClosure<(NativeSwiftValue, String) -> Int64>
        let factory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimePackReader<each A>(repeat A) -> (repeat A) -> Swift.Int64",
                    as: ((Int64, String) -> Reader).self,
                    genericArguments: [.pack([.type(Int64.self), .type(String.self)])]
                )
            )
        )
        let reader = try unsafe factory.unsafeInvoke(Int64(1), "one")
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let value = try unsafe make.unsafeInvoke(42)
        #expect(try unsafe reader.unsafeInvoke(value, "two") == 42)
        let inspect = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.inspectRuntimePackReader<each A>((repeat A) -> Swift.Int64, repeat A) -> Swift.Int64",
                    as: ((Reader, Int64, String) -> Int64).self,
                    genericArguments: [.pack([.type(Int64.self), .type(String.self)])]
                )
            )
        )
        #expect(try unsafe inspect.unsafeInvoke(reader, Int64(2), "three") == 42)
        let concreteFactory = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeConcreteRuntimeReader<A>(A) -> (Swift.Int64, Swift.String) -> Swift.Int64",
                    as: ((Int64) -> Reader).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let concrete = try unsafe concreteFactory.unsafeInvoke(Int64(0))
        #expect(try unsafe concrete.unsafeInvoke(value, "one") == 45)
        #expect(try unsafe inspect.unsafeInvoke(concrete, Int64(2), "three") == 7)
    }

    @Test func runtimeCallbackInputsPreserveBorrowScopeAndIndependentCopies() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let original = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let read = try await original.type.resolve(
            .swift(
                .method(
                    "read()",
                    as: (() -> Int64).self,
                    receiverABI: .opaque(named: original.type.name)
                )
            )
        )
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeValue<A where A: ~Swift.Copyable>(A, (A) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((
                        NativeSwiftValue,
                        NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Int64>
                    )
                        throws -> Int64).self,
                    genericArguments: [.type(original.type)]
                )
            )
        )
        let captured = RuntimeCallbackValues()
        let callback = try NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Int64> { value in
            captured.borrowed = value
            #expect(throws: NativeSwiftValueError.noncopyableType) { try value.copy() }
            return try unsafe read.unsafeInvoke(on: value)
        }
        #expect(try unsafe visit.unsafeInvoke(original, callback) == 42)
        #expect(!original.isConsumed && counts.destructions == 0)
        let expired = try #require(captured.borrowed)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try expired.copy() }

        let makeNumber = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let number = try unsafe makeNumber.unsafeInvoke(42)
        let copy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeValue<A where A: ~Swift.Copyable>(A, (A) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((NativeSwiftValue, NativeSwiftClosure<(NativeSwiftValue) throws -> Int64>)
                        throws
                        -> Int64).self,
                    genericArguments: [.type(number.type)]
                )
            )
        )
        let copyBody = try NativeSwiftClosure<(NativeSwiftValue) throws -> Int64> { value in
            captured.owned = value
            return try value.withCopy { $0 as! Int64 }
        }
        #expect(try unsafe copy.unsafeInvoke(number, copyBody) == 42)
        let retained = try #require(captured.owned)
        #expect(retained !== number && !number.isConsumed)
        #expect(try retained.take(as: Int64.self) == 42)

        let concrete = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitConcreteRuntimeValue<A>(A, Swift.String, (Swift.String) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((Int64, String, NativeSwiftClosure<(NativeSwiftValue) throws -> Int64>)
                        throws
                        -> Int64).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let textBody = try NativeSwiftClosure<(NativeSwiftValue) throws -> Int64> { value in
            Int64(try value.take(as: String.self).count)
        }
        #expect(try unsafe concrete.unsafeInvoke(Int64(1), "concrete", textBody) == 8)
    }

    @Test func asyncRuntimeCallbacksKeepBorrowsUntilNativeCompletion() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let original = try unsafe make.unsafeInvoke(ErrorLifetimeToken {})
        let read = try await original.type.resolve(
            .swift(
                .method(
                    "readAsync()",
                    as: (() async -> Int64).self,
                    receiverABI: .opaque(named: original.type.name)
                )
            )
        )
        typealias Body = NativeSwiftClosure<
            nonisolated(nonsending) (NativeSwiftBorrowedValue) async throws -> Int64
        >
        let visit = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeValueAsync<A where A: ~Swift.Copyable>(A, nonisolated(nonsending) (A) async throws -> Swift.Int64) async throws -> Swift.Int64",
                    as: ((NativeSwiftValue, Body) async throws -> Int64).self,
                    genericArguments: [.type(original.type)]
                )
            )
        )
        let captured = RuntimeCallbackValues()
        let operation:
            nonisolated(nonsending) @Sendable (NativeSwiftBorrowedValue) async throws -> Int64 = {
                value in
                captured.borrowed = value
                await Task.yield()
                return try unsafe await read.unsafeInvoke(on: value)
            }
        let callback = try Body(operation)
        #expect(try unsafe await visit.unsafeInvoke(original, callback) == 42)
        #expect(!original.isConsumed)
        let expired = try #require(captured.borrowed)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try expired.copy() }
    }

    @Test func runtimeCallbackBorrowsRestoreElidedMetatypes() async throws {
        let visit = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.visitRuntimeMetatype<A>(ManagedSwiftFixtures.GenericMetatypeValue<A>.Type, (ManagedSwiftFixtures.GenericMetatypeValue<A>.Type) throws -> Swift.Int64) throws -> Swift.Int64",
                    as: ((
                        GenericMetatypeValue<String>.Type,
                        NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Int64>
                    ) throws -> Int64).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let body = try NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Int64> { value in
            let copy = try value.copy()
            let metatype = try copy.take(as: GenericMetatypeValue<String>.Type.self)
            #expect(
                unsafeBitCast(metatype, to: UInt.self)
                    == unsafeBitCast(GenericMetatypeValue<String>.self, to: UInt.self)
            )
            return 42
        }
        #expect(try unsafe visit.unsafeInvoke(GenericMetatypeValue<String>.self, body) == 42)
    }

    @Test func callbackBodiesCanPassRuntimeHandlesAsOrdinarySwiftReferences() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let original = try unsafe make.unsafeInvoke(42)
        let callback = try NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> NativeSwiftValue>
        { value in
            try value.copy()
        }
        try original.withBorrowedValue { value in
            let copied = try unsafe callback.unsafeInvoke(value)
            #expect(copied !== original)
            #expect(try copied.withCopy { $0 as? Int64 } == 42)
        }
    }

    @Test func runtimeClassArgumentsRespectVarianceAndInoutReplacement() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueClassAny(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let original = try unsafe make.unsafeInvoke(ErrorLifetimeToken {})
        let copy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    genericArguments: [.type(OpaqueBase.self)]
                )
            )
        )
        let copied = try unsafe copy.unsafeInvoke(original)
        let object = try copied.take(as: OpaqueBase.self)
        #expect(object.number == 41)
        let borrowedCopy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((NativeSwiftBorrowedValue) -> NativeSwiftValue).self,
                    genericArguments: [.type(AnyObject.self)]
                )
            )
        )
        try original.withBorrowedValue { value in
            let copied = try unsafe borrowedCopy.unsafeInvoke(value)
            #expect(try copied.take(as: AnyObject.self) === object)
        }
        let replace = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.replaceRuntimeValue<A where A: ~Swift.Copyable>(inout A, __owned A) -> ()",
                    as: ((
                        NativeSwiftInout<NativeSwiftValue>, NativeSwiftConsuming<NativeSwiftValue>
                    )
                        -> Void).self,
                    genericArguments: [.type(OpaqueBase.self)]
                )
            )
        )
        let replacement = try unsafe copy.unsafeInvoke(original)
        do {
            try unsafe replace.unsafeInvoke(
                NativeSwiftInout(original),
                NativeSwiftConsuming(replacement)
            )
            Issue.record("An inout Base argument accepted storage owned as a derived type")
        } catch ABIInvocationError.incompatibleValue {}
        #expect(!original.isConsumed && !replacement.isConsumed)
        let move = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.moveRuntimeValue<A where A: ~Swift.Copyable>(__owned A) -> A",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self,
                    genericArguments: [.type(OpaqueBase.self)],
                    declaredAs: "<A where A: ~Swift.Copyable>(__owned A) -> A"
                )
            )
        )
        let moved = try unsafe move.unsafeInvoke(NativeSwiftConsuming(original))
        #expect(original.isConsumed)
        #expect(try moved.take(as: OpaqueBase.self) === object)
    }

    @Test func runtimeResultsRestoreElidedSingletonMetatypes() async throws {
        let type = try await ABIRuntime.shared.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.GenericMetatypeValue",
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let function = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.valueMetatypeGeneric<A>(ManagedSwiftFixtures.GenericMetatypeValue<A>.Type, Swift.Int64) -> (ManagedSwiftFixtures.GenericMetatypeValue<A>.Type, Swift.Int64)",
                    as: ((NativeSwiftValue, Int64) -> NativeSwiftValue).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let result = try unsafe function.unsafeInvoke(type.makeMetatypeValue(), Int64(40))
        let value = try result.take(as: (GenericMetatypeValue<String>.Type, Int64).self)
        #expect(
            unsafeBitCast(value.0, to: UInt.self)
                == unsafeBitCast(GenericMetatypeValue<String>.self, to: UInt.self)
        )
        #expect(value.1 == 41)
    }
    @Test func genericRuntimeArgumentsAndResultsPreserveNativeOwnership() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let original = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let arguments: [NativeSwiftGenericArgument] = [.type(original.type)]
        let borrow = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.borrowRuntimeValue<A where A: ~Swift.Copyable>(A) -> Swift.Int64",
                    as: ((NativeSwiftValue) -> Int64).self,
                    genericArguments: arguments
                )
            )
        )
        #expect(try unsafe borrow.unsafeInvoke(original) == Int64(MemoryLayout<RuntimeTicket>.size))
        let borrowed = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.borrowRuntimeValue<A where A: ~Swift.Copyable>(A) -> Swift.Int64",
                    as: ((NativeSwiftBorrowedValue) -> Int64).self,
                    genericArguments: arguments
                )
            )
        )
        try original.withBorrowedValue { value throws -> Void in
            #expect(
                try unsafe borrowed.unsafeInvoke(value) == Int64(MemoryLayout<RuntimeTicket>.size)
            )
        }
        #expect(!original.isConsumed && counts.destructions == 0)
        do {
            _ = try await runtime.resolve(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                        as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                        genericArguments: arguments
                    )
                )
            )
            Issue.record("A Copyable generic declaration accepted a noncopyable substitution")
        } catch ABIResolutionError.signatureMismatch(let detail) {
            #expect(detail.expected == "A: Swift.Copyable")
        }
        let move = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.moveRuntimeValue<A where A: ~Swift.Copyable>(__owned A) -> A",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self,
                    genericArguments: arguments,
                    declaredAs: "<A where A: ~Swift.Copyable>(__owned A) -> A"
                )
            )
        )
        let moved = try unsafe move.unsafeInvoke(NativeSwiftConsuming(original))
        #expect(original.isConsumed && !moved.isConsumed && !moved.isCopyable)
        #expect(counts.destructions == 0)
        let consume = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.consumeRuntimeValueAndThrow<A where A: ~Swift.Copyable>(__owned A) throws -> ()",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>) throws -> Void).self,
                    genericArguments: arguments
                )
            )
        )
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
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let first = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let second = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let replace = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.replaceRuntimeValue<A where A: ~Swift.Copyable>(inout A, __owned A) -> ()",
                    as: ((
                        NativeSwiftInout<NativeSwiftValue>, NativeSwiftConsuming<NativeSwiftValue>
                    )
                        -> Void).self,
                    genericArguments: [.type(first.type)]
                )
            )
        )
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
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let move = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.moveRuntimeValueAfterArgument<A where A: ~Swift.Copyable>(__owned A, Swift.Int64) -> A",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>, RuntimeRejectedArgument)
                        -> NativeSwiftValue).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
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
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let original = try unsafe make.unsafeInvoke(42)
        let copy = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    genericArguments: [.type(original.type)]
                )
            )
        )
        let copied = try unsafe copy.unsafeInvoke(original)
        #expect(try copied.take(as: Int64.self) == 42)
        #expect(!original.isConsumed)
        let makeTicket = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let ticket = try unsafe makeTicket.unsafeInvoke(ErrorLifetimeToken {})
        do {
            _ = try unsafe copy.unsafeInvoke(ticket)
            Issue.record("A runtime argument with different native metadata was accepted")
        } catch ABIInvocationError.incompatibleValue {}
        #expect(!ticket.isConsumed)
        #expect(try original.take(as: Int64.self) == 42)
    }

    @Test func noncopyableNominalContextsPreserveTheirSuppressedRequirements() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeTicket(_:)",
                    as: ((AnyObject) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let ticket = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let type = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.RuntimeValueBox",
                    genericArguments: [.type(ticket.type)]
                )
            )
        )
        let initialize = try await type.resolve(
            .swift(
                .initializer(
                    "init(_:)",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self
                )
            )
        )
        let box = try unsafe initialize.unsafeInvoke(NativeSwiftConsuming(ticket))
        #expect(ticket.isConsumed && !box.isConsumed && !box.isCopyable)
        #expect(throws: NativeSwiftValueError.noncopyableType) { try box.copy() }
        #expect(throws: NativeSwiftValueError.noncopyableType) { try box.withCopy { _ in } }
        let take = try await type.resolve(
            .swift(
                .method(
                    "takeValue()",
                    as: (() -> NativeSwiftValue).self,
                    receiver: .consuming
                )
            )
        )
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
        let makeInteger = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let integer = try unsafe makeInteger.unsafeInvoke(42)
        let copyableType = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.RuntimeConditionalValueBox",
                    genericArguments: [.type(integer.type)]
                )
            )
        )
        let makeCopyable = try await copyableType.resolve(
            .swift(
                .initializer(
                    "init(_:)",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self
                )
            )
        )
        let copyable = try unsafe makeCopyable.unsafeInvoke(NativeSwiftConsuming(integer))
        #expect(copyable.isCopyable)
        let copy = try copyable.copy()
        #expect(try copy.take(as: RuntimeConditionalValueBox<Int64>.self).value == 42)
        let makeTicket = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeTicket(_:)",
                    as: ((AnyObject) -> NativeSwiftValue).self
                )
            )
        )
        let ticket = try unsafe makeTicket.unsafeInvoke(NSObject())
        let noncopyableType = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.RuntimeConditionalValueBox",
                    genericArguments: [.type(ticket.type)]
                )
            )
        )
        let makeNoncopyable = try await noncopyableType.resolve(
            .swift(
                .initializer(
                    "init(_:)",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self
                )
            )
        )
        let noncopyable = try unsafe makeNoncopyable.unsafeInvoke(NativeSwiftConsuming(ticket))
        #expect(!noncopyable.isCopyable)
        #expect(throws: NativeSwiftValueError.noncopyableType) { try noncopyable.copy() }
        do {
            _ = try await runtime.resolve(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                        as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                        genericArguments: [.type(noncopyable.type)]
                    )
                )
            )
            Issue.record("A conditional Copyable constraint accepted a noncopyable argument")
        } catch ABIResolutionError.signatureMismatch {}
    }

    @Test func memberCopyableRequirementsOverrideNominalSuppression() async throws {
        let runtime = ABIRuntime.shared
        let copyable = try await runtime.resolve(
            .swift(
                .type("ManagedSwiftFixtures.RuntimeValueBox", genericArguments: [.type(Int64.self)])
            )
        )
        let initialize = try await copyable.resolve(
            .swift(
                .initializer(
                    "init(_:)",
                    as: ((NativeSwiftConsuming<Int64>) -> NativeSwiftValue).self
                )
            )
        )
        let box = try unsafe initialize.unsafeInvoke(NativeSwiftConsuming(Int64(42)))
        let copy = try await copyable.resolve(
            .swift(.method("copiedValue()", as: (() -> Int64).self))
        )
        #expect(try unsafe copy.unsafeInvoke(on: box) == 42)
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeTicket(_:)",
                    as: ((AnyObject) -> NativeSwiftValue).self
                )
            )
        )
        let ticket = try unsafe make.unsafeInvoke(NSObject())
        let noncopyable = try await runtime.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.RuntimeValueBox",
                    genericArguments: [.type(ticket.type)]
                )
            )
        )
        do {
            _ = try await noncopyable.resolve(
                .swift(
                    .method(
                        "copiedValue()",
                        as: (() -> NativeSwiftValue).self
                    )
                )
            )
            Issue.record(
                "A member's explicit Copyable requirement was suppressed by its nominal type"
            )
        } catch ABIResolutionError.declarationNotFound(let declaration) {
            #expect(declaration.name == "ManagedSwiftFixtures.RuntimeValueBox.copiedValue()")
        }
    }

    @Test @MainActor func runtimeArgumentsKeepAccessThroughAsyncCompletion() async throws {
        guard #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else { return }
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let arguments: [NativeSwiftGenericArgument] = [.type(value.type)]
        let borrow = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.borrowRuntimeValueAsync<A where A: ~Swift.Copyable>(A, ManagedSwiftFixtures.AsyncGate) async -> Swift.Int64",
                    as: ((NativeSwiftBorrowedValue, AsyncGate) async -> Int64).self,
                    genericArguments: arguments
                )
            )
        )
        let gate = AsyncGate()
        let task = try value.withBorrowedValue { borrowed in
            Task.immediate { try unsafe await borrow.unsafeInvoke(borrowed, gate) }
        }
        await gate.waitUntilSuspended()
        #expect(throws: NativeSwiftValueError.valueInUse) {
            _ = try value.take(as: RuntimeTicket.self)
        }
        await gate.open()
        #expect(try await task.value == Int64(MemoryLayout<RuntimeTicket>.size))
        let move = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.moveRuntimeValueAsync<A where A: ~Swift.Copyable>(__owned A) async -> A",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>) async -> NativeSwiftValue).self,
                    genericArguments: arguments
                )
            )
        )
        let moved = try unsafe await move.unsafeInvoke(NativeSwiftConsuming(value))
        #expect(value.isConsumed && counts.destructions == 0)
        do {
            let native = try moved.take(as: RuntimeTicket.self)
            #expect(native.number == 42)
        }
        #expect(moved.isConsumed && counts.destructions == 1)
    }
    #if os(macOS)
    @Test func runtimeMetatypeValuesSupplyExplicitGenericTypeArguments() async throws {
        let module = "RuntimeMetatype_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                import Foundation
                public struct Record: Decodable { public let number: Int64 }
                public func decode<Value: Decodable>(
                    _ type: Value.Type, from data: NSData
                ) throws -> (Value, String) {
                    (try JSONDecoder().decode(type, from: data as Data), String(reflecting: type))
                }
                """,
            linkArguments: ["-swift-version", "6", "-enable-library-evolution"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let type = try await runtime.resolve(
            .swift(.type(module + ".Record")),
            in: .path(library.libraryURL)
        )
        let decode = try await runtime.resolve(
            .swift(
                .function(
                    module + ".decode(_:from:)",
                    as: ((NativeSwiftValue, NSData) throws -> (NativeSwiftValue, String)).self,
                    genericArguments: [.type(type)]
                )
            ),
            in: .path(library.libraryURL)
        )
        let data = Data(#"{"number":42}"#.utf8) as NSData
        let (value, typeName) = try unsafe decode.unsafeInvoke(type.makeMetatypeValue(), data)
        #expect(typeName == type.name)
        let number = try await value.type.resolve(.swift(.getter("number", as: (() -> Int64).self)))
        #expect(try unsafe number.unsafeInvoke(on: value) == 42)
    }

    #endif
    #if DEBUG && os(macOS)
    @Test func anOpaqueFactoryKeepsItsOwnCodeAndUsesTheUnderlyingTypeImage() async throws {
        let module = "OpaqueType_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let provider = try FixtureLibrary(
            load: false,
            swiftModule: module,
            swiftSource: """
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
                """,
            linkArguments: ["-swift-version", "6", "-emit-module", "-enable-library-evolution"]
        )
        defer { provider.cleanup() }
        let factory = try FixtureLibrary(
            load: false,
            swiftModule: module + "Factory",
            swiftSource: """
                import \(module)
                public func make() -> some AnyObject { Box { 42 } }
                public func makeHidden() -> some AnyObject { hidden { 43 } }
                """,
            linkArguments: [
                "-swift-version", "6", "-I", provider.directory.path, provider.libraryURL.path,
            ]
        )
        defer { factory.cleanup() }
        try factory.load()
        let runtime = ABIRuntime()
        for (name, number) in [("make", Int64(42)), ("makeHidden", Int64(43))] {
            let value: NativeSwiftValue
            do {
                let make = try await runtime.resolve(
                    .swift(
                        .function(
                            module + "Factory." + name + "()",
                            as: (() -> NativeSwiftValue).self
                        )
                    ),
                    in: .path(factory.libraryURL)
                )
                value = try unsafe make.unsafeInvoke().copy()
            }
            runtime.removeCachedResults()
            factory.close()
            let expected = try #require(
                try runtime.resolveImagesAndWait(matching: .path(provider.libraryURL)).first
            )
            #expect(value.type.image.identity == expected.identity)
            let getter = try await value.type.resolve(
                .swift(.getter("value", as: (() -> Int64).self))
            )
            #expect(try unsafe getter.unsafeInvoke(on: value) == number)
            weak var observed: AnyObject?
            try value.withCopy { observed = $0 as AnyObject }
            let take = try await value.type.resolve(
                .swift(
                    .method(
                        "take()",
                        as: (() -> Int64).self,
                        receiver: .consuming
                    )
                )
            )
            #expect(try unsafe take.unsafeInvoke(on: value) == number)
            #expect(value.isConsumed && observed == nil)
        }
    }
    #endif

    @Test func runtimeValuesUseOrdinaryMembersWithExplicitOwnership() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let abi = try NativeType.opaque(named: value.type.name)
        let read = try await value.type.resolve(
            .swift(
                .method(
                    "read()",
                    as: (() -> Int64).self,
                    receiverABI: abi
                )
            )
        )
        let getter = try await value.type.resolve(
            .swift(
                .getter(
                    "number",
                    as: (() -> Int64).self,
                    receiverABI: abi
                )
            )
        )
        let add = try await value.type.resolve(
            .swift(
                .method(
                    "add(_:)",
                    as: ((Int64) -> Void).self,
                    receiverABI: abi,
                    receiver: .mutating
                )
            )
        )
        let take = try await value.type.resolve(
            .swift(
                .method(
                    "takeNumber()",
                    as: (() -> Int64).self,
                    receiverABI: abi,
                    receiver: .consuming
                )
            )
        )
        #expect(try unsafe read.unsafeInvoke(on: value) == 42)
        try unsafe add.unsafeInvoke(on: value, 5)
        #expect(try unsafe getter.unsafeInvoke(on: value) == 47)
        var escaped: NativeSwiftBorrowedValue?
        try value.withBorrowedValue { borrowed in
            escaped = borrowed
            let number = try unsafe read.unsafeInvoke(on: borrowed)
            #expect(number == 47)
            #expect(throws: NativeSwiftValueError.valueInUse) {
                try unsafe add.unsafeInvoke(on: value, 1)
            }
            #expect(throws: NativeSwiftValueError.valueInUse) {
                try unsafe take.unsafeInvoke(on: borrowed)
            }
            #expect(throws: NativeSwiftValueError.valueInUse) {
                try unsafe take.unsafeInvoke(on: value)
            }
        }
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe read.unsafeInvoke(on: escaped!)
        }
        #expect(try unsafe take.unsafeInvoke(on: value) == 47)
        #expect(value.isConsumed && counts.destructions == 1)
        #expect(throws: NativeSwiftValueError.consumedValue) {
            try unsafe read.unsafeInvoke(on: value)
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func aStartedAsyncBorrowRetainsItsOwnerAccessAfterScopeExit(_ inoutReceiver: Bool) async throws
    {
        guard #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else { return }
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let abi = try NativeType.opaque(named: value.type.name)
        let read = try await value.type.resolve(
            .swift(
                .method(
                    "readAfter(_:)",
                    as: ((AsyncGate) async -> Int64).self,
                    receiverABI: abi
                )
            )
        )
        let add = try await value.type.resolve(
            .swift(
                .method(
                    "add(_:)",
                    as: ((Int64) -> Void).self,
                    receiverABI: abi,
                    receiver: .mutating
                )
            )
        )
        let gate = AsyncGate()
        let task = try value.withBorrowedValue { borrowed in
            Task.immediate { @MainActor in
                var receiver = borrowed
                if inoutReceiver { return try unsafe await read.unsafeInvoke(on: &receiver, gate) }
                return try unsafe await read.unsafeInvoke(on: receiver, gate)
            }
        }
        await gate.waitUntilSuspended()
        #expect(throws: NativeSwiftValueError.valueInUse) {
            try unsafe add.unsafeInvoke(on: value, 1)
        }
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
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let abi = try NativeType.opaque(named: value.type.name)
        let read = try await value.type.resolve(
            .swift(
                .method(
                    "read() -> Swift.Int64",
                    as: (() -> RuntimeWordResult).self,
                    receiverABI: abi
                )
            )
        )
        let readAsync = try await value.type.resolve(
            .swift(
                .method(
                    "readAsync() async -> Swift.Int64",
                    as: (() async -> RuntimeWordResult).self,
                    receiverABI: abi
                )
            )
        )
        let add = try await value.type.resolve(
            .swift(
                .method(
                    "add(_:)",
                    as: ((Int64) -> Void).self,
                    receiverABI: abi,
                    receiver: .mutating
                )
            )
        )
        let take = try await value.type.resolve(
            .swift(
                .method(
                    "takeNumberAsync() async -> Swift.Int64",
                    as: (() async -> RuntimeWordResult).self,
                    receiverABI: abi,
                    receiver: .consuming
                )
            )
        )
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
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        var results: [RuntimeWordResult] = []
        do {
            let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
            let abi = try NativeType.opaque(named: value.type.name)
            let read = try await value.type.resolve(
                .swift(
                    .method(
                        "read() -> Swift.Int64",
                        as: (() -> RuntimeWordResult).self,
                        receiverABI: abi
                    )
                )
            )
            let readAsync = try await value.type.resolve(
                .swift(
                    .method(
                        "readAsync() async -> Swift.Int64",
                        as: (() async -> RuntimeWordResult).self,
                        receiverABI: abi
                    )
                )
            )
            let add = try await value.type.resolve(
                .swift(
                    .method(
                        "add(_:)",
                        as: ((Int64) -> Void).self,
                        receiverABI: abi,
                        receiver: .mutating
                    )
                )
            )
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
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let abi = try NativeType.opaque(named: value.type.name)
        let read = try await value.type.resolve(
            .swift(
                .method(
                    "readAsync()",
                    as: (() async -> Int64).self,
                    receiverABI: abi
                )
            )
        )
        let add = try await value.type.resolve(
            .swift(
                .method(
                    "addThenThrow(_:)",
                    as: ((Int64) async throws -> Void).self,
                    receiverABI: abi,
                    receiver: .mutating
                )
            )
        )
        let take = try await value.type.resolve(
            .swift(
                .method(
                    "takeNumberAsync()",
                    as: (() async -> Int64).self,
                    receiverABI: abi,
                    receiver: .consuming
                )
            )
        )
        #expect(try unsafe await read.unsafeInvoke(on: value) == 42)
        do {
            try unsafe await add.unsafeInvoke(on: value, 5)
            Issue.record("Native failure was not propagated")
        } catch is NativeSwiftError {}
        #expect(try unsafe await read.unsafeInvoke(on: value) == 47)
        #expect(!value.isConsumed && counts.destructions == 0)
        #expect(try unsafe await take.unsafeInvoke(on: value) == 47)
        #expect(value.isConsumed && counts.destructions == 1)
    }

    @Test func aCopyOfATemporaryRetainsItsManagedPayload() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaque(_:_:)",
                    as: ((ErrorLifetimeToken, Int64) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        var copy: NativeSwiftValue? = try unsafe make.unsafeInvoke(
            ErrorLifetimeToken { counts.destroyed() },
            42
        ).copy()
        #expect(counts.destructions == 0)
        try copy!.withCopy { #expect(($0 as? any ExistentialValue)?.number == 42) }
        copy = nil
        #expect(counts.destructions == 1)
    }

    @Test func opaqueNoncopyableValuesMoveWithoutAnyErasure() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
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

        let copyable = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeCopyableNoncopyableOpaque()",
                    as: (() -> NativeSwiftValue).self
                )
            )
        )
        let actual = try unsafe copyable.unsafeInvoke()
        #expect(actual.isCopyable)
        let copy = try actual.copy()
        #expect(try copy.take(as: Int64.self) == 42)
        #expect(try actual.take(as: Int64.self) == 42)
    }

    @Test func ownedCopiesMovesAndScopedBorrowsHaveIndependentLifetimes() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
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
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
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
        source.initialize(
            to: RuntimeCopyablePayload(
                life: RuntimeValueLife(deaths),
                text: String(repeating: "owned", count: 100)
            )
        )
        let copy = UnsafeMutableRawPointer.allocate(
            byteCount: layout.stride,
            alignment: layout.alignment
        )
        defer { source.deallocate(); copy.deallocate() }
        ABISwiftCopyValue(metadata, copy, source)
        ABISwiftDestroyValue(metadata, source)
        #expect(deaths.count.withLock { $0 } == 0)
        #expect(
            copy.load(as: RuntimeCopyablePayload.self).text
                == String(repeating: "owned", count: 100)
        )
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
        source.initialize(
            to: RuntimeMoveOnlyPayload(
                life: RuntimeValueLife(deaths),
                text: String(repeating: "moved", count: 100)
            )
        )
        let destination = UnsafeMutableRawPointer.allocate(
            byteCount: layout.stride,
            alignment: layout.alignment
        )
        destination.initializeMemory(as: UInt8.self, repeating: 0xa5, count: layout.stride)
        defer { source.deallocate(); destination.deallocate() }
        #expect(source.pointee.text == String(repeating: "moved", count: 100))
        ABISwiftTakeValue(metadata, destination, source)
        #expect(deaths.count.withLock { $0 } == 0)
        #expect(
            destination.assumingMemoryBound(to: RuntimeMoveOnlyPayload.self).pointee.text
                == String(repeating: "moved", count: 100)
        )
        ABISwiftDestroyValue(metadata, destination)
        #expect(deaths.count.withLock { $0 } == 1)
    }
}
