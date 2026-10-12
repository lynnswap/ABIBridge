#if os(macOS)
import ABIBridge
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct SynchronousSwiftLookupTests {
    @MainActor @Test
    func synchronousDemandDoesNotWaitForTheEntireTypedPreparation() async throws {
        let runtime = ABIRuntime()
        let pause = SwiftPreparationPause()
        let preparation = Task {
            try await runtime.prepare { runtime in
                defer { pause.finish() }
                let type = try runtime.swiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
                let getter = try type.getter(named: "text", as: (() -> String).self)
                pause.readyAndWait()
                return getter
            }
        }
        defer { pause.release() }
        await pause.waitUntilReady()

        let type = try runtime.swiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
        let demanded = try type.getter(named: "text", as: (() -> String).self)
        let receiver = SwiftMemberRenderer(text: "observed")
        #expect(try unsafe demanded.unsafeInvoke(on: receiver) == "observed")
        #expect(!pause.hasFinished)
        MainActor.assertIsolated()

        pause.release()
        let prepared = try await preparation.value
        runtime.removeCachedResults()
        receiver.text = "updated"
        #expect(try unsafe demanded.unsafeInvoke(on: receiver) == "updated")
        #expect(try unsafe prepared.unsafeInvoke(on: receiver) == "updated")
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
