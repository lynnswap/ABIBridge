#if os(macOS)
import ABIBridge
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct SynchronousSwiftLookupTests {
    @MainActor @Test(arguments: [false, true])
    func swiftMemberDemandDoesNotWaitForTheEntireTypedPreparation(
        asynchronous: Bool
    ) async throws {
        let runtime = ABIRuntime()
        let pause = SwiftPreparationPause()
        let preparation = Task {
            try await runtime.prepare { runtime in
                defer { pause.finish() }
                let type = try runtime.swiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
                let method = try type.method(named: "render(_:)", as: ((Int) -> Int).self)
                let getter = try type.getter(named: "text", as: (() -> String).self)
                pause.readyAndWait()
                return (type, method, getter)
            }
        }
        defer { pause.release() }
        await pause.waitUntilReady()

        let type: NativeSwiftType
        let method: NativeSwiftMethod<(Int) -> Int>
        let getter: NativeSwiftMethod<() -> String>
        if asynchronous {
            type = try await runtime.swiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
            method = try await type.method(named: "render(_:)", as: ((Int) -> Int).self)
            getter = try await type.getter(named: "text", as: (() -> String).self)
        } else {
            (type, method, getter) = try {
                let type = try runtime.swiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
                return (
                    type,
                    try type.method(named: "render(_:)", as: ((Int) -> Int).self),
                    try type.getter(named: "text", as: (() -> String).self)
                )
            }()
        }
        let receiver = SwiftMemberRenderer(text: "observed")
        #expect(try unsafe method.unsafeInvoke(on: receiver, 10) == 18)
        #expect(try unsafe getter.unsafeInvoke(on: receiver) == "observed")
        #expect(!pause.hasFinished)
        MainActor.assertIsolated()

        pause.release()
        let prepared = try await preparation.value
        #expect(type === prepared.0)
        runtime.removeCachedResults()
        receiver.text = "updated"
        #expect(try unsafe method.unsafeInvoke(on: receiver, 10) == 17)
        #expect(try unsafe getter.unsafeInvoke(on: receiver) == "updated")
        #expect(try unsafe prepared.2.unsafeInvoke(on: receiver) == "updated")
    }

    @MainActor @Test
    func asynchronousSwiftLookupDoesNotWaitForTheEntireTypedPreparation() async throws {
        let runtime = ABIRuntime()
        let pause = SwiftPreparationPause()
        let preparation = Task {
            try await runtime.prepare { runtime in
                defer { pause.finish() }
                let function = try runtime.swiftFunction(
                    named: "ABIBridgeTests.swiftABIString(_:)",
                    as: ((String) -> String).self
                )
                pause.readyAndWait()
                return function
            }
        }
        defer { pause.release() }
        await pause.waitUntilReady()

        let demanded = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABIString(_:)",
            as: ((String) -> String).self
        )
        #expect(try unsafe demanded.unsafeInvoke("demanded") == "demanded!")
        #expect(!pause.hasFinished)
        MainActor.assertIsolated()

        pause.release()
        let prepared = try await preparation.value
        #expect(prepared.symbol.declaration == demanded.symbol.declaration)
        #expect(try unsafe prepared.unsafeInvoke("prepared") == "prepared!")
    }

}

private final class SwiftPreparationPause: Sendable {
    private struct State: Sendable {
        var ready = false
        var finished = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    private let released = DispatchSemaphore(value: 0)

    var hasFinished: Bool { state.withLock { $0.finished } }

    func waitUntilReady() async {
        await withCheckedContinuation { waiter in
            let resume = state.withLock { state in
                if state.ready { return true }
                state.waiter = waiter
                return false
            }
            if resume { waiter.resume() }
        }
    }

    func readyAndWait() {
        markReady(finished: false)
        // A regression that waits for the whole closure must fail, not deadlock the test process.
        _ = released.wait(timeout: .now() + 10)
    }

    func finish() { markReady(finished: true) }
    func release() { released.signal() }

    private func markReady(finished: Bool) {
        let waiter = state.withLock { state in
            state.ready = true
            state.finished = finished
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}
#endif
