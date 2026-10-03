#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
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
