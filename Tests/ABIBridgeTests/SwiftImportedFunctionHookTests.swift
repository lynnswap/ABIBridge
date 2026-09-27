#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct SwiftImportedFunctionHookTests {
    @Test func chainsTypedArgumentsResultsAndIndependentInvalidation() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let failures = Mutex<[String]>([])
        let first = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
                #expect(call.declaration.name.contains("scalar"))
                #expect(call.description.contains("scalar"))
                return try call.proceed(value + 1) + 10
            }
        defer { first.invalidate() }
        #expect(first.slots.count == 1 && first.slots[0].status == .active)
        #expect(try unsafe oracle.unsafeInvoke(40) == 52)
        let second = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
                try call.proceed(value * 2) + 100
            }
        defer { second.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(40) == 192)
        first.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(40) == 181)
        second.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
        #expect(first.slots[0].status == .invalidated && second.slots[0].status == .invalidated)
        #expect(failures.withLock { $0.isEmpty })
    }

    @Test func editsOwnedStringsAndPreservesLatestResultAfterFailure() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".text(_:)", as: ((String) -> String).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedText(_:)", as: ((String) -> String).self, in: fixture.callerScope)
        let failures = Mutex<[String]>([])
        let calls = Mutex(0)
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
                calls.withLock { $0 += 1 }
                _ = try call.proceed(value + " discarded")
                return try call.proceed(value + " edited") + " returned"
            }
        defer { hook.invalidate() }
        let input = String(repeating: "heap-backed", count: 100)
        for _ in 0..<20 {
            #expect(try unsafe oracle.unsafeInvoke(input) == "original:" + input + " edited returned")
        }
        let failing = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
                _ = try call.proceed(value + " outer")
                throw SwiftHookTestFailure.afterProceed
            }
        #expect(try unsafe oracle.unsafeInvoke(input) == "original:" + input + " outer edited returned")
        failing.invalidate(); hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(input) == "original:" + input)
        #expect(failures.withLock { $0.count } == 1)
        #expect(calls.withLock { $0 } == 21)
    }

    @Test func editsTheIncomingObjectBeforeAndAfterProceeding() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        import Foundation
        @inline(never) public func objectLength(_ value: NSMutableString) -> Int64 { Int64(value.length) }
        """, callerExtra: """
        import Foundation
        @inline(never) public func importedObjectLength(_ value: NSMutableString) -> Int64 { objectLength(value) }
        """); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".objectLength(_:)", as: ((NSMutableString) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedObjectLength(_:)", as: ((NSMutableString) -> Int64).self, in: fixture.callerScope)
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record("Unexpected hook error: \($0)") }) { call, value in
                value.append("!")
                let result = try call.proceed(value)
                value.append("?")
                return result + 100
            }
        defer { hook.invalidate() }
        let value = NSMutableString(string: "abc")
        #expect(try unsafe oracle.unsafeInvoke(value) == 104)
        #expect(value == "abc!?")
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(value) == 5)
    }

    @Test @MainActor func mainActorCallbacksBypassBackgroundEntry() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let state = SwiftHookMainActorState()
        let failures = Mutex<[String]>([])
        let hook = try await unsafe target.hookMainActorImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
                state.calls += 1
                return try call.proceed(value + 1)
            }
        defer { hook.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(40) == 42)
        let background = try await Task.detached { try unsafe oracle.unsafeInvoke(40) }.value
        #expect(background == 41 && state.calls == 1)
        #expect(failures.withLock { $0 } == ["wrongThread"])
    }

    @Test func preservesIndirectResultsThroughTheCompiledCaller() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".payload(Swift.Int64) -> " + fixture.module + ".ReplacementPayload",
            as: ((Int64) -> SwiftABIFive).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedPayload(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record("Unexpected hook error: \($0)") }) { call, value in
                var result = try call.proceed(value + 1)
                result.a += 100
                return result
            }
        defer { hook.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(40) == 315)
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(40) == 210)
    }

    @Test func releasesCapturesAndRejectsEscapedContinuations() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let saved = SavedSwiftHookInvocation()
        let released = Mutex(false)
        var capture: SwiftHookCapture? = SwiftHookCapture { released.withLock { $0 = true } }
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record("Unexpected hook error: \($0)") }) { [capture] call, value in
                withExtendedLifetime(capture) { saved.value = call }
                return try call.proceed(value)
            }
        capture = nil
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
        let escaped = try #require(saved.value)
        #expect(throws: NativeSwiftHookInvocationError.expiredInvocation) { try escaped.proceed(40) }
        #expect(!released.withLock { $0 })
        hook.invalidate()
        #expect(released.withLock { $0 })
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
    }
}

private enum SwiftHookTestFailure: Error { case afterProceed }

@MainActor private final class SwiftHookMainActorState { var calls = 0 }

// The fixture invokes synchronously; this box deliberately lets the test retain
// a non-Sendable continuation after that same call has completed.
private final class SavedSwiftHookInvocation: @unchecked Sendable {
    var value: NativeSwiftFunctionInvocation<Int64, Int64>?
}

private final class SwiftHookCapture: Sendable {
    let release: @Sendable () -> Void
    init(_ release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}
#endif
