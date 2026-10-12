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
                let type = try runtime.resolveSwiftTypeAndWait(
                    named: "ABIBridgeTests.SwiftMemberRenderer"
                )
                let method = try type.resolveMethodAndWait(
                    named: "render(_:)",
                    as: ((Int) -> Int).self
                )
                let getter = try type.resolveGetterAndWait(named: "text", as: (() -> String).self)
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
            type = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
            method = try await type.resolveMethod(named: "render(_:)", as: ((Int) -> Int).self)
            getter = try await type.resolveGetter(named: "text", as: (() -> String).self)
        } else {
            type = try runtime.resolveSwiftTypeAndWait(named: "ABIBridgeTests.SwiftMemberRenderer")
            method = try type.resolveMethodAndWait(named: "render(_:)", as: ((Int) -> Int).self)
            getter = try type.resolveGetterAndWait(named: "text", as: (() -> String).self)
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

    @MainActor @Test(arguments: [false, true])
    func additionalMemberDemandDoesNotWaitForTheEntireTypedPreparation(
        asynchronous: Bool
    ) async throws {
        let runtime = ABIRuntime()
        let pause = SwiftPreparationPause()
        let preparation = Task {
            try await runtime.prepare { runtime in
                defer { pause.finish() }
                let type = try runtime.resolveSwiftTypeAndWait(
                    named: "ABIBridgeTests.SwiftMemberRenderer"
                )
                let initialize = try type.resolveInitializerAndWait(
                    named: "init(text:)",
                    as: ((String) -> AnyObject).self
                )
                _ = try type.resolveSetterAndWait(named: "text", as: String.self)
                _ = try type.resolveStaticMethodAndWait(
                    named: "decorate(_:)",
                    as: ((String) -> String).self
                )
                _ = try type.resolveStaticGetterAndWait(named: "standard", as: (() -> String).self)
                _ = try type.resolveStaticSetterAndWait(named: "count", as: Int.self)
                pause.readyAndWait()
                return (type, initialize)
            }
        }
        defer { pause.release() }
        await pause.waitUntilReady()

        let type: NativeSwiftType
        let initialize: NativeSwiftFunction<(String) -> AnyObject>
        let setter: NativeSwiftMethod<(String) -> Void>
        let decorate: NativeSwiftFunction<(String) -> String>
        let standard: NativeSwiftFunction<() -> String>
        let count: NativeSwiftFunction<(Int) -> Void>
        if asynchronous {
            type = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
            initialize = try await type.resolveInitializer(
                named: "init(text:)",
                as: ((String) -> AnyObject).self
            )
            setter = try await type.resolveSetter(named: "text", as: String.self)
            decorate = try await type.resolveStaticMethod(
                named: "decorate(_:)",
                as: ((String) -> String).self
            )
            standard = try await type.resolveStaticGetter(
                named: "standard",
                as: (() -> String).self
            )
            count = try await type.resolveStaticSetter(named: "count", as: Int.self)
        } else {
            type = try runtime.resolveSwiftTypeAndWait(named: "ABIBridgeTests.SwiftMemberRenderer")
            initialize = try type.resolveInitializerAndWait(
                named: "init(text:)",
                as: ((String) -> AnyObject).self
            )
            setter = try type.resolveSetterAndWait(named: "text", as: String.self)
            decorate = try type.resolveStaticMethodAndWait(
                named: "decorate(_:)",
                as: ((String) -> String).self
            )
            standard = try type.resolveStaticGetterAndWait(
                named: "standard",
                as: (() -> String).self
            )
            count = try type.resolveStaticSetterAndWait(named: "count", as: Int.self)
        }
        #expect(!pause.hasFinished)
        MainActor.assertIsolated()

        let receiver = try unsafe initialize.unsafeInvoke("before") as! SwiftMemberRenderer
        try unsafe setter.unsafeInvoke(on: receiver, "after")
        #expect(receiver.text == "after")
        #expect(try unsafe decorate.unsafeInvoke("value") == "value!")
        #expect(try unsafe standard.unsafeInvoke() == "standard")
        let originalCount = SwiftMemberRenderer.count
        defer { SwiftMemberRenderer.count = originalCount }
        try unsafe count.unsafeInvoke(7)
        #expect(SwiftMemberRenderer.count == 7)

        pause.release()
        let prepared = try await preparation.value
        #expect(type === prepared.0)
        let preparedReceiver =
            try unsafe prepared.1.unsafeInvoke("prepared") as! SwiftMemberRenderer
        #expect(preparedReceiver.text == "prepared")
    }

    @MainActor @Test
    func asynchronousSwiftLookupDoesNotWaitForTheEntireTypedPreparation() async throws {
        let runtime = ABIRuntime()
        let pause = SwiftPreparationPause()
        let preparation = Task {
            try await runtime.prepare { runtime in
                defer { pause.finish() }
                let function = try runtime.resolveSwiftFunctionAndWait(
                    named: "ABIBridgeTests.swiftABIString(_:)",
                    as: ((String) -> String).self
                )
                pause.readyAndWait()
                return function
            }
        }
        defer { pause.release() }
        await pause.waitUntilReady()

        let demanded = try await runtime.resolveSwiftFunction(
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
