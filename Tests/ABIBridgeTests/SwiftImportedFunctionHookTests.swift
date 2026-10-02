#if os(macOS) && DEBUG
@testable import ABIBridge
import ABIBridgeCore
import Darwin
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct SwiftImportedFunctionHookTests {
    @Test func chainsTypedArgumentsResultsAndIndependentInvalidation() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: (@Sendable (Int64) -> Int64).self, in: fixture.providerScope)
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
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: (@Sendable (Int64) -> Int64).self, in: fixture.providerScope)
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

    @Test func handlesZeroArgumentsVoidAndStackArguments() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public func zero() -> Int64 { 42 }
        @inline(never) public func touch(_ value: UnsafeMutablePointer<Int64>) { value.pointee += 10 }
        @inline(never) public func many(_ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ e: Int64, _ f: Int64, _ g: Int64, _ h: Int64, _ i: Int64, _ j: Int64, _ k: Int64, _ l: Int64) -> Int64 { a+b+c+d+e+f+g+h+i+j+k+l }
        """, callerExtra: """
        @inline(never) public func importedZero() -> Int64 { zero() }
        @inline(never) public func importedTouch(_ value: UnsafeMutablePointer<Int64>) { touch(value) }
        @inline(never) public func importedMany() -> Int64 { many(1,2,3,4,5,6,7,8,9,10,11,12) }
        """); defer { fixture.cleanup() }
        let zero = try await fixture.runtime.swiftFunction(named: fixture.module + ".zero()", as: (() -> Int64).self, in: fixture.providerScope)
        let zeroOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedZero()", as: (() -> Int64).self, in: fixture.callerScope)
        let zeroHook = try await unsafe zero.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call in
            try call.proceed() + 100
        }
        defer { zeroHook.invalidate() }
        #expect(try unsafe zeroOracle.unsafeInvoke() == 142)
        let touch = try await fixture.runtime.swiftFunction(named: fixture.module + ".touch(_:)", as: ((UnsafeMutablePointer<Int64>) -> Void).self, in: fixture.providerScope)
        let touchOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedTouch(_:)", as: ((UnsafeMutablePointer<Int64>) -> Void).self, in: fixture.callerScope)
        let touchHook = try await unsafe touch.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            value.pointee += 1
            try call.proceed(value)
            value.pointee += 2
        }
        defer { touchHook.invalidate() }
        var value: Int64 = 0
        try withUnsafeMutablePointer(to: &value) { try unsafe touchOracle.unsafeInvoke($0) }
        #expect(value == 13)
        let many = try await fixture.runtime.swiftFunction(named: fixture.module + ".many(_:_:_:_:_:_:_:_:_:_:_:_:)",
            as: ((Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) -> Int64).self, in: fixture.providerScope)
        let manyOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedMany()", as: (() -> Int64).self, in: fixture.callerScope)
        let manyHook = try await unsafe many.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, a,b,c,d,e,f,g,h,i,j,k,l in
            try call.proceed(a,b,c,d,e,f,g,h,i,j,k,l+100)
        }
        defer { manyHook.invalidate() }
        #expect(try unsafe manyOracle.unsafeInvoke() == 178)
    }

    @Test func preservesDisplacementAndSavedDispatcherLifetime() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let replacement = try await fixture.runtime.swiftFunction(named: fixture.module + ".replacementScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            try call.proceed(value + 1)
        }
        let external = try await unsafe target.prepareImportedReplacement(with: replacement, in: fixture.callerScope)
        let saved = try #require(external.slots.first?.original)
        try unsafe external.install()
        #expect(hook.slots[0].status == .displaced)
        #expect(try unsafe oracle.unsafeInvoke(40) == 140)
        #expect(try unsafe saved.unsafeInvoke(40) == 42)
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(40) == 140)
        #expect(try unsafe saved.unsafeInvoke(40) == 41)
        try external.restore()
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
    }

    @Test func failedPublicationKeepsProtectionOnlyRecoveryReachable() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let selection = try ImportedFunctionSelection(resolver: SymbolResolver(), declaration: target.symbol.declaration,
            importer: fixture.callerScope, provider: nil, language: .swift)
        let signature = try SwiftHookCallbackSignature<Int64, Int64>().erased(consumingArguments: false, retaining: target)
        let handler = SwiftHookHandler(failure: { Issue.record("Unexpected: \($0)") }) { frame, values in
            try frame.use { try $0(values) }
        }
        let repaired = Mutex(false)
        let transport = SwiftReplacementTransport(exchange: { _, before, _ in
            var result = ABIPointerSlotResult()
            result.status = Int32(ABIPointerSlotRestoreFailed)
            result.observed = before
            result.restoreProtectionError = KERN_PROTECTION_FAILURE
            result.protectionBefore = VM_PROT_READ
            return result
        }, repair: { _, _, _, _, _, _ in
            var result = ABIPointerSlotResult()
            result.status = Int32(repaired.withLock { $0 } ? ABIPointerSlotComplete : ABIPointerSlotRestoreFailed)
            result.restoreProtectionError = repaired.withLock { $0 } ? 0 : KERN_PROTECTION_FAILURE
            return result
        })
        let registry = SwiftHookRegistry()
        do {
            _ = try await registry.register(selection: selection, signature: signature, handler: handler, transport: transport)
            Issue.record("Expected injected publication failure")
        } catch let error as NativeSwiftHookInstallationError {
            let slot = try #require(error.registration.slots.first)
            #expect(slot.mutation?.didWrite == false)
            #expect(slot.protectionRecovery?.status == Int32(ABIPointerSlotRestoreFailed))
            #expect(try unsafe oracle.unsafeInvoke(40) == 41)
            repaired.withLock { $0 = true }
            try await registry.recover(node: ObjectIdentifier(error.registration.node), records: error.registration.records)
            #expect(error.registration.slots[0].protectionRecovery?.status == Int32(ABIPointerSlotComplete))
        }
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

    @Test func concurrentCallsKeepTheirSnapshotsWhileInvalidationReleasesCaptures() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: fixture.callerScope)
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let released = Mutex(false)
        let failures = Mutex<[String]>([])
        var capture: SwiftHookCapture? = SwiftHookCapture { released.withLock { $0 = true } }
        let hook = try await unsafe target.hookImportedCalls(in: fixture.callerScope,
            onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { [capture] call, value in
            entered.signal()
            guard resume.wait(timeout: .now() + 10) == .success else { throw SwiftHookTestFailure.timeout }
            return try withExtendedLifetime(capture) { try call.proceed(value + 1) }
        }
        capture = nil
        // Both sides of this intentionally blocked native call must progress
        // independently of Swift's bounded cooperative executor on busy runners.
        let observation: (Int64, Bool, Bool) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let done = DispatchSemaphore(value: 0)
                let result = Mutex<Swift.Result<Int64, any Error>?>(nil)
                DispatchQueue.global(qos: .userInitiated).async {
                    let value = Swift.Result { try unsafe oracle.unsafeInvoke(40) }
                    result.withLock { $0 = value }
                    done.signal()
                }
                let didEnter = entered.wait(timeout: .now() + 10) == .success
                hook.invalidate()
                let retainedDuringCall = !released.withLock { $0 }
                resume.signal()
                let didFinish = done.wait(timeout: .now() + 10) == .success
                guard didEnter && didFinish else {
                    continuation.resume(throwing: SwiftHookTestFailure.timeout)
                    return
                }
                do {
                    let value = try result.withLock { try $0!.get() }
                    continuation.resume(returning: (value, retainedDuringCall, released.withLock { $0 }))
                } catch { continuation.resume(throwing: error) }
            }
        }
        #expect(observation.0 == 42 && observation.1 && observation.2)
        #expect(failures.withLock { $0.isEmpty })
        let next = try await unsafe target.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            try call.proceed(value + 1) + 1
        }
        defer { next.invalidate() }
        let sum = try await withThrowingTaskGroup(of: Int64.self) { group in
            for index in 0..<32 { group.addTask { try unsafe oracle.unsafeInvoke(Int64(index)) } }
            return try await group.reduce(Int64(0), +)
        }
        #expect(sum == 592)
    }

    @Test func reusingAnEntryRetainsAdditionalCodeOwnersIndependentlyOfCallbacks() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let target = try await fixture.runtime.swiftFunction(named: fixture.module + ".scalar(_:)", as: ((Int64) -> Int64).self, in: fixture.providerScope)
        let first = try await unsafe target.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in try call.proceed(value) }
        var owner: SwiftHookCapture? = SwiftHookCapture {}
        weak var retainedOwner = owner
        let second = try await unsafe target.hookImportedCalls(in: fixture.callerScope, retaining: owner,
            onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in try call.proceed(value) }
        owner = nil
        first.invalidate(); second.invalidate()
        #expect(retainedOwner != nil)
    }
}

private enum SwiftHookTestFailure: Error { case afterProceed, timeout }

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
