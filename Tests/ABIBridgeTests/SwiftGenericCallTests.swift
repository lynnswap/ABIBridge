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
    @Test func genericStorageUsesTheActualTypeInsteadOfItsForeignConversion() async throws {
        let runtime = ABIRuntime.shared
        let echo = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((GenericPointerWrapper?) -> GenericPointerWrapper?).self, substituting: GenericPointerWrapper?.self)
        let value = GenericPointerWrapper(pointer: try #require(UnsafeRawPointer(bitPattern: 0x1000)), marker: 42)
        #expect(MemoryLayout<GenericPointerWrapper?>.size > MemoryLayout<UnsafeRawPointer>.size)
        #expect(try unsafe echo.unsafeInvoke(value) == echoGeneric(Optional(value)))
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)

        let marked = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((NativeSwiftBorrowing<String>) -> NativeSwiftBorrowing<String>).self,
            substituting: NativeSwiftBorrowing<String>.self)
        let input = NativeSwiftBorrowing(String(repeating: "owned", count: 100))
        #expect(try unsafe marked.unsafeInvoke(input).value == echoGeneric(input).value)

        let closure = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((NativeSwiftClosure<() -> Int64>) -> NativeSwiftClosure<() -> Int64>).self,
            substituting: NativeSwiftClosure<() -> Int64>.self)
        let returned = try unsafe closure.unsafeInvoke(NativeSwiftClosure { Int64(42) })
        #expect(try unsafe returned.unsafeInvoke() == 42)
    }

    @Test func capturingCallbacksMatchCompilerGeneratedCalls() async throws {
        let runtime = ABIRuntime.shared
        let boolean = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> Bool>) -> Bool).self, substituting: Bool.self)
        for value in [true, false] {
            let callback = try NativeSwiftClosure { value }
            #expect(try unsafe boolean.unsafeInvoke(callback) == referenceGenericBool(value))
        }
        let stringType = try await runtime.swiftType(named: "Swift.String")
        let string = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> String>) -> String).self, substituting: stringType)
        let input = String(repeating: "managed", count: 100)
        let callback = try NativeSwiftClosure { input + "!" }
        for _ in 0..<20 {
            #expect(try unsafe string.unsafeInvoke(callback) == referenceGenericString(input))
        }
    }

    @MainActor @Test func nonescapingApplyKeepsCallerIsolation() async throws {
        let run = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.runGeneric<A>(() -> A) -> A",
            as: ((NativeSwiftClosure<() -> Bool>) -> Bool).self, substituting: Bool.self)
        var calls = 0
        let result = try unsafe NativeSwiftClosure<() -> Bool>.withUnsafeNonescaping({ calls += 1; return calls == 1 }) {
            try unsafe run.unsafeInvoke($0)
        }
        #expect(result && calls == 1)
    }

    @Test func genericArgumentsAndResultsPreserveReferenceOwnership() async throws {
        let echo = try await ABIRuntime.shared.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
            as: ((NSObject) -> NSObject).self, substituting: NSObject.self)
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
            as: ((String, NativeSwiftClosure<() -> String>, Bool) -> String).self, substituting: String.self)
        let callback = try NativeSwiftClosure { "from callback" }
        #expect(try unsafe choose.unsafeInvoke("input", callback, false) == "input")
        #expect(try unsafe choose.unsafeInvoke("input", callback, true) == "from callback")
    }

    @Test func failedConversionDoesNotEnterNativeCode() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.countedGeneric<A>(A, Swift.Int64, Swift.UnsafeMutablePointer<Swift.Int32>) -> A",
            as: ((String, RejectGenericArgument, UnsafeMutablePointer<Int32>) -> String).self, substituting: String.self)
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
            as: ((NativeSwiftClosure<() -> String>) -> String).self, substituting: String.self)
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
            as: ((NativeSwiftClosure<() -> String>, RejectGenericArgument) -> String).self, substituting: String.self)
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
            as: ((NativeSwiftClosure<() -> Void>) -> Void).self, substituting: Void.self)
        let calls = GenericCaptureState()
        let body = try NativeSwiftClosure { calls.calls.withLock { $0 += 1 } }
        try unsafe run.unsafeInvoke(body)
        #expect(calls.calls.withLock { $0 } == 1)
    }

    @Test func incompatibleSubstitutionsAndUnsupportedFormalShapesFailPreparation() async throws {
        let runtime = ABIRuntime.shared
        await #expect(throws: ABIResolutionError.self) {
            try await runtime.swiftFunction(named: "ManagedSwiftFixtures.echoGeneric<A>(A) -> A",
                as: ((Bool) -> Bool).self, substituting: String.self)
        }
        for declaration in ["Example.run<A, B>(A) -> A", "Example.run<A where A: Swift.Equatable>(A) -> A",
                            "Example.run<A>(Swift.Array<A>) -> A", "Example.run<A>(A) async -> A",
                            "Example.run<A>((A) -> A) -> A"] {
            await #expect(throws: ABIResolutionError.self) {
                try await runtime.swiftFunction(named: declaration, as: ((Bool) -> Bool).self, substituting: Bool.self)
            }
        }
    }
}
