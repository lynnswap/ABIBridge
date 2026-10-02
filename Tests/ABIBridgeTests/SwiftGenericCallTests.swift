import ABIBridge
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

private enum GenericConversionFailure: Error { case rejected }
private struct RejectGenericArgument: ABIBridgeValue {
    static var abiType: NativeType { .int64 }
    init() {}
    init(nativeValue: NativeValue) throws { throw GenericConversionFailure.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue { throw GenericConversionFailure.rejected }
}

private struct GenericPointerWrapper: ABIBridgeValue, Equatable {
    let pointer: UnsafeRawPointer
    let marker: Int64
    static var abiType: NativeType { .pointer }
    init(pointer: UnsafeRawPointer, marker: Int64) { self.pointer = pointer; self.marker = marker }
    init(nativeValue: NativeValue) throws { throw GenericConversionFailure.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue { throw GenericConversionFailure.rejected }
}

private final class GenericCapture: Sendable {
    let state: GenericCaptureState
    init(_ state: GenericCaptureState) { self.state = state }
    deinit { state.deaths.withLock { $0 += 1 } }
    func value() -> String { state.calls.withLock { $0 += 1 }; return String(repeating: "capture", count: 100) }
}
private final class GenericCaptureState: Sendable {
    let calls = Mutex(0)
    let deaths = Mutex(0)
}

@Suite(.serialized)
struct SwiftGenericCallTests {
    @Test func returnedGenericClosuresPreserveCapturedValuesAndTypedErrors() async throws {
        let runtime = ABIRuntime.shared
        let factory = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeClosureGeneric<A>(A) -> (A) -> A",
            as: ((String) -> NativeSwiftClosure<(String) -> String>).self,
            genericArguments: [.type(String.self)])
        let text = String(repeating: "captured", count: 100)
        let closure = try unsafe factory.unsafeInvoke(text)
        #expect(try unsafe closure.unsafeInvoke("argument") == text)
        let throwing = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeThrowingClosureGeneric<A, B where B: Swift.Error>(A, B) -> (Swift.Bool) throws(B) -> A",
            as: ((String, ScalarFailure) -> NativeSwiftClosure<(Bool) throws(ScalarFailure) -> String>).self,
            genericArguments: [.type(String.self), .type(ScalarFailure.self)])
        let operation = try unsafe throwing.unsafeInvoke(text, ScalarFailure(77))
        #expect(try unsafe operation.unsafeInvoke(false) == text)
        do {
            _ = try unsafe operation.unsafeInvoke(true)
            Issue.record("Expected the captured typed error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? ScalarFailure)?.code } == 77)
        }
    }

    @MainActor @Test func returnedGenericClosuresComposeWithAsyncAndPacks() async throws {
        let runtime = ABIRuntime.shared
        let asynchronous = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeAsyncClosureGeneric<A where A: Swift.Sendable>(A) -> nonisolated(nonsending) @Sendable (A) async -> A",
            as: ((String) -> NativeSwiftClosure<@Sendable (String) async -> String>).self,
            genericArguments: [.type(String.self)])
        let text = String(repeating: "asynchronous", count: 50)
        let operation = try unsafe asynchronous.unsafeInvoke(text)
        #expect(try unsafe await operation.unsafeInvoke("ignored") == text)
        let pack = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makePackClosureGeneric<each A>() -> (repeat A) -> (repeat A)",
            as: (() -> NativeSwiftClosure<(String, Int64) -> (String, Int64)>).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let returned = try unsafe pack.unsafeInvoke()
        let output = try unsafe returned.unsafeInvoke(text, Int64(61))
        #expect(output.0 == text && output.1 == 61)
    }

    @Test func returnedGenericClosureReleasesItsCapturedValueAfterTheLastCopy() async throws {
        let state = GenericCaptureState()
        let factory = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeOwnedClosureGeneric<A>(A) -> () -> A",
            as: ((GenericCapture) -> NativeSwiftClosure<() -> GenericCapture>).self,
            genericArguments: [.type(GenericCapture.self)])
        var saved: NativeSwiftClosure<() -> GenericCapture>?
        do {
            let capture = GenericCapture(state)
            let original = try unsafe factory.unsafeInvoke(capture)
            saved = original
            #expect(try unsafe original.unsafeInvoke() === capture)
        }
        #expect(state.deaths.withLock { $0 } == 0)
        withExtendedLifetime(saved) { #expect(state.deaths.withLock { $0 } == 0) }
        saved = nil
        #expect(state.deaths.withLock { $0 } == 1)
    }

    @Test func parameterPacksIncludeEmptySingletonAndConstrainedBindings() async throws {
        let runtime = ABIRuntime.shared
        let name = "ManagedSwiftFixtures.packGeneric<each A>(repeat A) -> (repeat A)"
        let empty = try await runtime.swiftFunction(named: name, as: (() -> Void).self,
            genericArguments: [.pack([])])
        try unsafe empty.unsafeInvoke()
        let single = try await runtime.swiftFunction(named: name, as: ((String) -> String).self,
            genericArguments: [.pack([.type(String.self)])])
        let text = String(repeating: "pack", count: 100)
        #expect(try unsafe single.unsafeInvoke(text) == text)
        let values = try await runtime.swiftFunction(named: name,
            as: ((String, Int64, Bool) -> (String, Int64, Bool)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self), .type(Bool.self)])])
        let output = try unsafe values.unsafeInvoke(text, Int64(42), true)
        let control = packGeneric(text, Int64(42), true)
        #expect(output.0 == control.0 && output.1 == control.1 && output.2 == control.2)
        let constrained = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.constrainedPackGeneric<each A where A: Swift.Equatable>(repeat A) -> (repeat A)",
            as: ((String, [Int64]) -> (String, [Int64])).self,
            genericArguments: [.pack([.type(String.self), .type([Int64].self)])])
        let paired = try unsafe constrained.unsafeInvoke(text, [Int64(1), 2])
        #expect(paired.0 == text && paired.1 == [1, 2])
    }

    @MainActor @Test func mixedAndNestedPacksPreserveTupleStorageAndSuspension() async throws {
        let runtime = ABIRuntime.shared
        let text = String(repeating: "nested pack", count: 50)
        let mixed = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.mixedPackGeneric<A, B>(A, repeat B) -> (Swift.Int8, A, repeat B, Swift.Int8)",
            as: ((String, Int64, Bool) -> (Int8, String, Int64, Bool, Int8)).self,
            genericArguments: [.type(String.self), .pack([.type(Int64.self), .type(Bool.self)])])
        let result = try unsafe mixed.unsafeInvoke(text, Int64(37), true)
        #expect(result.0 == 1 && result.1 == text && result.2 == 37 && result.3 && result.4 == 2)
        let nested = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.nestedPackGeneric<each A>((Swift.Int8, repeat A, Swift.Int8)) -> (Swift.Int8, repeat A, Swift.Int8)",
            as: (((Int8, String, Int64, Int8)) -> (Int8, String, Int64, Int8)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let tuple = try unsafe nested.unsafeInvoke((Int8(12), text, Int64(93), Int8(-8)))
        #expect(tuple.0 == 12 && tuple.1 == text && tuple.2 == 93 && tuple.3 == -8)
        let suspended = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedPackGeneric<each A>(repeat A) async -> (repeat A)",
            as: ((String, Int64) async -> (String, Int64)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let output = try unsafe await suspended.unsafeInvoke(text, Int64(57))
        #expect(output.0 == text && output.1 == 57)
    }

    @Test func packShapeClassesAndCallbacksUseOneNativePackPerExpansion() async throws {
        let runtime = ABIRuntime.shared
        let markerInName = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.Rvz<A, B>(A, repeat B) -> (A, repeat B)",
            as: ((String, Int64) -> (String, Int64)).self,
            genericArguments: [.type(String.self), .pack([.type(Int64.self)])])
        let namedResult = try unsafe markerInName.unsafeInvoke("name", Int64(22))
        #expect(namedResult.0 == "name" && namedResult.1 == 22)
        let pair = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.pairedPackGeneric<each A, B where A.shape == B.shape>(repeat (A, B)) -> (repeat (B, A))",
            as: (((Int64, String), (Bool, Double)) -> ((String, Int64), (Double, Bool))).self,
            genericArguments: [.pack([.type(Int64.self), .type(Bool.self)]), .pack([.type(String.self), .type(Double.self)])])
        let output = try unsafe pair.unsafeInvoke((Int64(34), "value"), (true, 2.5))
        #expect(output.0.0 == "value" && output.0.1 == 34 && output.1.0 == 2.5 && output.1.1)
        let function = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.callbackPackGeneric<each A>((repeat A) -> (repeat A), repeat A) -> (repeat A)",
            as: ((NativeSwiftClosure<(String, Int64) -> (String, Int64)>, String, Int64) -> (String, Int64)).self,
            genericArguments: [.pack([.type(String.self), .type(Int64.self)])])
        let body: NativeSwiftClosure<(String, Int64) -> (String, Int64)> = try NativeSwiftClosure { ($0 + "!", $1 + 1) }
        let called = try unsafe function.unsafeInvoke(body, "callback", Int64(17))
        #expect(called.0 == "callback!" && called.1 == 18)
    }

    @Test func genericTupleElementsUseTheirDeclaredConventions() async throws {
        let runtime = ABIRuntime.shared
        let tuple = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.tupleGeneric<A>((A, Swift.Int8, Swift.Int8)) -> (A, Swift.Int8, Swift.Int8)",
            as: (((String, Int8, Int8)) -> (String, Int8, Int8)).self,
            genericArguments: [.type(String.self)])
        let input: (String, Int8, Int8) = (String(repeating: "tuple", count: 100), -31, 72)
        let output = try unsafe tuple.unsafeInvoke(input)
        let control = tupleGeneric(input)
        #expect(output.0 == control.0 && output.1 == control.1 && output.2 == control.2)

        let pair = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.pairGeneric<A, B>((A, B)) -> (B, A)",
            as: (((String, Int64)) -> (Int64, String)).self,
            genericArguments: [.type(String.self), .type(Int64.self)])
        let swapped = try unsafe pair.unsafeInvoke((input.0, Int64(42)))
        #expect(swapped.0 == 42 && swapped.1 == input.0)

        let callback = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.tupleCallbackGeneric<A>((A, Swift.Int8), ((A, Swift.Int8)) -> (A, Swift.Int8, Swift.Int8)) -> (A, Swift.Int8, Swift.Int8)",
            as: (((String, Int8), NativeSwiftClosure<((String, Int8)) -> (String, Int8, Int8)>) -> (String, Int8, Int8)).self,
            genericArguments: [.type(String.self)])
        let body: NativeSwiftClosure<((String, Int8)) -> (String, Int8, Int8)> = try NativeSwiftClosure {
            ($0.0 + "!", $0.1, -$0.1)
        }
        let called = try unsafe callback.unsafeInvoke((input.0, Int8(27)), body)
        #expect(called.0 == input.0 + "!" && called.1 == 27 && called.2 == -27)
    }

    @MainActor @Test func mixedTupleResultsSurviveAsyncSuspension() async throws {
        let runtime = ABIRuntime.shared
        let large = LargeManagedValue(token: LifetimeToken(), a: 1, b: 2, c: 3, d: 4)
        let input = (String(repeating: "large", count: 100), large, Int64(91))
        let direct = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.largeTupleGeneric<A>((A, ManagedSwiftFixtures.LargeManagedValue, Swift.Int64)) -> (A, ManagedSwiftFixtures.LargeManagedValue, Swift.Int64)",
            as: (((String, LargeManagedValue, Int64)) -> (String, LargeManagedValue, Int64)).self,
            genericArguments: [.type(String.self)])
        let output = try unsafe direct.unsafeInvoke(input)
        #expect(output.0 == input.0 && output.1.token === large.token && output.1.d == 4 && output.2 == 91)
        let suspended = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedLargeTupleGeneric<A>((A, ManagedSwiftFixtures.LargeManagedValue, Swift.Int64)) async -> (A, ManagedSwiftFixtures.LargeManagedValue, Swift.Int64)",
            as: (((String, LargeManagedValue, Int64)) async -> (String, LargeManagedValue, Int64)).self,
            genericArguments: [.type(String.self)])
        let awaited = try unsafe await suspended.unsafeInvoke(input)
        #expect(awaited.0 == input.0 && awaited.1.token === large.token && awaited.1.d == 4 && awaited.2 == 91)
        let pair = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedPairGeneric<A, B>((A, B)) async -> (B, A)",
            as: (((String, Int64)) async -> (Int64, String)).self,
            genericArguments: [.type(String.self), .type(Int64.self)])
        let swapped = try unsafe await pair.unsafeInvoke((input.0, Int64(55)))
        #expect(swapped.0 == 55 && swapped.1 == input.0)
    }

    @MainActor @Test func genericAsyncCallbacksPreserveIsolationTupleResultsAndErrors() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedTransformGeneric<A, B>(A, nonisolated(nonsending) (A) async throws -> (B, Swift.Int8)) async throws -> (B, Swift.Int8)",
            as: ((String, NativeSwiftClosure<(String) async throws -> (String, Int8)>) async throws -> (String, Int8)).self,
            genericArguments: [.type(String.self), .type(String.self)])
        let operation: @Sendable (String) async throws -> (String, Int8) = { value in
            MainActor.preconditionIsolated()
            await Task.yield()
            MainActor.preconditionIsolated()
            if value.isEmpty { throw GenericConversionFailure.rejected }
            return (value + "!", 42)
        }
        let body = try NativeSwiftClosure<(String) async throws -> (String, Int8)>(operation)
        let text = String(repeating: "async tuple", count: 50)
        let output = try unsafe await function.unsafeInvoke(text, body)
        #expect(output.0 == text + "!" && output.1 == 42)
        do {
            _ = try unsafe await function.unsafeInvoke("", body)
            Issue.record("Expected the callback's original error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is GenericConversionFailure })
        }
    }

    @Test func multipleBindingsConstraintsAndCompositeValuesMatchNativeCalls() async throws {
        let runtime = ABIRuntime.shared
        let equal = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.equalGeneric<A where A: Swift.Equatable>(A, A) -> Swift.Bool",
            as: (([String], [String]) -> Bool).self, genericArguments: [.type([String].self)])
        let values = ["first", String(repeating: "second", count: 80)]
        #expect(try unsafe equal.unsafeInvoke(values, values) == equalGeneric(values, values))
        #expect(try unsafe equal.unsafeInvoke(values, []) == equalGeneric(values, []))
        let select = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.selectGeneric<A, B where A == B.Element, B: Swift.Collection>(A, B) -> A",
            as: ((String, [String]) -> String).self, genericArguments: [.type(String.self), .type([String].self)])
        #expect(try unsafe select.unsafeInvoke("fallback", values) == selectGeneric("fallback", values))
        #expect(try unsafe select.unsafeInvoke("fallback", []) == "fallback")
        let optional = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.optionalGeneric<A>(A?) -> A?",
            as: ((String?) -> String?).self, genericArguments: [.type(String.self)])
        #expect(try unsafe optional.unsafeInvoke(values[1]) == optionalGeneric(Optional(values[1])))
        #expect(try unsafe optional.unsafeInvoke(nil) == nil)
    }

    @Test func genericCallbacksAcceptArgumentsAndPreserveNativeErrors() async throws {
        let transform = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.transformGeneric<A, B>([A], (A) throws -> B) throws -> [B]",
            as: (([Int64], NativeSwiftClosure<(Int64) throws -> String>) throws -> [String]).self,
            genericArguments: [.type(Int64.self), .type(String.self)])
        let callback: NativeSwiftClosure<(Int64) throws -> String> = try NativeSwiftClosure { value in
            if value < 0 { throw GenericConversionFailure.rejected }
            return "value: \(value)"
        }
        let values: [Int64] = [1, 2, 3]
        #expect(try unsafe transform.unsafeInvoke(values, callback) == transformGeneric(values) { "value: \($0)" })
        do {
            _ = try unsafe transform.unsafeInvoke([-1], callback)
            Issue.record("Expected the original callback error")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { $0 is GenericConversionFailure })
        }
    }

    @MainActor @Test func genericAsyncAndTypedErrorsPreserveValuesAcrossSuspension() async throws {
        let runtime = ABIRuntime.shared
        let echo = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGeneric<A>(A) async -> A",
            as: ((String) async -> String).self, genericArguments: [.type(String.self)])
        let text = String(repeating: "suspended", count: 100)
        #expect(try unsafe await echo.unsafeInvoke(text) == text)
        let failure = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericFailure<A, B where B: Swift.Error>(A, B, Swift.Bool) throws(B) -> A",
            as: ((String, ScalarFailure, Bool) throws(ScalarFailure) -> String).self,
            genericArguments: [.type(String.self), .type(ScalarFailure.self)])
        #expect(try unsafe failure.unsafeInvoke(text, ScalarFailure(42), false) == text)
        do {
            _ = try unsafe failure.unsafeInvoke(text, ScalarFailure(42), true)
            Issue.record("Expected the typed failure")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? ScalarFailure)?.code } == 42)
        }
        let suspended = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.suspendedGenericFailure<A, B where B: Swift.Error>(A, B, Swift.Bool) async throws(B) -> A",
            as: ((String, ScalarFailure, Bool) async throws(ScalarFailure) -> String).self,
            genericArguments: [.type(String.self), .type(ScalarFailure.self)])
        #expect(try unsafe await suspended.unsafeInvoke(text, ScalarFailure(43), false) == text)
        do {
            _ = try unsafe await suspended.unsafeInvoke(text, ScalarFailure(43), true)
            Issue.record("Expected the suspended typed failure")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? ScalarFailure)?.code } == 43)
        }
    }

    @Test func genericStorageUsesTheActualTypeInsteadOfItsForeignConversion() async throws {
        let runtime = ABIRuntime.shared
        let echo = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((GenericPointerWrapper?) -> GenericPointerWrapper?).self, genericArguments: [.type(GenericPointerWrapper?.self)])
        let value = GenericPointerWrapper(pointer: try #require(UnsafeRawPointer(bitPattern: 0x1000)), marker: 42)
        #expect(MemoryLayout<GenericPointerWrapper?>.size > MemoryLayout<UnsafeRawPointer>.size)
        #expect(try unsafe echo.unsafeInvoke(value) == echoGeneric(Optional(value)))
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)

        let marked = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((NativeSwiftBorrowing<String>) -> NativeSwiftBorrowing<String>).self,
            genericArguments: [.type(NativeSwiftBorrowing<String>.self)])
        let input = NativeSwiftBorrowing(String(repeating: "owned", count: 100))
        #expect(try unsafe marked.unsafeInvoke(input).value == echoGeneric(input).value)

        let closure = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((NativeSwiftClosure<() -> Int64>) -> NativeSwiftClosure<() -> Int64>).self,
            genericArguments: [.type(NativeSwiftClosure<() -> Int64>.self)])
        let returned = try unsafe closure.unsafeInvoke(NativeSwiftClosure { Int64(42) })
        #expect(try unsafe returned.unsafeInvoke() == 42)
    }

    @Test func capturingCallbacksMatchCompilerGeneratedCalls() async throws {
        let runtime = ABIRuntime.shared
        let boolean = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> Bool>) -> Bool).self, genericArguments: [.type(Bool.self)])
        for value in [true, false] {
            let callback = try NativeSwiftClosure { value }
            #expect(try unsafe boolean.unsafeInvoke(callback) == referenceGenericBool(value))
        }
        let stringType = try await runtime.swiftType(named: "Swift.String")
        let string = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> String>) -> String).self, genericArguments: [.type(stringType)])
        let input = String(repeating: "managed", count: 100)
        let callback = try NativeSwiftClosure { input + "!" }
        for _ in 0..<20 {
            #expect(try unsafe string.unsafeInvoke(callback) == referenceGenericString(input))
        }
    }

    @MainActor @Test func nonescapingApplyKeepsCallerIsolation() async throws {
        let run = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> Bool>) -> Bool).self, genericArguments: [.type(Bool.self)])
        var calls = 0
        let result = try unsafe NativeSwiftClosure<() -> Bool>.withUnsafeNonescaping({ calls += 1; return calls == 1 }) {
            try unsafe run.unsafeInvoke($0)
        }
        #expect(result && calls == 1)
    }

    @Test func genericArgumentsAndResultsPreserveReferenceOwnership() async throws {
        let echo = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((NSObject) -> NSObject).self, genericArguments: [.type(NSObject.self)])
        weak var observed: NSObject?
        var result: NSObject?
        do {
            let object = NSObject()
            observed = object
            result = try unsafe echo.unsafeInvoke(object)
            #expect(result === object)
        }
        withExtendedLifetime(result) { #expect(observed != nil) }
        result = nil
        #expect(observed == nil)
        let choose = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.chooseGeneric<A>(A, () -> A, Swift.Bool) -> A",
            as: ((String, NativeSwiftClosure<() -> String>, Bool) -> String).self, genericArguments: [.type(String.self)])
        let callback = try NativeSwiftClosure { "from callback" }
        #expect(try unsafe choose.unsafeInvoke("input", callback, false) == "input")
        #expect(try unsafe choose.unsafeInvoke("input", callback, true) == "from callback")
    }

    @Test func failedConversionDoesNotEnterNativeCode() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.countedGeneric<A>(A, Swift.Int64, Swift.UnsafeMutablePointer<Swift.Int32>) -> A",
            as: ((String, RejectGenericArgument, UnsafeMutablePointer<Int32>) -> String).self, genericArguments: [.type(String.self)])
        var calls: Int32 = 0
        try withUnsafeMutablePointer(to: &calls) { pointer in
            #expect(throws: GenericConversionFailure.rejected) {
                try unsafe function.unsafeInvoke(String(repeating: "input", count: 100), RejectGenericArgument(), pointer)
            }
        }
        #expect(calls == 0)
    }

    @Test func reabstractedNativeCopiesRetainCapturesAndReleaseAfterFinalUse() async throws {
        let runtime = ABIRuntime.shared
        let store = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.storeGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> String>) -> String).self, genericArguments: [.type(String.self)])
        let fire = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.fireGeneric()", as: (() -> Void).self)
        let clear = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.clearGeneric()", as: (() -> Void).self)
        let state = GenericCaptureState()
        do {
            let capture = GenericCapture(state)
            let callback = try NativeSwiftClosure { capture.value() }
            #expect(try unsafe store.unsafeInvoke(callback).count == 700)
        }
        #expect(state.deaths.withLock { $0 } == 0)
        try unsafe fire.unsafeInvoke()
        try unsafe clear.unsafeInvoke()
        #expect(state.calls.withLock { $0 } == 2)
        #expect(state.deaths.withLock { $0 } == 1)
    }

    @Test func reabstractionIsReleasedWhenLaterConversionFails() async throws {
        let runtime = ABIRuntime.shared
        let function = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.genericCallbackThenArgument<A>(() -> A, Swift.Int64) -> A",
            as: ((NativeSwiftClosure<() -> String>, RejectGenericArgument) -> String).self, genericArguments: [.type(String.self)])
        let state = GenericCaptureState()
        do {
            let capture = GenericCapture(state)
            let callback = try NativeSwiftClosure { capture.value() }
            #expect(throws: GenericConversionFailure.rejected) { try unsafe function.unsafeInvoke(callback, RejectGenericArgument()) }
        }
        #expect(state.calls.withLock { $0 } == 0)
        #expect(state.deaths.withLock { $0 } == 1)
    }

    @Test func emptyGenericResultsRemainFormallyIndirect() async throws {
        let run = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> Void>) -> Void).self, genericArguments: [.type(Void.self)])
        let calls = GenericCaptureState()
        let body = try NativeSwiftClosure { calls.calls.withLock { $0 += 1 } }
        try unsafe run.unsafeInvoke(body)
        #expect(calls.calls.withLock { $0 } == 1)
    }

    @Test func incompatibleSubstitutionsAndUnsupportedFormalShapesFailPreparation() async throws {
        let runtime = ABIRuntime.shared
        await #expect(throws: ABIResolutionError.self) {
            try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
                as: ((Bool) -> Bool).self, genericArguments: [.type(String.self)])
        }
        for declaration in ["Example.run<A, B>(A) -> A", "Example.run<A where A: Swift.Equatable>(A) -> A",
                            "Example.run<A>(Swift.Array<A>) -> A", "Example.run<A>(A) async -> A",
                            "Example.run<A>((A) -> A) -> A"] {
            await #expect(throws: ABIResolutionError.self) {
                try await runtime.swiftFunction(named: declaration, as: ((Bool) -> Bool).self, genericArguments: [.type(Bool.self)])
            }
        }
    }
}
