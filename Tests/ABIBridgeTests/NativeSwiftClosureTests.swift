import ABIBridgeRuntime
import ABIBridgeTestSupport
#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ABIBridgeCore
import CoreGraphics
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

private final class ClosureCounter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private final class ClosureCapture: Sendable {
    let destroyed: ClosureCounter
    let bias: Int64
    init(_ destroyed: ClosureCounter, bias: Int64 = 7) {
        self.destroyed = destroyed; self.bias = bias
    }
    deinit { destroyed.increment() }
}

private enum ClosureConversionError: Error { case rejected }
private struct RejectingClosureArgument: ABIBridgeValue {
    static let abiType = NativeType.int64
    init() {}
    init(nativeValue: NativeValue) throws { throw ClosureConversionError.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue {
        throw ClosureConversionError.rejected
    }
}

private final class ReentrantClosureCapture: Sendable {
    let destroyed: ClosureCounter
    init(_ destroyed: ClosureCounter) { self.destroyed = destroyed }
    deinit {
        do {
            let callback = try NativeSwiftClosure { Int64(42) }
            #expect(try unsafe callback.unsafeInvoke() == 42)
        } catch { Issue.record(error) }
        destroyed.increment()
    }
}

private final class NestedClosureCapture: @unchecked Sendable {
    var value: NativeSwiftClosure<(Int64) -> Int64>?
    var asyncValue: NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>?
}

struct NativeSwiftClosureTests {
    @MainActor @Test func resolvedMainActorClosurePreservesIsolationAcrossNativeParameters()
        async throws
    {
        typealias Isolated = NativeSwiftClosure<@MainActor (Int64) -> Int64>
        typealias Ordinary = NativeSwiftClosure<(Int64) -> Int64>
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeIsolatedIntegerClosure(_:)",
            as: ((Int64) -> NativeSwiftValue).self
        )
        let value = try unsafe make.unsafeInvoke(7)
        let closure = try await value.resolveClosure(as: (@MainActor (Int64) -> Int64).self)
        let apply = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyIsolatedIntegerClosure(_:_:)",
            as: ((Isolated, Int64) -> Int64).self
        )
        #expect(try unsafe apply.unsafeInvoke(closure, 35) == 42)
        await #expect(throws: ABIResolutionError.self) {
            try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.applyIntegerClosure(_:_:)",
                as: ((Isolated, Int64) -> Int64).self
            )
        }
        await #expect(throws: ABIResolutionError.self) {
            try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.applyIsolatedIntegerClosure(_:_:)",
                as: ((Ordinary, Int64) -> Int64).self
            )
        }
    }

    @Test func consumingDirectInputsRetainEscapingBorrows() async throws {
        typealias Inner = NativeSwiftClosure<(Int64) -> Int64>
        typealias Callback = NativeSwiftClosure<(Inner) throws -> Int64>
        let runtime = ABIRuntime.shared
        let visit = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitOwnedNestedClosure(_:_:)",
            as: ((Inner, Callback) throws -> Int64).self
        )
        let nativeConsume = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.consumeNestedClosure(_:)",
            as: ((NativeSwiftConsuming<Inner>) -> Int64).self
        )
        let destroyed = ClosureCounter()
        do {
            let capture = ClosureCapture(destroyed)
            let original = try Inner { $0 + capture.bias }
            let callback = try Callback { borrowed in
                let consume = try NativeSwiftClosure<(NativeSwiftConsuming<Inner>) throws -> Int64>
                { value in
                    try unsafe value.value.unsafeInvoke(35)
                }
                let consumed = try unsafe consume.unsafeInvoke(NativeSwiftConsuming(borrowed))
                #expect(consumed == 42)
                #expect(try unsafe nativeConsume.unsafeInvoke(NativeSwiftConsuming(borrowed)) == 42)
                return try unsafe borrowed.unsafeInvoke(35)
            }
            #expect(try unsafe visit.unsafeInvoke(original, callback) == 50)
            #expect(try unsafe original.unsafeInvoke(35) == 42)
        }
        #expect(destroyed.count == 1)

        let visitStack = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitNestedClosure(_:)",
            as: ((Callback) throws -> Int64).self
        )
        let entered = ClosureCounter()
        let callback = try Callback { borrowed in
            let reject = try NativeSwiftClosure<(NativeSwiftConsuming<Inner>) -> Void> { _ in
                entered.increment()
            }
            do {
                try unsafe reject.unsafeInvoke(NativeSwiftConsuming(borrowed))
                Issue.record("A consuming input accepted a nonescaping borrowed closure")
            } catch is ABIResolutionError {}
            return try unsafe borrowed.unsafeInvoke(35)
        }
        #expect(try unsafe visitStack.unsafeInvoke(callback) == 72)
        #expect(entered.count == 0)
    }

    @Test func consumingAsyncClosureInputsRetainEscapingBorrows() async throws {
        typealias Inner = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
        typealias Callback = NativeSwiftClosure<
            nonisolated(nonsending) (Inner) async throws -> Void
        >
        let visit = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitEscapingNestedAsyncClosure(_:)",
            as: (nonisolated(nonsending) (Callback) async throws -> Void).self
        )
        let callbackBody: nonisolated(nonsending) @Sendable (Inner) async throws -> Void = {
            borrowed in
            let consumeSynchronously = try NativeSwiftClosure<
                (NativeSwiftConsuming<Inner>) -> Int64
            > { _ in 42 }
            #expect(
                try unsafe consumeSynchronously.unsafeInvoke(NativeSwiftConsuming(borrowed)) == 42
            )
            let body:
                nonisolated(nonsending) @Sendable (NativeSwiftConsuming<Inner>) async throws ->
                    Int64 = { value in
                        await Task.yield()
                        return try unsafe await value.value.unsafeInvoke(35)
                    }
            let consume = try NativeSwiftClosure(body)
            #expect(try unsafe await consume.unsafeInvoke(NativeSwiftConsuming(borrowed)) == 42)
            #expect(try unsafe await borrowed.unsafeInvoke(1) == 43)
        }
        try unsafe await visit.unsafeInvoke(Callback(callbackBody))

        typealias StackCallback = NativeSwiftClosure<
            nonisolated(nonsending) (Inner) async throws -> Int64
        >
        let visitStack = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitNestedAsyncClosure(_:)",
            as: (nonisolated(nonsending) (StackCallback) async throws -> Int64).self
        )
        let entered = ClosureCounter()
        let stackBody: nonisolated(nonsending) @Sendable (Inner) async throws -> Int64 = {
            borrowed in
            let body:
                nonisolated(nonsending) @Sendable (NativeSwiftConsuming<Inner>) async -> Void = {
                    _ in
                    entered.increment()
                }
            let consume = try NativeSwiftClosure(body)
            await #expect(throws: ABIResolutionError.self) {
                try unsafe await consume.unsafeInvoke(NativeSwiftConsuming(borrowed))
            }
            return try unsafe await borrowed.unsafeInvoke(35)
        }
        #expect(try unsafe await visitStack.unsafeInvoke(StackCallback(stackBody)) == 72)
        #expect(entered.count == 0)
    }

    @Test func initializersBorrowNonescapingClosureArguments() async throws {
        typealias Inner = NativeSwiftClosure<(Int64) -> Int64>
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.EvaluatedIntegerClosure",
            as: EvaluatedIntegerClosure.self
        )
        let create = try await type.resolveInitializer(
            named: "init(_:)",
            as: ((Inner) -> EvaluatedIntegerClosure).self
        )
        let destroyed = ClosureCounter()
        do {
            let capture = ClosureCapture(destroyed)
            let callback = try Inner { $0 + capture.bias }
            #expect(try unsafe create.unsafeInvoke(callback).value == 42)
        }
        #expect(destroyed.count == 1)

        typealias Callback = NativeSwiftClosure<(Inner) throws -> Int64>
        let visit = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitNestedClosure(_:)",
            as: ((Callback) throws -> Int64).self
        )
        let callback = try Callback { borrowed in
            try unsafe create.unsafeInvoke(borrowed).value
        }
        #expect(try unsafe visit.unsafeInvoke(callback) == 72)
    }

    @Test func directHostCallsForwardNativeClosureArgumentsAndResults() async throws {
        typealias Inner = NativeSwiftClosure<(Int64) -> Int64>
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeNoncapturingClosure()",
            as: (() -> Inner).self
        )
        let makeGeneric = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeClosureGeneric<A>(A) -> (A) -> A",
            as: ((Int64) -> Inner).self,
            genericArguments: [.type(Int64.self)]
        )
        let receive = try NativeSwiftClosure<(Inner) throws -> Int64> { value in
            try unsafe value.unsafeInvoke(21)
        }
        let saved = NestedClosureCapture()
        let produce = try NativeSwiftClosure<() throws -> Inner> { saved.value! }
        for native in [try unsafe make.unsafeInvoke(), try unsafe makeGeneric.unsafeInvoke(42)] {
            #expect(try unsafe receive.unsafeInvoke(native) == 42)
            saved.value = native
            let returned = try unsafe produce.unsafeInvoke()
            #expect(try unsafe returned.unsafeInvoke(21) == 42)
        }
    }

    @Test func directSynchronousHostCallsForwardNativeAsyncClosures() async throws {
        typealias Inner = NativeSwiftClosure<
            nonisolated(nonsending) @Sendable (Int64) async -> Int64
        >
        final class Owner: @unchecked Sendable {
            let value: Inner
            init(_ value: Inner) { self.value = value }
        }
        let make = try await ABIRuntime.shared.resolveSwiftFunction(
            named:
                "ManagedSwiftFixtures.makeAsyncClosureGeneric<A where A: Swift.Sendable>(A) -> nonisolated(nonsending) @Sendable (A) async -> A",
            as: ((Int64) -> Inner).self,
            genericArguments: [.type(Int64.self)]
        )
        let owner = Owner(try unsafe make.unsafeInvoke(42))
        let receive = try NativeSwiftClosure<(Inner) -> Int64> { _ in 42 }
        #expect(try unsafe receive.unsafeInvoke(owner.value) == 42)
        let produce = try NativeSwiftClosure<() throws -> Inner> { owner.value }
        let returned = try unsafe produce.unsafeInvoke()
        #expect(try unsafe await returned.unsafeInvoke(21) == 42)
    }

    @Test func nativeNestedResultsOwnTheirCaptureAfterBothOuterCallsReturn() async throws {
        typealias Inner = NativeSwiftClosure<(Int64) -> Int64>
        typealias Producer = NativeSwiftClosure<() -> Inner>
        let runtime = ABIRuntime.shared
        let factory = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeRetainedConcreteNestedProducer(_:)",
            as: ((NativeSwiftClosure<() -> Void>) -> Producer).self
        )
        let take = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.takeNestedRuntimeProducer<A>(() -> (A) -> A) -> (A) -> A",
            as: ((Producer) -> Inner).self,
            genericArguments: [.type(Int64.self)]
        )
        let destroyed = ClosureCounter()
        do {
            var returned: Inner?
            do {
                let onDestroy = try NativeSwiftClosure { destroyed.increment() }
                let producer = try unsafe factory.unsafeInvoke(onDestroy)
                returned = try unsafe take.unsafeInvoke(producer)
            }
            #expect(destroyed.count == 0)
            let copied = try returned!.copy()
            returned = nil
            #expect(try unsafe copied.unsafeInvoke(35) == 42)
            #expect(destroyed.count == 0)
        }
        #expect(destroyed.count == 1)
    }

    @Test func nativeNestedAsyncResultsUsePreparedAdapters() async throws {
        let runtime = ABIRuntime.shared
        typealias Inner = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
        typealias Producer = NativeSwiftClosure<nonisolated(nonsending) () async -> Inner>
        let factory = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeConcreteNestedAsyncProducer()",
            as: (() -> Producer).self
        )
        let call = try await runtime.resolveSwiftFunction(
            named:
                "ManagedSwiftFixtures.callNestedRuntimeAsyncProducer<A>(nonisolated(nonsending) () async -> nonisolated(nonsending) (A) async -> A, A) async -> A",
            as: (nonisolated(nonsending) (Producer, Int64) async -> Int64).self,
            genericArguments: [.type(Int64.self)]
        )
        let producer = try unsafe factory.unsafeInvoke()
        #expect(try unsafe await call.unsafeInvoke(producer, 35) == 42)
    }

    @Test func nativeNestedPackInputsUsePreparedAdapters() async throws {
        let runtime = ABIRuntime.shared
        typealias PackInner = NativeSwiftClosure<(Int64, String) -> Int64>
        typealias Caller = NativeSwiftClosure<(PackInner, Int64, String) -> Int64>
        let packFactory = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeConcreteNestedPackCaller()",
            as: (() -> Caller).self
        )
        let packCall = try await runtime.resolveSwiftFunction(
            named:
                "ManagedSwiftFixtures.callNestedRuntimePackCaller<each A>(_: repeat A, body: ((repeat A) -> Swift.Int64, repeat A) -> Swift.Int64) -> Swift.Int64",
            as: ((Int64, String, Caller) -> Int64).self,
            genericArguments: [.pack([.type(Int64.self), .type(String.self)])]
        )
        let caller = try unsafe packFactory.unsafeInvoke()
        #expect(try unsafe packCall.unsafeInvoke(35, "pack", caller) == 42)
    }

    @Test func nativeNestedClosuresReabstractGenericInputsAndResultsInBothDirections() async throws
    {
        let runtime = ABIRuntime.shared
        typealias Inner = NativeSwiftClosure<(Int64) -> Int64>
        typealias Caller = NativeSwiftClosure<(Inner, Int64) -> Int64>
        typealias Producer = NativeSwiftClosure<() -> Inner>
        let concreteFactory = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeConcreteNestedCaller()",
            as: (() -> Caller).self
        )
        let genericCall = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.callNestedRuntimeCaller<A>(((A) -> A, A) -> A, A) -> A",
            as: ((Caller, Int64) -> Int64).self,
            genericArguments: [.type(Int64.self)]
        )
        let concrete = try unsafe concreteFactory.unsafeInvoke()
        #expect(try unsafe genericCall.unsafeInvoke(concrete, 42) == 42)
        let genericFactory = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeNestedRuntimeCaller<A>(A.Type) -> ((A) -> A, A) -> A",
            as: ((Int64.Type) -> Caller).self,
            genericArguments: [.type(Int64.self)]
        )
        let concreteCall = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.callConcreteNestedCaller(_:)",
            as: ((Caller) -> Int64).self
        )
        let generic = try unsafe genericFactory.unsafeInvoke(Int64.self)
        #expect(try unsafe concreteCall.unsafeInvoke(generic) == 42)
        let concreteProducerFactory = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeConcreteNestedProducer()",
            as: (() -> Producer).self
        )
        let genericProduce = try await runtime.resolveSwiftFunction(
            named:
                "ManagedSwiftFixtures.callNonthrowingNestedRuntimeProducer<A>(() -> (A) -> A, A) -> A",
            as: ((Producer, Int64) -> Int64).self,
            genericArguments: [.type(Int64.self)]
        )
        #expect(
            try unsafe genericProduce.unsafeInvoke(concreteProducerFactory.unsafeInvoke(), 35) == 42
        )
        let genericProducerFactory = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeNestedRuntimeProducer<A>(A.Type) -> () -> (A) -> A",
            as: ((Int64.Type) -> Producer).self,
            genericArguments: [.type(Int64.self)]
        )
        let concreteProduce = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.callConcreteNestedProducer(_:)",
            as: ((Producer) -> Int64).self
        )
        #expect(
            try unsafe concreteProduce.unsafeInvoke(genericProducerFactory.unsafeInvoke(Int64.self))
                == 42
        )
    }

    @Test func nativeNestedAsyncClosuresReabstractGenericInputsInBothDirections() async throws {
        let runtime = ABIRuntime.shared
        typealias Inner = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
        typealias Caller = NativeSwiftClosure<nonisolated(nonsending) (Inner, Int64) async -> Int64>
        let concreteFactory = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeConcreteNestedAsyncCaller()",
            as: (() -> Caller).self
        )
        let genericCall = try await runtime.resolveSwiftFunction(
            named:
                "ManagedSwiftFixtures.callNestedRuntimeAsyncCaller<A>(nonisolated(nonsending) (nonisolated(nonsending) (A) async -> A, A) async -> A, A) async -> A",
            as: (nonisolated(nonsending) (Caller, Int64) async -> Int64).self,
            genericArguments: [.type(Int64.self)]
        )
        let concrete = try unsafe concreteFactory.unsafeInvoke()
        #expect(try unsafe await genericCall.unsafeInvoke(concrete, 42) == 42)
        let genericFactory = try await runtime.resolveSwiftFunction(
            named:
                "ManagedSwiftFixtures.makeNestedRuntimeAsyncCaller<A>(A.Type) -> nonisolated(nonsending) (nonisolated(nonsending) (A) async -> A, A) async -> A",
            as: ((Int64.Type) -> Caller).self,
            genericArguments: [.type(Int64.self)]
        )
        let concreteCall = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.callConcreteNestedAsyncCaller(_:)",
            as: (nonisolated(nonsending) (Caller) async -> Int64).self
        )
        let generic = try unsafe genericFactory.unsafeInvoke(Int64.self)
        #expect(try unsafe await concreteCall.unsafeInvoke(generic) == 42)
    }

    @Test func escapingNestedInputsCanBeCopiedBeyondTheirCallback() async throws {
        typealias Nested = NativeSwiftClosure<(Int64) -> Int64>
        typealias Callback = NativeSwiftClosure<(Nested) throws -> Void>
        let visit = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitEscapingNestedClosure(_:)",
            as: ((Callback) throws -> Void).self
        )
        let borrowed = NestedClosureCapture(), owned = NestedClosureCapture()
        let callback = try Callback { value in
            borrowed.value = value
            owned.value = try value.copy()
        }
        try unsafe visit.unsafeInvoke(callback)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe borrowed.value!.unsafeInvoke(35)
        }
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try borrowed.value!.copy() }
        #expect(try unsafe owned.value!.unsafeInvoke(35) == 42)
        let copiedAgain = try owned.value!.copy()
        owned.value = nil
        #expect(try unsafe copiedAgain.unsafeInvoke(8) == 50)
        let echo = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.echoClosure(_:)",
            as: ((Nested) -> Nested).self
        )
        let returned = try unsafe echo.unsafeInvoke(copiedAgain)
        #expect(try unsafe returned.unsafeInvoke(1) == 51)
    }

    @Test func escapingNestedAsyncInputsCanBeCopiedAfterSuspension() async throws {
        typealias Nested = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
        typealias Callback = NativeSwiftClosure<
            nonisolated(nonsending) (Nested) async throws -> Void
        >
        let visit = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitEscapingNestedAsyncClosure(_:)",
            as: (nonisolated(nonsending) (Callback) async throws -> Void).self
        )
        let borrowed = NestedClosureCapture(), owned = NestedClosureCapture()
        let body: nonisolated(nonsending) @Sendable (Nested) async throws -> Void = { value in
            borrowed.asyncValue = value
            await Task.yield()
            owned.asyncValue = try value.copy()
        }
        try unsafe await visit.unsafeInvoke(Callback(body))
        await #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe await borrowed.asyncValue!.unsafeInvoke(35)
        }
        #expect(try unsafe await owned.asyncValue!.unsafeInvoke(35) == 42)
        let copiedAgain = try owned.asyncValue!.copy()
        owned.asyncValue = nil
        #expect(try unsafe await copiedAgain.unsafeInvoke(8) == 50)
    }

    @Test func nestedInputsBorrowStackContextsAndExpireAfterReturn() async throws {
        typealias Inner = NativeSwiftClosure<(Int64) -> Int64>
        let apply = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyIntegerClosure(_:_:)",
            as: ((Inner, Int64) -> Int64).self
        )
        let echo = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.echoClosure(_:)",
            as: ((Inner) -> Inner).self
        )
        let visit = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitNestedClosure(_:)",
            as: ((NativeSwiftClosure<(NativeSwiftClosure<(Int64) -> Int64>) throws -> Int64>) throws
                -> Int64).self
        )
        let saved = NestedClosureCapture()
        let callback = try NativeSwiftClosure<
            (NativeSwiftClosure<(Int64) -> Int64>) throws -> Int64
        > { value in
            saved.value = value
            #expect(throws: ABIResolutionError.self) { try value.copy() }
            #expect(throws: ABIResolutionError.self) { try unsafe echo.unsafeInvoke(value) }
            return try unsafe apply.unsafeInvoke(value, 20)
        }
        #expect(try unsafe visit.unsafeInvoke(callback) == 42)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe saved.value!.unsafeInvoke(1)
        }
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try saved.value!.copy() }
    }

    @Test func nestedAsyncInputsKeepTheirNativeScopeAcrossAwait() async throws {
        typealias Nested = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
        typealias Callback = NativeSwiftClosure<
            nonisolated(nonsending) (Nested) async throws -> Int64
        >
        let visit = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitNestedAsyncClosure(_:)",
            as: (nonisolated(nonsending) (Callback) async throws -> Int64).self
        )
        let saved = NestedClosureCapture()
        let body: nonisolated(nonsending) @Sendable (Nested) async throws -> Int64 = { value in
            saved.asyncValue = value
            await Task.yield()
            return try unsafe await value.unsafeInvoke(20)
        }
        let callback = try Callback(body)
        #expect(try unsafe await visit.unsafeInvoke(callback) == 42)
        await #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe await saved.asyncValue!.unsafeInvoke(1)
        }
    }

    @Test @MainActor func forwardingBorrowedClosuresUsesTheReceivingCallsSuspensionContract()
        async throws
    {
        guard #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else { return }
        typealias Sync = NativeSwiftClosure<(Int64) -> Int64>
        typealias Async = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
        let runtime = ABIRuntime.shared
        let visitSync = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitClosureSynchronously(_:)",
            as: ((NativeSwiftClosure<(Sync) -> Void>) -> Void).self
        )
        let visitAsync = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitAsyncClosureSynchronously(_:)",
            as: ((NativeSwiftClosure<(Async) -> Void>) -> Void).self
        )
        let forwardSync = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyBorrowedClosureAsync(_:_:)",
            as: (nonisolated(nonsending) (Sync, Int64) async -> Int64).self
        )
        let forwardAsync = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyBorrowedAsyncClosure(_:_:)",
            as: (nonisolated(nonsending) (Async, Int64) async -> Int64).self
        )
        let inspect = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.inspectAsyncClosureSynchronously(_:)",
            as: ((Async) -> Int64).self
        )
        var syncTask: Task<Int64, any Error>?
        try unsafe NativeSwiftClosure<(Sync) -> Void>.withUnsafeNonescaping({ value in
            syncTask = Task.immediate { @MainActor in
                try unsafe await forwardSync.unsafeInvoke(value, 20)
            }
        }) { try unsafe visitSync.unsafeInvoke($0) }
        await #expect(throws: NativeSwiftBorrowError.synchronousBorrow) {
            try await syncTask!.value
        }
        var asyncTask: Task<Int64, any Error>?
        var directTask: Task<Int64, any Error>?
        let directBody: nonisolated(nonsending) @Sendable (Async, Int64) async throws -> Int64 = {
            value,
            number in
            try unsafe await value.unsafeInvoke(number)
        }
        let direct = try NativeSwiftClosure<
            nonisolated(nonsending) (Async, Int64) async throws -> Int64
        >(directBody)
        try unsafe NativeSwiftClosure<(Async) -> Void>.withUnsafeNonescaping({ value in
            do { #expect(try unsafe inspect.unsafeInvoke(value) == 42) } catch {
                Issue.record(error)
            }
            asyncTask = Task.immediate { @MainActor in
                try unsafe await forwardAsync.unsafeInvoke(value, 20)
            }
            directTask = Task.immediate { @MainActor in
                try unsafe await direct.unsafeInvoke(value, 20)
            }
        }) { try unsafe visitAsync.unsafeInvoke($0) }
        await #expect(throws: NativeSwiftBorrowError.synchronousBorrow) {
            try await asyncTask!.value
        }
        await #expect(throws: NativeSwiftBorrowError.synchronousBorrow) {
            try await directTask!.value
        }

        typealias Callback = NativeSwiftClosure<
            nonisolated(nonsending) (Async) async throws -> Int64
        >
        let visitSuspending = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitNestedAsyncClosure(_:)",
            as: (nonisolated(nonsending) (Callback) async throws -> Int64).self
        )
        let body: nonisolated(nonsending) @Sendable (Async) async throws -> Int64 = { value in
            try unsafe await forwardAsync.unsafeInvoke(value, 20)
        }
        #expect(try unsafe await visitSuspending.unsafeInvoke(Callback(body)) == 42)
        let forwardSyncBody: nonisolated(nonsending) @Sendable (Sync) async throws -> Int64 = {
            value in
            try unsafe await forwardSync.unsafeInvoke(value, 20)
        }
        let receiveSync = try NativeSwiftClosure<
            nonisolated(nonsending) (Sync) async throws -> Int64
        >(forwardSyncBody)
        #expect(try unsafe await receiveSync.unsafeInvoke(Sync { $0 + 22 }) == 42)
    }

    @Test func nestedResultsTransferOwnedContextsToTheNativeCaller() async throws {
        let call = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.callClosureProducer(_:)",
            as: ((NativeSwiftClosure<() throws -> NativeSwiftClosure<(Int64) -> Int64>>) throws
                -> Int64).self
        )
        let destroyed = ClosureCounter()
        let producer = try NativeSwiftClosure<() throws -> NativeSwiftClosure<(Int64) -> Int64>> {
            let capture = ClosureCapture(destroyed)
            return try NativeSwiftClosure { (value: Int64) in value + capture.bias }
        }
        #expect(try unsafe call.unsafeInvoke(producer) == 42)
        #expect(destroyed.count == 1)
    }

    @Test func nonescapingConstructionInfersTheOrdinarySignature() throws {
        let result = try unsafe NativeSwiftClosure.withUnsafeNonescaping({ (value: Int64) in
            value + 7
        }) {
            try unsafe $0.unsafeInvoke(35)
        }
        #expect(result == 42)
    }

    @Test func sendableNonescapingSignaturePreservesItsTypedBody() throws {
        let result = try unsafe NativeSwiftClosure<@Sendable (Int64) -> Int64>
            .withUnsafeNonescaping({ $0 + 7 }) {
                try unsafe $0.unsafeInvoke(35)
            }
        #expect(result == 42)
    }

    @Test func callbackPageReuseReleasesCapturesAndPermitsDestructionReentry() throws {
        let destroyed = ClosureCounter()
        for expected in 1...128 {
            do {
                let capture = ReentrantClosureCapture(destroyed)
                let callback = try NativeSwiftClosure { [capture] in
                    withExtendedLifetime(capture) { Int64(42) }
                }
                #expect(try unsafe callback.unsafeInvoke() == 42)
            }
            #expect(destroyed.count == expected)
        }
    }

    @Test func manyCallbacksKeepIndependentContextsWithSharedEntries() throws {
        let destroyed = ClosureCounter()
        var callbacks: [NativeSwiftClosure<(Int64) -> Int64>] = []
        for index in 0..<1100 {
            let capture = ClosureCapture(destroyed, bias: Int64(index))
            callbacks.append(try NativeSwiftClosure { (value: Int64) in value + capture.bias })
        }
        for index in callbacks.indices {
            #expect(try unsafe callbacks[index].unsafeInvoke(1) == Int64(index + 1))
        }
        callbacks.removeFirst(1000)
        #expect(destroyed.count == 1000)
        for index in callbacks.indices {
            #expect(try unsafe callbacks[index].unsafeInvoke(2) == Int64(index + 1002))
        }
        callbacks.removeAll()
        #expect(destroyed.count == 1100)
        let next = try NativeSwiftClosure { Int64(7) }
        #expect(try unsafe next.unsafeInvoke() == 7)
    }

    @Test func concurrentCallbackCreationAndReleaseKeepBodiesIndependent() async throws {
        let total = try await withThrowingTaskGroup(of: Int64.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    var sum: Int64 = 0
                    for index in 0..<128 {
                        let value = Int64(worker * 128 + index)
                        let callback = try NativeSwiftClosure { value }
                        sum += try unsafe callback.unsafeInvoke()
                    }
                    return sum
                }
            }
            var total: Int64 = 0
            for try await value in group { total += value }
            return total
        }
        #expect(total == 1023 * 1024 / 2)
    }

    @Test func sendableNativeCallersCanInvokeOneContextConcurrently() async throws {
        let apply = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyConcurrentClosure(_:)",
            as: ((NativeSwiftClosure<@Sendable (Int64) -> Int64>) -> Int64).self
        )
        let calls = ClosureCounter()
        let callback = try NativeSwiftClosure<@Sendable (Int64) -> Int64> { value in
            calls.increment(); return value + 7
        }
        #expect(try unsafe apply.unsafeInvoke(callback) == 2464)
        #expect(calls.count == 64)
    }

    @Test func builtInRepresentationsRoundTripThroughGeneratedEntries() throws {
        func check<Value: Equatable>(_ value: Value) throws {
            let callback = try NativeSwiftClosure<(Value) -> Value> { $0 }
            #expect(try unsafe callback.unsafeInvoke(value) == value)
        }
        try check(true); try check(false)
        try check(Int8(-7)); try check(UInt8(250))
        try check(Int16(-300)); try check(UInt16(60_000))
        try check(Int32(-70_000)); try check(UInt32(4_000_000_000))
        try check(Int64(-5_000_000_000)); try check(UInt64.max)
        try check(Int(-42)); try check(UInt(42))
        try check(Float(1.25)); try check(Double(2.5)); try check(CGFloat(3.75))
        try check(String(repeating: "value", count: 100))
        try check(CGPoint(x: 1, y: 2)); try check(CGSize(width: 3, height: 4))
        try check(CGRect(x: 1, y: 2, width: 3, height: 4));
        try check(NSRange(location: 5, length: 6))
        try check(NSSelectorFromString("description"))
        var number: Int64 = 42
        try withUnsafeMutablePointer(to: &number) { pointer in
            try check(pointer); try check(UnsafePointer(pointer))
            try check(UnsafeRawPointer(pointer)); try check(UnsafeMutableRawPointer(pointer))
            try check(OpaquePointer(pointer)); try check(Optional(pointer))
        }
        try check(UnsafeRawPointer?.none)
    }

    #if DEBUG && os(macOS)
    @Test func builtInAuthenticationMatchesNativeCompilerCalls() throws {
        let cases: [(Any.Type, String)] = [
            (Bool.self, "Bool"), (Int8.self, "Int8"), (UInt8.self, "UInt8"),
            (Int16.self, "Int16"), (UInt16.self, "UInt16"),
            (Int32.self, "Int32"), (UInt32.self, "UInt32"),
            (Int64.self, "Int64"), (UInt64.self, "UInt64"),
            (Int.self, "Int"), (UInt.self, "UInt"),
            (Float.self, "Float"), (Double.self, "Double"), (CGFloat.self, "CGFloat"),
            (String.self, "String"), (AnyObject.self, "AnyObject"),
            (NSObject?.self, "NSObject?"), (Selector.self, "Selector"),
            (CGPoint.self, "CGPoint"), (CGSize.self, "CGSize"), (CGRect.self, "CGRect"),
            (NSRange.self, "NSRange"), (UnsafeRawPointer.self, "UnsafeRawPointer"),
            (UnsafeMutableRawPointer?.self, "UnsafeMutableRawPointer?"),
            (UnsafePointer<Int64>.self, "UnsafePointer<Int64>"),
            (UnsafeMutablePointer<UInt8>?.self, "UnsafeMutablePointer<UInt8>?"),
            (OpaquePointer?.self, "OpaquePointer?"),
            (Unmanaged<NSObject>.self, "Unmanaged<NSObject>"),
            (Unmanaged<NSString>.self, "Unmanaged<NSString>"),
            (Unmanaged<NSObject>?.self, "Unmanaged<NSObject>?"),
            (Unmanaged<CFString>?.self, "Unmanaged<CFString>?"),
            ([String].self, "[String]"), ([Int].self, "[Int]"),
            ([[String?]].self, "[[String?]]"), ([String]?.self, "[String]?"),
            (String?.self, "String?"),
        ]
        let declarations = cases.enumerated().map { index, entry in
            "@inline(never) public func closureProbe\(index)(_ callback: (\(entry.1)) -> \(entry.1), _ value: \(entry.1)) -> \(entry.1) { callback(value) }"
        }.joined(separator: "\n")
        let found = try arm64eClosureCallDiscriminators(
            source: "import Foundation\nimport CoreGraphics\n" + declarations,
            functions: cases.indices.map { "closureProbe\($0)" }
        )
        for (entry, expected) in zip(cases, found) {
            let name = try swiftClosureAuthType(entry.0, position: .parameter)
            #expect(
                swiftClosureDiscriminator(parameters: [name], result: name) == expected,
                "\(entry.1)"
            )
        }
    }

    /// An inferred struct hashes as `-indirect` when it passes by address,
    /// and otherwise as its declaration, both for a host value of its own
    /// type and for a declaration's closure plan. A declaration hashes
    /// without generic arguments, and one in a constrained extension includes
    /// the extension's generic signature, which runtime type names omit;
    /// inference leaves such generic instances undecided, so only their names
    /// are checked. A tuple result's element is hashed by its type unless it
    /// is formally indirect.
    @Test(arguments: [false, true])
    func inferredAuthenticationMatchesNativeCompilerCalls(evolution: Bool) async throws {
        let inferred = ["AuthPoint", "AuthWide", "AuthOpen"]
        // These pass directly. With library evolution, the compiler passes
        // the resilient ones by address, which their names do not show.
        let named =
            ["ClosedRange<Int>.Index"]
            + (evolution
                ? []
                : [
                    "AuthPair<Double>", "AuthPair<Int8>", "AuthBox<Int>.Inner",
                    "AuthBox<Int>.Inner.Deep", "AuthBox<Int>.Kind", "AuthBox<Int>.Same",
                ])
        let types = inferred + named
        let module = "ClosureAuth_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source =
            """
            // Its String field sets the addressable bit, so the module's clear
            // bits certify its other types.
            public struct AuthLabel {
                public var text: String
                public init() { text = "label" }
            }
            @frozen public struct AuthPoint {
                public var x: Double, y: Double
                public init() { x = 1; y = 2 }
            }
            @frozen public struct AuthWide {
                public var a: Int64, b: Int64, c: Int64, d: Int64, e: Int64
                public init() { a = 1; b = 2; c = 3; d = 4; e = 5 }
            }
            public struct AuthOpen {
                public var x: Double, y: Double
                public init() { x = 1; y = 2 }
            }
            @frozen public struct AuthPair<T> {
                public var a: T, b: T
            }
            public struct AuthBox<T> {}
            extension AuthBox where T: Equatable {
                public struct Inner {
                    public var x: Double, y: Double
                    public struct Deep { public var x: Double, y: Double }
                }
                public enum Kind { case real(Double), none }
            }
            extension AuthBox where T == Int {
                public struct Same { public var x: Double, y: Double }
            }
            public func closureProbeType(_ index: Int64) -> Any.Type {
                let types: [Any.Type] = [\(types.map { $0 + ".self" }.joined(separator: ", "))]
                return types[Int(index)]
            }
            public func closureProbeTupleType() -> Any.Type { (AuthWide, Int64).self }
            @inline(never) public func closureProbeTuple(_ callback: () -> (AuthWide, Int64)) -> Int64 { callback().1 }
            public func closureProbeOpenTupleType() -> Any.Type { (AuthOpen, Int64).self }
            @inline(never) public func closureProbeOpenTuple(_ callback: () -> (AuthOpen, Int64)) -> Int64 { callback().1 }

            """
            + types.enumerated().map { index, type in
                "@inline(never) public func closureProbe\(index)(_ callback: (\(type)) -> \(type), _ value: \(type)) -> \(type) { callback(value) }"
            }.joined(separator: "\n")
        let flags = evolution ? ["-enable-library-evolution"] : []
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: source,
            linkArguments: ["-parse-as-library", "-swift-version", "6"] + flags
        )
        defer { library.cleanup() }
        let found = try arm64eClosureCallDiscriminators(
            source: source,
            arguments: ["-module-name", module] + flags,
            functions: types.indices.map { "closureProbe\($0)" } + [
                "closureProbeTuple", "closureProbeOpenTuple",
            ]
        )
        let runtime = ABIRuntime()
        let typeAt = try await runtime.resolveSwiftFunction(
            named: module + ".closureProbeType(_:)",
            as: ((Int64) -> Any.Type).self,
            in: .path(library.libraryURL)
        )
        // A relative name does not find every declaration whose signature
        // names a type of a constrained extension, such as
        // `ClosedRange<Int>.Index`.
        let exports = try library.exportedSymbols()
        func completeName(_ function: String) throws -> String {
            let symbol = try #require(
                exports.first { $0.contains("\(function.utf8.count)\(function)y") }
            )
            return try #require(
                DeclarationKey.demangle(String(symbol.dropFirst()), language: .swift)
            )
        }
        for (index, (name, expected)) in zip(types, found).enumerated() {
            let type = try unsafe typeAt.unsafeInvoke(Int64(index))
            guard index < inferred.count else {
                let hash = try swiftClosureTypeHash(type)
                #expect(
                    swiftClosureDiscriminator(parameters: [hash], result: hash) == expected,
                    "\(name)"
                )
                continue
            }
            let host = swiftClosureDiscriminator(
                parameters: [try swiftClosureAuthType(type, position: .parameter)],
                result: try swiftClosureAuthType(type, position: .result)
            )
            #expect(host == expected, "\(name)")
            let probe = try await runtime.resolveSwiftFunction(
                named: try completeName("closureProbe\(index)"),
                as: ((NativeSwiftClosure<(NativeSwiftValue) -> NativeSwiftValue>, NativeSwiftValue) ->
                    NativeSwiftValue).self,
                in: .path(library.libraryURL)
            )
            guard case .closure(let plan, _) = try #require(probe.call.generic).parameters.arguments[0]
            else {
                Issue.record("\(name) has no closure plan")
                continue
            }
            #expect(
                swiftClosureDiscriminator(description: plan.authentication) == expected,
                "\(name)"
            )
        }
        // AuthWide passes by address as a whole result, but a tuple result
        // keeps it as a direct SIL result that shares one return buffer.
        let tupleType = try await runtime.resolveSwiftFunction(
            named: module + ".closureProbeTupleType()",
            as: (() -> Any.Type).self,
            in: .path(library.libraryURL)
        )
        let expected = found[types.count]
        #expect(
            swiftClosureDiscriminator(
                parameters: [],
                results: try swiftClosureAuthTypes(
                    unsafe tupleType.unsafeInvoke(),
                    position: .result
                )
            ) == expected
        )
        // An explicit layout of the element follows the same rule.
        let wide = try await runtime.resolveSwiftType(
            named: module + ".AuthWide",
            in: .path(library.libraryURL)
        )
        let wideABI = try NativeType.structure(
            named: "AuthWide",
            fields: Array(repeating: .int64, count: 5)
        )
        for valueABIs: [NativeSwiftType: NativeType] in [[:], [wide: wideABI]] {
            let probe = try await runtime.resolveSwiftFunction(
                named: module + ".closureProbeTuple(_:)",
                as: ((NativeSwiftClosure<() -> NativeSwiftValue>) -> Int64).self,
                valueABIs: valueABIs,
                in: .path(library.libraryURL)
            )
            let arguments = try #require(probe.call.generic).parameters.arguments
            guard case .closure(let plan, _) = arguments[0] else {
                Issue.record("closureProbeTuple has no closure plan")
                continue
            }
            #expect(
                swiftClosureDiscriminator(description: plan.authentication) == expected,
                "valueABIs: \(valueABIs.count)"
            )
        }
        // A resilient element is formally indirect, so it hashes as
        // `-indirect`, as does an opaque layout of it.
        let openTupleType = try await runtime.resolveSwiftFunction(
            named: module + ".closureProbeOpenTupleType()",
            as: (() -> Any.Type).self,
            in: .path(library.libraryURL)
        )
        let openExpected = found[types.count + 1]
        #expect(
            swiftClosureDiscriminator(
                parameters: [],
                results: try swiftClosureAuthTypes(
                    unsafe openTupleType.unsafeInvoke(),
                    position: .result
                )
            ) == openExpected
        )
        let open = try await runtime.resolveSwiftType(
            named: module + ".AuthOpen",
            in: .path(library.libraryURL)
        )
        let openABIs: [[NativeSwiftType: NativeType]] =
            evolution ? [[:], [open: try .opaque(named: "AuthOpen")]] : [[:]]
        for valueABIs in openABIs {
            let probe = try await runtime.resolveSwiftFunction(
                named: module + ".closureProbeOpenTuple(_:)",
                as: ((NativeSwiftClosure<() -> NativeSwiftValue>) -> Int64).self,
                valueABIs: valueABIs,
                in: .path(library.libraryURL)
            )
            let arguments = try #require(probe.call.generic).parameters.arguments
            guard case .closure(let plan, _) = arguments[0] else {
                Issue.record("closureProbeOpenTuple has no closure plan")
                continue
            }
            #expect(
                swiftClosureDiscriminator(description: plan.authentication) == openExpected,
                "open valueABIs: \(valueABIs.count)"
            )
        }
    }

    /// A type declared in an unconstrained extension of another module's
    /// type hashes as its runtime name, which includes the extension and has
    /// no generic signature to omit, whether or not its image exports its
    /// descriptor. On arm64e, one in a constrained extension needs that
    /// descriptor.
    @Test func unexportedTypesInExtensionsHashByTheirRuntimeNames() async throws {
        let module = "ClosureExtension_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source = """
            // A String field sets the addressable bit, which Helper leaves clear.
            public struct Label { public var text: String = "" }
            extension Int {
                struct Helper { var x: Double, y: Double }
            }
            extension Array {
                struct Foreign { var a: Int64, b: Int64 }
            }
            // Repeats Dictionary's own requirement on Key.
            extension Dictionary {
                struct Entry { var a: Int64, b: Int64 }
            }
            public struct Box<T> {}
            extension Box where T: Equatable {
                struct Hidden { var x: Double, y: Double }
            }
            public protocol Base {}
            public protocol Refined: Base {}
            extension Int: Refined {}
            public struct Bounded<T: Base> {}
            // As many requirements as Bounded, but a different one.
            extension Bounded where T: Refined {
                struct Narrow { var x: Double, y: Double }
            }
            func closureProbeType(_ index: Int64) -> Any.Type {
                [Int.Helper.self, Box<Int>.Hidden.self, Bounded<Int>.Narrow.self][Int(index)]
            }
            @inline(never) func closureProbeHelper(_ callback: (Int.Helper) -> Double) -> Double {
                callback(.init(x: 1, y: 2))
            }
            @inline(never) func closureProbeForeign(_ callback: ([Int].Foreign) -> Int64) -> Int64 {
                callback(.init(a: 3, b: 4))
            }
            @inline(never) func closureProbeEntry(_ callback: ([Int: Int].Entry) -> Int64) -> Int64 {
                callback(.init(a: 5, b: 6))
            }
            """
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: source,
            linkArguments: ["-parse-as-library", "-swift-version", "6"]
        )
        defer { library.cleanup() }
        let found = try arm64eClosureCallDiscriminators(
            source: source,
            arguments: ["-module-name", module],
            functions: ["closureProbeHelper", "closureProbeForeign", "closureProbeEntry"]
        )
        let runtime = ABIRuntime()
        let typeAt = try await runtime.resolveSwiftFunction(
            named: module + ".closureProbeType(_:)",
            as: ((Int64) -> Any.Type).self,
            in: .path(library.libraryURL)
        )
        let helper = try swiftClosureAuthType(unsafe typeAt.unsafeInvoke(0), position: .parameter)
        #expect(swiftClosureDiscriminator(parameters: [helper], result: "$sSd") == found[0])
        let inferred = try await runtime.resolveSwiftFunction(
            named: module + ".closureProbeHelper(_:)",
            as: ((NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Double>) -> Double).self,
            in: .path(library.libraryURL)
        )
        // Inference leaves generic structs that are not public undecided, so
        // they take explicit layouts.
        let pair = try NativeType.structure(named: "Pair", fields: [.int64, .int64])
        var calls = [inferred.call]
        for (name, function, arguments) in [
            ("Array.Foreign", "closureProbeForeign(_:)", [NativeSwiftGenericArgument.type(Int.self)]),
            ("Dictionary.Entry", "closureProbeEntry(_:)", [.type(Int.self), .type(Int.self)]),
        ] {
            let type = try await runtime.resolveSwiftType(
                named: "(extension in \(module)):Swift.\(name)",
                in: .path(library.libraryURL),
                genericArguments: arguments
            )
            calls.append(
                try await runtime.resolveSwiftFunction(
                    named: "\(module).\(function)",
                    as: ((NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Int64>) -> Int64).self,
                    valueABIs: [type: pair],
                    in: .path(library.libraryURL)
                ).call
            )
        }
        for (index, call) in calls.enumerated() {
            guard case .closure(let plan, _) = try #require(call.generic).parameters.arguments[0]
            else {
                Issue.record("probe \(index) has no closure plan")
                continue
            }
            #expect(
                swiftClosureDiscriminator(description: plan.authentication) == found[index],
                "probe \(index)"
            )
        }
        // Their conventions are undecided, so only their names are hashed.
        for index: Int64 in [1, 2] {
            let type = try unsafe typeAt.unsafeInvoke(index)
            guard RuntimePointerAuthentication.isEnabled else {
                // Only arm64e hashes the declaration; elsewhere the runtime
                // name identifies the type.
                #expect(try swiftClosureTypeHash(type) == "$s" + _mangledTypeName(type)!)
                continue
            }
            #expect {
                _ = try swiftClosureTypeHash(type)
            } throws: { error in
                guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                    return false
                }
                return message.contains("it is declared in a constrained extension")
            }
        }
    }
    #endif

    #if os(macOS)
    /// Only arm64e signs a closure with a discriminator, which hashes the
    /// declaration of each type in the closure's signature. Other
    /// architectures prepare a closure over a type in a constrained extension
    /// even when its image does not export the type's descriptor.
    @Test func closuresOverTypesInConstrainedExtensionsPrepare() async throws {
        let module =
            "ClosureConstrained_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source = """
            public struct Box<T> {}
            extension Box where T: Equatable {
                struct Hidden { var x: Double, y: Double }
            }
            // Requirement records omit conformances to marker protocols.
            extension Box where T: Sendable {
                struct Marked { var x: Double, y: Double }
            }
            @inline(never) func applyHidden(_ callback: (Box<Int>.Hidden) -> Double) -> Double {
                callback(.init(x: 1, y: 2)) + 1
            }
            @inline(never) func applyMarked(_ callback: (Box<Int>.Marked) -> Double) -> Double {
                callback(.init(x: 3, y: 4)) + 2
            }
            """
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: source,
            linkArguments: ["-parse-as-library", "-swift-version", "6"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let layout = try NativeType.structure(named: "Point", fields: [.double, .double])
        let callback = try NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Double> { _ in 40 }
        for (name, offset) in [("Hidden", 1.0), ("Marked", 2.0)] {
            // Inference leaves generic structs that are not public undecided.
            let type = try await runtime.resolveSwiftType(
                named: "\(module).Box.\(name)",
                in: .path(library.libraryURL),
                genericArguments: [.type(Int.self)]
            )
            let apply = {
                try await runtime.resolveSwiftFunction(
                    named: "\(module).apply\(name)(_:)",
                    as: ((NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Double>) -> Double).self,
                    valueABIs: [type: layout],
                    in: .path(library.libraryURL)
                )
            }
            if NativePointerAuthentication.isEnabled {
                await #expect(throws: ABIResolutionError.self) { try await apply() }
                continue
            }
            let function = try await apply()
            #expect(try unsafe function.unsafeInvoke(callback) == 40 + offset, "\(name)")
        }
    }
    #endif

    @Test func preservesManagedResultsAndFloatingAggregates() async throws {
        let runtime = ABIRuntime.shared
        let apply = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyStringClosure(_:_:)",
            as: ((NativeSwiftClosure<(String) -> String>, String) -> String).self
        )
        let suffix = String(repeating: "!", count: 100)
        let callback = try NativeSwiftClosure { (value: String) in value + suffix }
        let input = String(repeating: "managed", count: 100)
        #expect(try unsafe apply.unsafeInvoke(callback, input) == input + suffix)
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeStringClosure(_:)",
            as: ((String) -> NativeSwiftClosure<(String) -> String>).self
        )
        let returned = try unsafe make.unsafeInvoke(input)
        #expect(try unsafe returned.unsafeInvoke(suffix) == input + suffix)

        let applyObject = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyOptionalObjectClosure(_:_:)",
            as: ((NativeSwiftClosure<(LifetimeToken?) -> LifetimeToken?>, LifetimeToken?)
                -> LifetimeToken?).self
        )
        let identity = try NativeSwiftClosure { (value: LifetimeToken?) in value }
        let token = LifetimeToken()
        #expect(try unsafe applyObject.unsafeInvoke(identity, token) === token)
        #expect(try unsafe applyObject.unsafeInvoke(identity, nil) == nil)

        let applyRect = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyRectClosure(_:_:)",
            as: ((NativeSwiftClosure<(CGRect) -> CGRect>, CGRect) -> CGRect).self
        )
        let translate = try NativeSwiftClosure { (value: CGRect) in value.offsetBy(dx: 3, dy: 4) }
        let rectangle = CGRect(x: 1, y: 2, width: 5, height: 6)
        #expect(
            try unsafe applyRect.unsafeInvoke(translate, rectangle)
                == rectangle.offsetBy(dx: 3, dy: 4)
        )
    }

    @Test func laterArgumentFailureReleasesTheEncodedClosureReference() async throws {
        let runtime = ABIRuntime.shared
        let prototype = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyIntegerClosure(_:_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
        )
        let apply = try await runtime.resolveSwiftFunction(
            named: prototype.symbol.declaration.name,
            as: ((NativeSwiftClosure<(Int64) -> Int64>, RejectingClosureArgument) -> Int64).self
        )
        let destroyed = ClosureCounter(), calls = ClosureCounter()
        weak var observed: ClosureCapture?
        do {
            let capture = ClosureCapture(destroyed)
            observed = capture
            let callback = try NativeSwiftClosure { (value: Int64) in
                calls.increment(); return value + capture.bias
            }
            #expect(throws: ClosureConversionError.self) {
                try unsafe apply.unsafeInvoke(callback, RejectingClosureArgument())
            }
        }
        #expect(calls.count == 0)
        #expect(observed == nil)
        #expect(destroyed.count == 1)
    }

    @Test func explicitEmptyTupleMatchesTheCompiledCallback() async throws {
        let apply = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyEmptyTupleClosure(_:)",
            as: ((NativeSwiftClosure<(Void) -> Int64>) -> Int64).self
        )
        let callback = try NativeSwiftClosure<(Void) -> Int64> { _ in 42 }
        #expect(try unsafe apply.unsafeInvoke(callback) == 42)
        #expect(try unsafe callback.unsafeInvoke(()) == 42)
    }

    #if os(macOS) && DEBUG
    @Test func incomingNonescapingHooksExpireTheirBorrowedClosures() async throws {
        let fixture = try CompiledSwiftReplacementFixture(
            providerExtra: """
                @inline(never) public func hookIntegerBody(_ body: (Int64) -> Int64, _ value: Int64) -> Int64 { body(value) }
                """,
            callerExtra: """
                @inline(never) public func callHookIntegerBody(_ value: Int64) -> Int64 { hookIntegerBody({ $0 + 1 }, value) }
                """
        )
        defer { fixture.cleanup() }
        typealias Body = NativeSwiftClosure<(Int64) -> Int64>
        let function = try await fixture.runtime.resolveSwiftFunction(
            named: fixture.module + ".hookIntegerBody(_:_:)",
            as: ((Body, Int64) -> Int64).self,
            in: fixture.providerScope
        )
        let caller = try await fixture.runtime.resolveSwiftFunction(
            named: fixture.callerModule + ".callHookIntegerBody(_:)",
            as: ((Int64) -> Int64).self,
            in: fixture.callerScope
        )
        let saved = SavedIncomingIntegerClosure()
        let hook = try unsafe await function.hookImportedCalls(
            in: fixture.callerScope,
            using: fixture.runtime,
            onFailure: { Issue.record($0) }
        ) { call, body, value in
            saved.value = body
            return try call.proceed(body, value) + 10
        }
        defer { hook.invalidate() }
        #expect(try unsafe caller.unsafeInvoke(31) == 42)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) {
            try unsafe saved.value!.unsafeInvoke(1)
        }
    }

    #endif

    @Test func rejectsFallibleCustomConversionsBeforeInvokingACallback() throws {
        let calls = ClosureCounter()
        let callback = try NativeSwiftClosure { (value: RejectingClosureArgument) in
            calls.increment()
            return Int64(42)
        }
        #expect(throws: ABIResolutionError.self) {
            try unsafe callback.unsafeInvoke(RejectingClosureArgument()) as Int64
        }
        #expect(calls.count == 0)
    }

    @Test func passesConcreteCallbackToNonescapingNativeParameter() async throws {
        let apply = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyIntegerClosure(_:_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
        )
        let callback = try NativeSwiftClosure { (value: Int64) in value + 7 }
        #expect(try unsafe apply.unsafeInvoke(callback, 35) == 42)
        #expect(try unsafe callback.unsafeInvoke(35) == 42)
    }

    @Test func closureResultsDoNotRetainUncapturedReceivers() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ManagedSwiftFixtures.ClosurePropertyOwner",
            as: ClosurePropertyOwner.self
        )
        let getter = try await type.resolveGetter(
            named: "callback",
            as: (() -> NativeSwiftClosure<(Int64) -> Int64>).self
        )
        let method = try await type.resolveMethod(
            named: "readCallback()",
            as: (() -> NativeSwiftClosure<(Int64) -> Int64>).self
        )
        let setter = try await type.resolveSetter(
            named: "callback",
            as: NativeSwiftClosure<(Int64) -> Int64>.self
        )
        for throughMethod in [false, true] {
            weak var observed: ClosurePropertyOwner?
            var returned: NativeSwiftClosure<(Int64) -> Int64>?
            do {
                let receiver = ClosurePropertyOwner()
                observed = receiver
                returned =
                    try unsafe throughMethod
                    ? method.unsafeInvoke(on: receiver) : getter.unsafeInvoke(on: receiver)
                let callback = try #require(returned)
                try unsafe setter.unsafeInvoke(on: receiver, callback)
                #expect(receiver.callback(35) == 42)
            }
            #expect(observed == nil)
            do {
                let callback = try #require(returned)
                #expect(try unsafe callback.unsafeInvoke(35) == 42)
            }
            returned = nil
        }
    }

    @Test func initializersTransferClosuresAndMethodsBorrowThem() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.StoredIntegerClosure",
            as: StoredIntegerClosure.self
        )
        let create = try await type.resolveInitializer(
            named: "init(_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>) -> StoredIntegerClosure).self
        )
        let apply = try await type.resolveMethod(
            named: "apply(_:_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
        )
        let destroyed = ClosureCounter()
        weak var observed: ClosureCapture?
        var receiver: StoredIntegerClosure?
        do {
            let capture = ClosureCapture(destroyed)
            observed = capture
            let callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
            receiver = try unsafe create.unsafeInvoke(callback)
        }
        do {
            let object = try #require(receiver)
            let doubling = try NativeSwiftClosure { (value: Int64) in value * 2 }
            #expect(try unsafe apply.unsafeInvoke(on: object, doubling, 35) == 84)
            #expect(observed != nil)
        }
        receiver = nil
        #expect(observed == nil)
        #expect(destroyed.count == 1)
    }

    @Test func escapingNativeCallbackOwnsCapturesAndEntryCode() async throws {
        let retain = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.retainIntegerClosure(_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>) -> StoredIntegerClosure).self
        )
        let destroyed = ClosureCounter()
        weak var observed: ClosureCapture?
        var native: StoredIntegerClosure?
        do {
            let capture = ClosureCapture(destroyed)
            observed = capture
            let callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
            native = try unsafe retain.unsafeInvoke(callback)
        }
        withExtendedLifetime(native) {
            #expect(observed != nil)
            #expect(destroyed.count == 0)
        }
        #expect(native!(35) == 42)
        native = nil
        #expect(observed == nil)
        #expect(destroyed.count == 1)
    }

    @Test(arguments: [false, true])
    func repeatedNativeHandoffsPreserveOneOwningEntry(_ throughHostResult: Bool) async throws {
        let echo = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.echoClosure(_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>) -> NativeSwiftClosure<(Int64) -> Int64>)
                .self
        )
        let destroyed = ClosureCounter()
        weak var observed: ClosureCapture?
        do {
            let capture = ClosureCapture(destroyed)
            observed = capture
            let saved = NestedClosureCapture()
            let producer = try NativeSwiftClosure {
                () throws -> NativeSwiftClosure<(Int64) -> Int64> in
                try #require(saved.value)
            }
            var callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
            callback = try unsafe echo.unsafeInvoke(callback)
            #if DEBUG
            func context(
                of callback: NativeSwiftClosure<(Int64) -> Int64>
            ) throws -> UnsafeMutableRawPointer? {
                guard case .synchronous(let storage, _) = try callback.call.resolved() else {
                    Issue.record("Expected a synchronous native closure")
                    return nil
                }
                return storage.value.context
            }
            let originalContext = try #require(try context(of: callback))
            #endif
            for _ in 0..<8 {
                if throughHostResult {
                    saved.value = callback
                    callback = try unsafe producer.unsafeInvoke()
                    saved.value = nil
                }
                callback = try unsafe echo.unsafeInvoke(callback)
                #if DEBUG
                #expect(try context(of: callback) == originalContext)
                #endif
            }
            #expect(try unsafe callback.unsafeInvoke(35) == 42)
        }
        #expect(observed == nil)
        #expect(destroyed.count == 1)
    }

    @Test func noncapturingNativeResultAllowsANilContext() async throws {
        let make = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeNoncapturingClosure()",
            as: (() -> NativeSwiftClosure<(Int64) -> Int64>).self
        )
        let callback = try unsafe make.unsafeInvoke()
        #expect(try unsafe callback.unsafeInvoke(21) == 42)
    }

    @Test func returnedNativeClosureOwnsItsCaptureContext() async throws {
        let make = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeIntegerClosure(_:_:)",
            as: ((LifetimeToken, Int64) -> NativeSwiftClosure<(Int64) -> Int64>).self
        )
        weak var observed: LifetimeToken?
        var destroyed = 0
        var callback: NativeSwiftClosure<(Int64) -> Int64>?
        do {
            let token = LifetimeToken { destroyed += 1 }
            observed = token
            callback = try unsafe make.unsafeInvoke(token, 7)
        }
        do {
            let value = try #require(callback)
            #expect(observed != nil)
            #expect(try unsafe value.unsafeInvoke(35) == 42)
        }
        callback = nil
        #expect(observed == nil)
        #expect(destroyed == 1)
    }

    @Test func handlesZeroArgumentsVoidAndStackArguments() throws {
        let calls = ClosureCounter()
        let empty = try NativeSwiftClosure<() -> Void> { calls.increment() }
        try unsafe empty.unsafeInvoke()
        #expect(calls.count == 1)
        let many = try NativeSwiftClosure {
            (
                a: Int64,
                b: Int64,
                c: Int64,
                d: Int64,
                e: Int64,
                f: Int64,
                g: Int64,
                h: Int64,
                i: Int64,
                j: Int64,
                k: Int64,
                l: Int64
            ) -> Int64 in
            let first = a + b + c + d + e + f
            return first + g + h + i + j + k + l
        }
        #expect(try unsafe many.unsafeInvoke(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) == 78)
    }

    #if DEBUG
    @Test func nativeContextsOwnSharedEntriesAfterEveryPreparedHandleAndCacheEntryIsReleased()
        async throws
    {
        let deaths = ClosureCounter()
        var keeper: ClosurePropertyOwner? = ClosurePropertyOwner()
        do {
            let runtime = ABIRuntime()
            let type = try await runtime.resolveSwiftType(
                named: "ManagedSwiftFixtures.ClosurePropertyOwner"
            )
            let set = try await type.resolveSetter(
                named: "callback",
                as: NativeSwiftClosure<(Int64) -> Int64>.self
            )
            let capture = ClosureCapture(deaths)
            let callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
            try unsafe set.unsafeInvoke(on: keeper!, callback)
        }
        for size in 1...80 {
            let interface = try SwiftCallInterface.cached(
                result: CValueType(indirectSwiftSize: size, alignment: 1),
                parameters: []
            )
            _ = try interface.closureEntry()
        }
        #expect(deaths.count == 0)
        #expect(keeper!.callback(35) == 42)
        keeper = nil
        #expect(deaths.count == 1)
    }

    @Test func cachedInterfacesPreserveIndirectionErrorsAndLiveHandlesAfterEviction() throws {
        let word = try CValueType(scalar: ABIValueInt64)
        let direct = try SwiftCallInterface.cached(result: word, parameters: [word])
        let indirect = try CValueType(indirectSwiftSize: 8, alignment: 8)
        #expect(
            try SwiftCallInterface.cached(result: indirect, parameters: [word]).runtime
                !== direct.runtime
        )
        #expect(
            try SwiftCallInterface.cached(result: word, parameters: [indirect]).runtime
                !== direct.runtime
        )
        let typed = try SwiftCallInterface.cached(
            result: word,
            parameters: [word],
            errorPlan: SwiftErrorPlan.make(ScalarFailure.self)
        )
        let untyped = try SwiftCallInterface.cached(
            result: word,
            parameters: [word],
            errorPlan: SwiftErrorPlan.make((any Error).self)
        )
        #expect(
            typed.runtime !== untyped.runtime && typed.runtime !== direct.runtime
                && untyped.runtime !== direct.runtime
        )
        let callback = try NativeSwiftClosure { (value: Int64) in value + 1 }
        for size in 1...80 {
            _ = try SwiftCallInterface.cached(
                result: CValueType(indirectSwiftSize: size, alignment: 1),
                parameters: []
            )
        }
        #expect(try unsafe callback.unsafeInvoke(41) == 42)
        let repeated = try NativeSwiftClosure { (value: Int64) in value + 2 }
        #expect(try unsafe repeated.unsafeInvoke(40) == 42)
    }

    @Test func closureDiscriminatorsMatchCompilerEvidence() throws {
        #expect(
            swiftClosureDiscriminator(
                parameters: [try swiftClosureAuthType(Int64.self, position: .parameter)],
                result: try swiftClosureAuthType(Int64.self, position: .result)
            ) == 21761
        )
        #expect(swiftClosureDiscriminator(parameters: ["-indirect"], result: "-indirect") == 55683)
        #expect(
            try swiftClosureAuthType(LifetimeToken.self, position: .parameter)
                == swiftClosureAuthType(LifetimeToken?.self, position: .parameter)
        )
        #expect(
            try swiftClosureAuthType(UnsafePointer<Int64>.self, position: .parameter)
                == swiftClosureAuthType(UnsafePointer<UInt8>.self, position: .parameter)
        )
    }

    @Test func failedReturnedClosurePreparationReleasesOwnedContext() throws {
        let codec = try NativeSwiftClosure<(Int64) -> Int64>.makeClosureCodec()
        let destroyed = ClosureCounter()
        let context = Unmanaged.passRetained(ClosureCapture(destroyed)).toOpaque()
        #expect(throws: ABIInvocationError.self) {
            _ = try codec.makeValue(
                ABISwiftClosureValue(function: nil, context: context),
                nil,
                true,
                nil
            )
        }
        #expect(destroyed.count == 1)
    }
    #endif
}

private final class SavedIncomingIntegerClosure: @unchecked Sendable {
    var value: NativeSwiftClosure<(Int64) -> Int64>?
}

#if DEBUG && os(macOS)
/// Compiles `source` for arm64e and returns the pointer-authentication
/// discriminator of the closure call in each of `functions`.
private func arm64eClosureCallDiscriminators(
    source: String,
    arguments: [String] = [],
    functions: [String]
) throws -> [UInt16] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
    }
    let sourceURL = directory.appendingPathComponent("Closures.swift")
    let ir = directory.appendingPathComponent("Closures.ll")
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    func run(_ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        // The test runner's injected Xcode frameworks belong to its process,
        // not to the xcrun-selected compiler and SDK tools.
        process.environment = FixtureLibrary.toolEnvironment.filter { $0.key != "SDKROOT" }
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ClosureCompilerProbe",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
        return text
    }
    let sdk = try run(["--sdk", "iphoneos", "--show-sdk-path"]).trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    _ = try run(
        [
            "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone",
            "-target", "arm64e-apple-ios18.4", "-sdk", sdk, "-emit-ir",
        ] + arguments + [sourceURL.path, "-o", ir.path]
    )
    let text = try String(contentsOf: ir, encoding: .utf8)
    return try functions.map { function in
        let pattern = #"(?ms)^define[^\n]*"# + function + #"[y_][^\n]*\{(.*?)^\}"#
        let expression = try NSRegularExpression(pattern: pattern)
        let match = try #require(
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        )
        let range = try #require(Range(match.range(at: 1), in: text))
        let body = String(text[range])
        let call = try #require(
            body.split(separator: "\n").first {
                $0.contains("call swiftcc") && $0.contains("swiftself")
                    && $0.contains(#""ptrauth""#)
            }
        )
        let discriminator = try NSRegularExpression(
            pattern: #""ptrauth"\(i32 0, i64 ([0-9]+)\)"#
        )
        let line = String(call)
        let auth = try #require(
            discriminator.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        )
        let digits = try #require(Range(auth.range(at: 1), in: line))
        return try #require(UInt16(line[digits]))
    }
}
#endif
