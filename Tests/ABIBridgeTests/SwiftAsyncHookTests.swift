#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

@Suite(.serialized)
struct SwiftAsyncHookTests {
    @Test func importedAsyncChainsUseTheNativeTaskAndOutliveSuspension() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public nonisolated(nonsending) func hookAsync(_ value: Int64) async -> Int64 {
            await Task.yield()
            return value + 1
        }
        """, callerExtra: """
        @inline(never) public nonisolated(nonsending) func importedAsync(_ value: Int64) async -> Int64 {
            await hookAsync(value)
        }
        """)
        defer { fixture.cleanup() }
        typealias Signature = nonisolated(nonsending) (Int64) async -> Int64
        let function = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookAsync(_:)",
            as: Signature.self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsync(_:)",
            as: Signature.self, in: fixture.callerScope)
        #expect(try unsafe await oracle.unsafeInvoke(1) == 2)
        let first = try unsafe await function.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                await Task.yield()
                return try await call.proceed(value + 10) * 2
            }
        defer { first.invalidate() }
        let second = try unsafe await function.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                try await call.proceed(value + 3) + 5
            }
        defer { second.invalidate() }
        #expect(try unsafe await oracle.unsafeInvoke(1) == 35)
        first.invalidate()
        #expect(try unsafe await oracle.unsafeInvoke(1) == 10)
        second.invalidate()
        #expect(try unsafe await oracle.unsafeInvoke(1) == 2)
    }
    @Test func genericAsyncBindingsPassUnmatchedCallsWithoutDecodingThem() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public nonisolated(nonsending) func hookAsyncEcho<T>(_ value: T) async -> T {
            await Task.yield()
            return value
        }
        """, callerExtra: """
        @inline(never) public nonisolated(nonsending) func echoInteger(_ value: Int64) async -> Int64 { await hookAsyncEcho(value) }
        @inline(never) public nonisolated(nonsending) func echoText(_ value: String) async -> String { await hookAsyncEcho(value) }
        """)
        defer { fixture.cleanup() }
        let integer = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookAsyncEcho(_:)",
            as: (nonisolated(nonsending) (Int64) async -> Int64).self, genericArguments: [.type(Int64.self)], in: fixture.providerScope)
        let text = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookAsyncEcho(_:)",
            as: (nonisolated(nonsending) (String) async -> String).self, genericArguments: [.type(String.self)], in: fixture.providerScope)
        let integerOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".echoInteger(_:)",
            as: (nonisolated(nonsending) (Int64) async -> Int64).self, in: fixture.callerScope)
        let textOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".echoText(_:)",
            as: (nonisolated(nonsending) (String) async -> String).self, in: fixture.callerScope)
        #expect(try unsafe await integerOracle.unsafeInvoke(1) == 1)
        #expect(try unsafe await textOracle.unsafeInvoke("native") == "native")
        let first = try unsafe await integer.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in try await call.proceed(value + 10) }
        defer { first.invalidate() }
        #expect(try unsafe await textOracle.unsafeInvoke("unmatched") == "unmatched")
        let second = try unsafe await text.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                await Task.yield()
                return try await call.proceed(value + "-hook")
            }
        defer { second.invalidate() }
        #expect(try unsafe await integerOracle.unsafeInvoke(5) == 15)
        #expect(try unsafe await textOracle.unsafeInvoke(String(repeating: "x", count: 100)) == String(repeating: "x", count: 100) + "-hook")
    }

    @Test func virtualAsyncMethodsKeepTheReceiverAndDescriptorContext() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        open class AsyncHookOwner {
            public init() {}
            @inline(never) open nonisolated(nonsending) func value(_ number: Int64) async -> Int64 {
                await Task.yield()
                return number + 1
            }
        }
        @inline(never) public func makeAsyncHookOwner() -> AsyncHookOwner { AsyncHookOwner() }
        """, callerExtra: """
        @inline(never) public nonisolated(nonsending) func importedAsyncMethod(_ object: AsyncHookOwner, _ number: Int64) async -> Int64 {
            await object.value(number)
        }
        """)
        defer { fixture.cleanup() }
        let name = fixture.module + ".AsyncHookOwner"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.providerScope)
        let method = try await type.method(named: "value(_:)", as: (nonisolated(nonsending) (Int64) async -> Int64).self)
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeAsyncHookOwner() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncMethod(" + name + ", Swift.Int64) async -> Swift.Int64",
            as: (nonisolated(nonsending) (AnyObject, Int64) async -> Int64).self, in: fixture.callerScope)
        let object = try unsafe make.unsafeInvoke()
        let identity = ObjectIdentifier(object)
        let hook = try unsafe await method.hookVirtualCalls(onFailure: { Issue.record($0) }) { call, value in
            #expect(ObjectIdentifier(try call.receiver(as: AnyObject.self)) == identity)
            let result = try await call.proceed(value + 10)
            await Task.yield()
            #expect(ObjectIdentifier(try call.receiver(as: AnyObject.self)) == identity)
            return result + 100
        }
        defer { hook.invalidate() }
        #expect(try unsafe await oracle.unsafeInvoke(object, 1) == 112)
        hook.invalidate()
        #expect(try unsafe await oracle.unsafeInvoke(object, 1) == 2)
    }

    @Test func invalidatedAsyncDescriptorsReserveTheNativeContext() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        open class AsyncTextOwner {
            public init() {}
            @inline(never) open nonisolated(nonsending) func render(_ text: String) async -> String {
                await Task.yield()
                return text + "-native"
            }
        }
        @inline(never) public func makeAsyncTextOwner() -> AsyncTextOwner { AsyncTextOwner() }
        """, callerExtra: """
        @inline(never) public nonisolated(nonsending) func importedAsyncText(_ object: AsyncTextOwner, _ text: String) async -> String {
            await object.render(text)
        }
        """)
        defer { fixture.cleanup() }
        let name = fixture.module + ".AsyncTextOwner"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.providerScope)
        let method = try await type.method(named: "render(_:)", as: (nonisolated(nonsending) (String) async -> String).self)
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeAsyncTextOwner() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let caller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncText(" + name + ", Swift.String) async -> Swift.String",
            as: (nonisolated(nonsending) (AnyObject, String) async -> String).self, in: fixture.callerScope)
        let object = try unsafe make.unsafeInvoke()
        let hook = try unsafe await method.hookVirtualCalls(onFailure: { Issue.record($0) }) { call, value in
            try await call.proceed(value + "-hook")
        }
        #expect(try unsafe await caller.unsafeInvoke(object, "value") == "value-hook-native")
        hook.invalidate()
        for index in 0..<8 {
            let value = String(repeating: "value", count: index * 20)
            #expect(try unsafe await caller.unsafeInvoke(object, value) == value + "-native")
        }
    }

    @Test func asyncFailuresPreserveNativeResultsWithoutRepeatingEffects() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        import Foundation
        @inline(never) public nonisolated(nonsending) func hookAsyncTyped(_ value: Int64, _ count: UnsafeMutablePointer<Int64>) async throws(NSError) -> String {
            await Task.yield()
            count.pointee += 1
            if value < 0 { throw NSError(domain: "async-native", code: Int(value)) }
            return String(repeating: "value:\\(value)", count: 100)
        }
        """, callerExtra: """
        import Foundation
        @inline(never) public nonisolated(nonsending) func importedAsyncTyped(_ value: Int64, _ count: UnsafeMutablePointer<Int64>) async throws(NSError) -> String {
            try await hookAsyncTyped(value, count)
        }
        """)
        defer { fixture.cleanup() }
        typealias Signature = nonisolated(nonsending) (Int64, UnsafeMutablePointer<Int64>) async throws(NSError) -> String
        let function = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookAsyncTyped(_:_:)", as: Signature.self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncTyped(_:_:)", as: Signature.self, in: fixture.callerScope)
        let count = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        count.initialize(to: 0)
        defer { count.deinitialize(count: 1); count.deallocate() }
        _ = try unsafe await oracle.unsafeInvoke(1, count)
        count.pointee = 0
        let failures = Mutex(0)
        let hook = try unsafe await function.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value, count in
                if value == 99 { throw NSError(domain: "async-hook", code: 99) }
                if value == 98 { throw AsyncHookFailure.rejected }
                do {
                    let result = try await call.proceed(value, count)
                    await Task.yield()
                    if value == 97 { throw AsyncHookFailure.rejected }
                    return result + "-hook"
                } catch {
                    if value == -8 { throw AsyncHookFailure.rejected }
                    throw error
                }
            }
        defer { hook.invalidate() }
        #expect(try unsafe await oracle.unsafeInvoke(98, count) == String(repeating: "value:98", count: 100))
        #expect(try unsafe await oracle.unsafeInvoke(97, count) == String(repeating: "value:97", count: 100))
        #expect(count.pointee == 2)
        for (value, domain) in [(Int64(-8), "async-native"), (99, "async-hook")] {
            do { _ = try unsafe await oracle.unsafeInvoke(value, count); Issue.record("Expected native failure") }
            catch let error as NativeSwiftError { error.withUnderlyingError { #expect(($0 as NSError).domain == domain) } }
        }
        #expect(count.pointee == 3 && failures.withLock { $0 } == 3)
    }

    @Test func invalidationAndCancellationKeepTheEnteredTaskAndReleaseCaptures() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public nonisolated(nonsending) func hookAsyncCancellation(_ value: Int64) async -> Int64 {
            await Task.yield()
            return value + (Task.isCancelled ? 1000 : 1)
        }
        """, callerExtra: """
        @inline(never) public nonisolated(nonsending) func importedAsyncCancellation(_ value: Int64) async -> Int64 {
            await hookAsyncCancellation(value)
        }
        """)
        defer { fixture.cleanup() }
        typealias Signature = nonisolated(nonsending) (Int64) async -> Int64
        let function = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookAsyncCancellation(_:)", as: Signature.self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncCancellation(_:)", as: Signature.self, in: fixture.callerScope)
        _ = try unsafe await oracle.unsafeInvoke(1)
        let gate = AsyncHookGate()
        let saved = SavedAsyncHookInvocation<Signature>()
        let releases = Mutex(0)
        let hook: NativeSwiftImportedFunctionHook
        do {
            let capture = AsyncHookCapture { releases.withLock { $0 += 1 } }
            hook = try unsafe await function.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
                onFailure: { Issue.record($0) }) { call, value in
                    saved.value = call
                    #expect(AsyncHookTaskValues.marker == 42)
                    await gate.wait()
                    #expect(AsyncHookTaskValues.marker == 42 && Task.isCancelled)
                    defer { withExtendedLifetime(capture) {} }
                    return try await call.proceed(value)
                }
        }
        let task = Task { try await AsyncHookTaskValues.$marker.withValue(42) { try unsafe await oracle.unsafeInvoke(1) } }
        await gate.waitUntilSuspended()
        hook.invalidate()
        #expect(releases.withLock { $0 } == 0)
        task.cancel()
        await gate.open()
        #expect(try await task.value == 1001)
        #expect(releases.withLock { $0 } == 1)
        await #expect(throws: NativeSwiftHookInvocationError.expiredInvocation) { try await saved.value!.proceed(1) }
        #expect(try unsafe await oracle.unsafeInvoke(1) == 2)
    }
    @Test @MainActor func actorCallbacksResumeOnTheirDeclaredExecutor() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) @MainActor public func hookAsyncActor(_ value: Int64) async -> Int64 {
            MainActor.preconditionIsolated()
            await Task.yield()
            return value + 1
        }
        @inline(never) public nonisolated(nonsending) func hookAsyncInherited(_ value: Int64) async -> Int64 {
            await Task.yield()
            return value + 1
        }
        """, callerExtra: """
        @inline(never) @MainActor public func importedAsyncActor(_ value: Int64) async -> Int64 { await hookAsyncActor(value) }
        @inline(never) public nonisolated(nonsending) func importedAsyncInherited(_ value: Int64) async -> Int64 { await hookAsyncInherited(value) }
        """)
        defer { fixture.cleanup() }
        let actor = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookAsyncActor(_:)",
            as: (@Sendable @concurrent (Int64) async -> Int64).self, in: fixture.providerScope)
        let actorOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncActor(_:)",
            as: (@concurrent (Int64) async -> Int64).self, in: fixture.callerScope)
        _ = try unsafe await actorOracle.unsafeInvoke(1)
        let hook = try unsafe await actor.hookMainActorImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                MainActor.preconditionIsolated()
                await Task.yield()
                let result = try await call.proceed(value + 10)
                MainActor.preconditionIsolated()
                return result + 100
            }
        defer { hook.invalidate() }
        #expect(try unsafe await actorOracle.unsafeInvoke(1) == 112)
        let inherited = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookAsyncInherited(_:)",
            as: (nonisolated(nonsending) (Int64) async -> Int64).self, in: fixture.providerScope)
        let inheritedOracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncInherited(_:)",
            as: (nonisolated(nonsending) (Int64) async -> Int64).self, in: fixture.callerScope)
        _ = try unsafe await inheritedOracle.unsafeInvoke(1)
        let callerHook = try unsafe await inherited.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                MainActor.preconditionIsolated()
                let result = try await call.proceed(value)
                MainActor.preconditionIsolated()
                return result + 10
            }
        defer { callerHook.invalidate() }
        #expect(try unsafe await inheritedOracle.unsafeInvoke(1) == 12)
    }

    @Test func indirectAsyncResultsAndErrorsKeepIndependentOwnedStorage() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public nonisolated(nonsending) func hookAsyncError<E: Error>(_ error: E, _ fail: Bool) async throws(E) -> E {
            await Task.yield()
            if fail { throw error }
            return error
        }
        """, callerExtra: """
        @inline(never) public nonisolated(nonsending) func importedAsyncError<E: Error>(_ error: E, _ fail: Bool) async throws(E) -> E {
            try await hookAsyncError(error, fail)
        }
        """)
        defer { fixture.cleanup() }
        typealias Signature = nonisolated(nonsending) (LargeFailure, Bool) async throws(LargeFailure) -> LargeFailure
        let function = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookAsyncError(_:_:)",
            as: Signature.self, genericArguments: [.type(LargeFailure.self)], in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncError(_:_:)",
            as: Signature.self, genericArguments: [.type(LargeFailure.self)], in: fixture.callerScope)
        let token = ErrorLifetimeToken()
        let input = LargeFailure(token)
        #expect(try unsafe await oracle.unsafeInvoke(input, false).token === token)
        let failures = Mutex(0)
        let hook = try unsafe await function.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { _ in failures.withLock { $0 += 1 } }) { call, error, fail in
                do {
                    _ = try await call.proceed(error, false)
                    return try await call.proceed(error, fail)
                } catch { throw AsyncHookFailure.rejected }
            }
        defer { hook.invalidate() }
        #expect(try unsafe await oracle.unsafeInvoke(input, false).token === token)
        do { _ = try unsafe await oracle.unsafeInvoke(input, true); Issue.record("Expected an indirect native error") }
        catch let error as NativeSwiftError {
            error.withUnderlyingError { #expect(($0 as? LargeFailure)?.token === token && ($0 as? LargeFailure)?.d == 4) }
        }
        #expect(failures.withLock { $0 } == 1)
    }

    @Test func concurrentAndReentrantAsyncCallsKeepTheirOwnContinuations() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public nonisolated(nonsending) func hookAsyncReentrant(_ value: Int64) async -> Int64 { await Task.yield(); return value + 1 }
        """, callerExtra: """
        @inline(never) public nonisolated(nonsending) func importedAsyncReentrant(_ value: Int64) async -> Int64 { await hookAsyncReentrant(value) }
        """)
        defer { fixture.cleanup() }
        typealias Signature = nonisolated(nonsending) (Int64) async -> Int64
        let function = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookAsyncReentrant(_:)", as: Signature.self, in: fixture.providerScope)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncReentrant(_:)", as: Signature.self, in: fixture.callerScope)
        _ = try unsafe await oracle.unsafeInvoke(1)
        let hook = try unsafe await function.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in
                let saved = SavedAsyncHookInvocation<Signature>()
                saved.value = call
                _ = await Task.detached {
                    await #expect(throws: NativeSwiftHookInvocationError.wrongTask) { try await saved.value!.proceed(value) }
                }.value
                let nested = if value == 0 { Int64(0) } else { try unsafe await oracle.unsafeInvoke(value - 1) }
                return nested + (try await call.proceed(value))
            }
        defer { hook.invalidate() }
        let sum = try await withThrowingTaskGroup(of: Int64.self) { group in
            for _ in 0..<16 { group.addTask { try unsafe await oracle.unsafeInvoke(3) } }
            return try await group.reduce(0, +)
        }
        #expect(sum == 160)
    }
    @Test func importedAsyncValueMethodsKeepOriginalReceiverWriteback() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @frozen public struct AsyncHookCounter {
            public var value: Int64
            public init(_ value: Int64) { self.value = value }
            @inline(never) public nonisolated(nonsending) mutating func advance(_ delta: Int64) async -> Int64 {
                await Task.yield()
                value += delta
                return value
            }
        }
        """, callerExtra: """
        @inline(never) public nonisolated(nonsending) func importedAsyncAdvance(_ initial: Int64, _ delta: Int64) async -> Int64 {
            var counter = AsyncHookCounter(initial)
            let result = await counter.advance(delta)
            return counter.value * 100 + result
        }
        """)
        defer { fixture.cleanup() }
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".AsyncHookCounter", as: Int64.self, in: fixture.providerScope)
        let method = try await type.method(named: "advance(_:)", as: (nonisolated(nonsending) (Int64) async -> Int64).self, mutating: true)
        let caller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncAdvance(_:_:)",
            as: (nonisolated(nonsending) (Int64, Int64) async -> Int64).self, in: fixture.callerScope)
        #expect(try unsafe await caller.unsafeInvoke(10, 2) == 1212)
        let hook = try unsafe await method.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, delta in
                #expect(try call.receiver(as: Int64.self) == 10)
                let result = try await call.proceed(delta + 1)
                #expect(try call.receiver(as: Int64.self) == 13)
                return result + 1000
            }
        defer { hook.invalidate() }
        #expect(try unsafe await caller.unsafeInvoke(10, 2) == 2313)
        hook.invalidate()
        #expect(try unsafe await caller.unsafeInvoke(10, 2) == 1212)
    }

    @Test func asyncStackAndFloatingArgumentsSurviveActiveAndInvalidatedHooks() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) @concurrent public func hookAsyncStack(
            _ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ e: Int64,
            _ f: Int64, _ g: Int64, _ h: Int64, _ i: Int64, _ j: Int64,
            _ k: Double, _ l: Double, _ m: Double, _ n: Double, _ o: Double,
            _ p: Double, _ q: Double, _ r: Double, _ s: Double, _ t: Double
        ) async -> Double {
            await Task.yield()
            let integers = a + b + c + d + e + f + g + h + i + j
            let floating = k + l + m + n + o + p + q + r + s + t
            return Double(integers) + floating
        }
        """, callerExtra: """
        @inline(never) @concurrent public func importedAsyncStack() async -> Double {
            await hookAsyncStack(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5)
        }
        """)
        defer { fixture.cleanup() }
        let function = try await fixture.runtime.swiftFunction(named: fixture.module + ".hookAsyncStack(_:_:_:_:_:_:_:_:_:_:_:_:_:_:_:_:_:_:_:_:)",
            as: (@concurrent (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64,
                              Double, Double, Double, Double, Double, Double, Double, Double, Double, Double) async -> Double).self,
            in: fixture.providerScope)
        let caller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncStack()",
            as: (@concurrent () async -> Double).self, in: fixture.callerScope)
        #expect(try unsafe await caller.unsafeInvoke() == 82.5)
        let hook = try unsafe await function.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t in
                await Task.yield()
                return try await call.proceed(a, b, c, d, e, f, g, h, i, j + 10, k, l, m, n, o, p, q, r, s, t + 1.5) * 2
            }
        #expect(try unsafe await caller.unsafeInvoke() == 188)
        hook.invalidate()
        #expect(try unsafe await caller.unsafeInvoke() == 82.5)
    }
    @Test func zeroArgumentAsyncContinuationsBalanceConsumedReceivers() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        public final class AsyncConsumedOwner {
            let deaths: UnsafeMutablePointer<Int64>
            public init(_ deaths: UnsafeMutablePointer<Int64>) { self.deaths = deaths }
            deinit { deaths.pointee += 1 }
            @inline(never) public nonisolated(nonsending) consuming func consume() async -> Int64 {
                await Task.yield()
                return 13
            }
        }
        """, callerExtra: """
        @inline(never) public nonisolated(nonsending) func importedAsyncConsume(_ deaths: UnsafeMutablePointer<Int64>) async -> Int64 {
            await AsyncConsumedOwner(deaths).consume()
        }
        """)
        defer { fixture.cleanup() }
        let type = try await fixture.runtime.swiftType(named: fixture.module + ".AsyncConsumedOwner", in: fixture.providerScope)
        let method = try await type.method(named: "consume()", as: (nonisolated(nonsending) () async -> Int64).self, consuming: true)
        let caller = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".importedAsyncConsume(_:)",
            as: (nonisolated(nonsending) (UnsafeMutablePointer<Int64>) async -> Int64).self, in: fixture.callerScope)
        let deaths = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        deaths.initialize(to: 0)
        defer { deaths.deinitialize(count: 1); deaths.deallocate() }
        #expect(try unsafe await caller.unsafeInvoke(deaths) == 13)
        #expect(deaths.pointee == 1)
        let hook = try unsafe await method.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call in
                let first = try await call.proceed()
                let second = try await call.proceed()
                return first + second
            }
        #expect(try unsafe await caller.unsafeInvoke(deaths) == 26)
        #expect(deaths.pointee == 2)
        hook.invalidate()
        let skipping = try unsafe await method.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { _ in
                await Task.yield()
                return Int64(99)
            }
        #expect(try unsafe await caller.unsafeInvoke(deaths) == 99)
        #expect(deaths.pointee == 3)
        skipping.invalidate()
        #expect(try unsafe await caller.unsafeInvoke(deaths) == 13)
        #expect(deaths.pointee == 4)
    }
    @Test func unmatchedAsyncPacksPassTheirNativeResultVectorsUnchanged() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        @inline(never) public nonisolated(nonsending) func asyncHookPack<each Value>(_ values: repeat each Value) async -> (repeat each Value) {
            await Task.yield()
            return (repeat each values)
        }
        """, callerExtra: """
        @inline(never) public nonisolated(nonsending) func asyncPackEmpty() async { await asyncHookPack() }
        @inline(never) public nonisolated(nonsending) func asyncPackOne(_ value: Int64) async -> Int64 { await asyncHookPack(value) }
        @inline(never) public nonisolated(nonsending) func asyncPackTen() async -> Int64 {
            let values = await asyncHookPack(Int64(1), Int64(2), Int64(3), Int64(4), Int64(5), Int64(6), Int64(7), Int64(8), Int64(9), Int64(10))
            return values.0 + values.1 + values.2 + values.3 + values.4 + values.5 + values.6 + values.7 + values.8 + values.9
        }
        """)
        defer { fixture.cleanup() }
        let function = try await fixture.runtime.swiftFunction(named: fixture.module + ".asyncHookPack(_:)",
            as: (nonisolated(nonsending) (Int64) async -> Int64).self, genericArguments: [.pack([.type(Int64.self)])], in: fixture.providerScope)
        let one = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".asyncPackOne(_:)",
            as: (nonisolated(nonsending) (Int64) async -> Int64).self, in: fixture.callerScope)
        let empty = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".asyncPackEmpty()",
            as: (nonisolated(nonsending) () async -> Void).self, in: fixture.callerScope)
        let ten = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".asyncPackTen()",
            as: (nonisolated(nonsending) () async -> Int64).self, in: fixture.callerScope)
        _ = try unsafe await one.unsafeInvoke(1)
        let hook = try unsafe await function.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record($0) }) { call, value in try await call.proceed(value + 10) }
        defer { hook.invalidate() }
        #expect(try unsafe await one.unsafeInvoke(1) == 11)
        try unsafe await empty.unsafeInvoke()
        #expect(try unsafe await ten.unsafeInvoke() == 55)
        hook.invalidate()
        #expect(try unsafe await one.unsafeInvoke(1) == 1)
        #expect(try unsafe await ten.unsafeInvoke() == 55)
    }

}
private enum AsyncHookFailure: Error { case rejected }
private enum AsyncHookTaskValues { @TaskLocal static var marker: Int = 0 }
private final class SavedAsyncHookInvocation<Signature>: @unchecked Sendable {
    var value: NativeSwiftFunctionInvocation<Signature>?
}
private final class AsyncHookCapture: Sendable {
    let release: @Sendable () -> Void
    init(_ release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}
private actor AsyncHookGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { waiter = $0; observer?.resume(); observer = nil }
    }
    func waitUntilSuspended() async {
        if waiter != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func open() { waiter?.resume(); waiter = nil }
}
#endif
