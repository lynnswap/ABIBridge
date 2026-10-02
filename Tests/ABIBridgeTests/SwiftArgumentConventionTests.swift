import ABIBridge
import ManagedSwiftFixtures
import Testing

extension ArgumentCounter: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .int64 }
}
private enum ArgumentEncodingFailure: Error { case expected }
private struct BadArgumentEncoding: ABIBridgeValue {
    static var abiType: NativeType { .int64 }
    static func nativeValue(from value: Self) throws -> NativeValue { throw ArgumentEncodingFailure.expected }
    init(nativeValue: NativeValue) throws {}
    init() {}
}

struct SwiftArgumentConventionTests {
    @Test func asyncEntriesAndCallbacksHandleOddStackSlotCounts() async throws {
        let runtime = ABIRuntime.shared
        let seven = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.asyncSeven(_:_:_:_:_:_:_:)",
            as: (@concurrent (Int64, Int64, Int64, Int64, Int64, Int64, Int64) async -> Int64).self)
        let nine = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.asyncNine(_:_:_:_:_:_:_:_:_:)",
            as: (@concurrent (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) async -> Int64).self)
        #expect(try unsafe await seven.unsafeInvoke(1, 2, 3, 4, 5, 6, 7) == 28)
        #expect(try unsafe await nine.unsafeInvoke(1, 2, 3, 4, 5, 6, 7, 8, 9) == 45)

        typealias Seven = NativeSwiftClosure<@Sendable @concurrent (Int64, Int64, Int64, Int64, Int64, Int64, Int64) async -> Int64>
        typealias Nine = NativeSwiftClosure<@Sendable @concurrent (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) async -> Int64>
        let applySeven = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applySeven(_:)",
            as: (@concurrent (Seven) async -> Int64).self)
        let applyNine = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.applyNine(_:)",
            as: (@concurrent (Nine) async -> Int64).self)
        #expect(try unsafe await applySeven.unsafeInvoke(Seven(asyncSeven)) == 28)
        #expect(try unsafe await applyNine.unsafeInvoke(Nine(asyncNine)) == 45)
    }

    @Test func consumedIndirectValuesReleaseTheirReferencesExactlyOnce() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.consumeLargeArgument(_:_:_:)",
            as: ((NativeSwiftConsuming<ErrorSuccessPayload>, ArgumentCounts, Bool) throws(ScalarFailure) -> Int64).self)
        let counts = ArgumentCounts()
        for fail in [false, true] {
            weak var observed: ErrorLifetimeToken?
            do {
                let token = ErrorLifetimeToken { counts.destroyed() }
                observed = token
                let value = ErrorSuccessPayload(token)
                do {
                    #expect(try unsafe call.unsafeInvoke(.init(value), counts, fail) == 40 && !fail)
                } catch let error as NativeSwiftError {
                    error.withUnderlyingError { #expect(fail && ($0 as? ScalarFailure)?.code == 42) }
                }
                #expect(observed != nil && value.d == 40)
            }
            #expect(observed == nil)
        }
        #expect(counts.entries == 2 && counts.destructions == 2)
    }

    @Test func failedArgumentEncodingLeavesInoutStorageUntouched() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.mutateBeforeConversionFailure(inout Swift.String, Swift.Int64) -> ()",
            as: ((NativeSwiftInout<String>, BadArgumentEncoding) -> Void).self)
        let text = NativeSwiftInout("original")
        do { try unsafe call.unsafeInvoke(text, .init()); Issue.record("Expected argument conversion failure") }
        catch ArgumentEncodingFailure.expected {}
        #expect(text.value == "original")
    }


    @Test func inoutValuesKeepNativeWritebackOnSuccessAndError() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.mutateArguments(_:_:_:_:)",
            as: ((NativeSwiftInout<String>, NativeSwiftInout<[String]>, NativeSwiftInout<Int64>, Bool) throws(ScalarFailure) -> Void).self)
        let text = NativeSwiftInout(String(repeating: "text", count: 100))
        let values = NativeSwiftInout([String]())
        let count = NativeSwiftInout(Int64(40))
        try unsafe call.unsafeInvoke(text, values, count, false)
        #expect(count.value == 41 && values.value == [text.value])
        do { try unsafe call.unsafeInvoke(text, values, count, true); Issue.record("Expected typed failure") }
        catch let error as NativeSwiftError {
            error.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 42) }
        }
        #expect(count.value == 42 && values.value.count == 2 && values.value.last == text.value)
        text.value = "reset"
        #expect(text.value == "reset")
    }

    @Test func consumingCopiesAreTransferredOnBothCompletionPaths() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.consumeArguments(_:_:_:_:)",
            as: ((NativeSwiftConsuming<String>, NativeSwiftBorrowing<String>, NativeSwiftConsuming<ArgumentToken>, Bool) throws(ScalarFailure) -> String).self)
        let counts = ArgumentCounts()
        for fail in [false, true] {
            weak var observed: ArgumentToken?
            do {
                let token = ArgumentToken(counts)
                observed = token
                let owned = String(repeating: "owned", count: 100)
                let borrowed = String(repeating: "borrowed", count: 100)
                do {
                    let result = try unsafe call.unsafeInvoke(.init(owned), .init(borrowed), .init(token), fail)
                    #expect(!fail && result == owned + borrowed)
                } catch let error as NativeSwiftError {
                    error.withUnderlyingError { #expect(fail && ($0 as? ScalarFailure)?.code == 42) }
                }
                #expect(observed === token && owned.count == 500 && borrowed.count == 800)
            }
            #expect(observed == nil)
        }
        #expect(counts.entries == 2 && counts.destructions == 2)
    }

    @Test func laterEncodingFailureReleasesTheUntransferredCopy() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.consumeBeforeConversionFailure(__owned ManagedSwiftFixtures.ArgumentToken, Swift.Int64) -> Swift.Int64",
            as: ((NativeSwiftConsuming<ArgumentToken>, BadArgumentEncoding) -> Int64).self)
        let counts = ArgumentCounts()
        weak var observed: ArgumentToken?
        do {
            let token = ArgumentToken(counts)
            observed = token
            do { _ = try unsafe call.unsafeInvoke(.init(token), .init()); Issue.record("Expected conversion failure") }
            catch ArgumentEncodingFailure.expected {}
            #expect(observed === token && counts.entries == 0)
        }
        #expect(observed == nil && counts.destructions == 1)
    }

    @Test func initializersMixBorrowedAndConsumedArguments() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.ArgumentOwner")
        let make = try await type.initializer(named: "init(_:_:_:)",
            as: ((NativeSwiftBorrowing<String>, NativeSwiftConsuming<String>, NativeSwiftBorrowing<ArgumentToken>) -> ArgumentOwner).self)
        let counts = ArgumentCounts()
        weak var observed: ArgumentToken?
        var owner: ArgumentOwner?
        do {
            let token = ArgumentToken(counts)
            observed = token
            owner = try unsafe make.unsafeInvoke(.init("first"), .init("second"), .init(token))
        }
        #expect(owner?.first == "first" && owner?.second == "second" && observed != nil)
        owner = nil
        #expect(observed == nil && counts.destructions == 1)
    }

    @Test func receiverAndExplicitInoutArgumentsHaveSeparateWriteback() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.ArgumentCounter", as: ArgumentCounter.self)
        let update = try await type.method(named: "update(_:_:_:)",
            as: ((NativeSwiftInout<String>, NativeSwiftConsuming<String>, Bool) throws(ScalarFailure) -> Void).self,
            mutating: true)
        var receiver = ArgumentCounter(40)
        let text = NativeSwiftInout("value")
        do { try unsafe update.unsafeInvoke(on: &receiver, text, .init("!"), true); Issue.record("Expected failure") }
        catch let error as NativeSwiftError {
            error.withUnderlyingError { #expect(($0 as? ScalarFailure)?.code == 41) }
        }
        #expect(receiver.count == 41 && text.value == "value!")
    }

    @MainActor @Test func asyncInoutArgumentsRemainLiveThroughCancellation() async throws {
        let call = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.asyncArguments(_:_:_:_:_:)",
            as: (@concurrent (AsyncGate, NativeSwiftInout<String>, NativeSwiftConsuming<String>, NativeSwiftBorrowing<String>, Bool) async throws(ScalarFailure) -> String).self)
        for cancel in [false, true] {
            let gate = AsyncGate()
            let text = NativeSwiftInout("value")
            let task = Task { @MainActor in
                try unsafe await call.unsafeInvoke(gate, text, .init("!"), .init("?"), false)
            }
            await gate.waitUntilSuspended()
            if cancel { task.cancel() }
            await gate.open()
            do { #expect(try await task.value == "value!?" && !cancel) }
            catch let error as NativeSwiftError {
                error.withUnderlyingError { #expect(cancel && ($0 as? ScalarFailure)?.code == -1) }
            }
            #expect(text.value == "value!")
        }
    }

    @Test func asyncInitializersRetainBorrowedArgumentsUntilCompletion() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.ArgumentOwner")
        let make = try await type.initializer(named: "init(_:_:_:_:_:)",
            as: (@concurrent (NativeSwiftBorrowing<String>, NativeSwiftConsuming<String>, NativeSwiftBorrowing<ArgumentToken>, AsyncGate, Bool) async throws(ScalarFailure) -> ArgumentOwner).self)
        let counts = ArgumentCounts()
        for fail in [false, true] {
            let gate = AsyncGate()
            weak var observed: ArgumentToken?
            let task: Task<ArgumentOwner, any Error>
            do {
                let token = ArgumentToken(counts)
                observed = token
                task = Task { try unsafe await make.unsafeInvoke(.init("first"), .init("second"), .init(token), gate, fail) }
            }
            await gate.waitUntilSuspended()
            #expect(observed != nil)
            await gate.open()
            do {
                let owner = try await task.value
                #expect(!fail && owner.first == "first" && owner.second == "second" && owner.token === observed)
            } catch let error as NativeSwiftError {
                error.withUnderlyingError { #expect(fail && ($0 as? ScalarFailure)?.code == 42) }
                #expect(observed == nil)
            }
        }
    }
}
