import ABIBridge
import ManagedSwiftFixtures
import Synchronization
import Testing

private final class ClosureCounter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private final class ClosureCapture: Sendable {
    let destroyed: ClosureCounter
    let bias: Int64
    init(_ destroyed: ClosureCounter, bias: Int64 = 7) {
        self.destroyed = destroyed; self.bias = bias
    }
    deinit { destroyed.increment() }
}

struct ClosureHandoffStressTests {
    @Test func repeatedNativeHandoffsPreserveOneOwningEntry() async throws {
        let echo = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.echoClosure(_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>) -> NativeSwiftClosure<(Int64) -> Int64>)
                .self
        )
        let destroyed = ClosureCounter()
        weak var observed: ClosureCapture?
        do {
            let capture = ClosureCapture(destroyed)
            observed = capture
            var callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
            for _ in 0..<10_000 { callback = try unsafe echo.unsafeInvoke(callback) }
            #expect(try unsafe callback.unsafeInvoke(35) == 42)
        }
        #expect(observed == nil)
        #expect(destroyed.count == 1)
    }
}
