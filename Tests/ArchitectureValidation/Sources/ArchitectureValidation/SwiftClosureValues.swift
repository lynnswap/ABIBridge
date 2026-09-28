import ABIBridge
import CoreGraphics
import SwiftReplacementFixtures
import Synchronization

private final class ClosureProbeCounter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private final class ClosureProbeCapture: Sendable {
    let counter: ClosureProbeCounter
    let bias: Int64 = 7
    init(_ counter: ClosureProbeCounter) { self.counter = counter }
    deinit { counter.increment() }
}

@MainActor func validateSwiftClosureValues() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let apply = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callClosureValue(_:_:)",
        as: ((NativeSwiftClosure<Int64, Int64>, Int64) -> Int64).self
    )
    let callback = try NativeSwiftClosure { (value: Int64) in value + 7 }
    try check(try unsafe apply.unsafeInvoke(callback, 35) == 42,
              "Compiled native caller invokes the generated concrete closure")
    try check(try unsafe callback.unsafeInvoke(35) == 42,
              "The retained closure invokes its entry with the hidden context")

    let retain = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.holdClosureValue(_:)",
        as: ((NativeSwiftClosure<Int64, Int64>) -> ClosureValueHolder).self
    )
    let destroyed = ClosureProbeCounter()
    weak var observed: ClosureProbeCapture?
    var holder: ClosureValueHolder?
    do {
        let capture = ClosureProbeCapture(destroyed)
        observed = capture
        let callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
        holder = try unsafe retain.unsafeInvoke(callback)
    }
    try withExtendedLifetime(holder) {
        try check(observed != nil && destroyed.count == 0,
                  "Native escaping storage retains the capture and generated entry")
    }
    try check(holder!(35) == 42, "Saved native closure calls after its Swift wrapper is released")
    holder = nil
    try check(observed == nil && destroyed.count == 1, "Final native closure release destroys captures once")

    let factory = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.makeStringClosureValue(_:)",
        as: ((String) -> NativeSwiftClosure<String, String>).self
    )
    let prefix = String(repeating: "owned prefix ", count: 100)
    let returned = try unsafe factory.unsafeInvoke(prefix)
    try check(try unsafe returned.unsafeInvoke("result") == prefix + "result",
              "Returned Swift capture context preserves String ownership and authentication")

    let applyRect = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callRectClosureValue(_:_:)",
        as: ((NativeSwiftClosure<CGRect, CGRect>, CGRect) -> CGRect).self
    )
    let translate = try NativeSwiftClosure { (value: CGRect) in value.offsetBy(dx: 3, dy: 4) }
    let rectangle = CGRect(x: 1, y: 2, width: 5, height: 6)
    try check(try unsafe applyRect.unsafeInvoke(translate, rectangle) == rectangle.offsetBy(dx: 3, dy: 4),
              "Imported value identity and floating aggregate registers match the native closure")

    let applyPointer = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callPointerClosureValue(_:_:)",
        as: ((NativeSwiftClosure<Int64, UnsafePointer<Int64>?>, UnsafePointer<Int64>?) -> Int64).self
    )
    let read = try NativeSwiftClosure { (value: UnsafePointer<Int64>?) -> Int64 in value?.pointee ?? -1 }
    var number: Int64 = 42
    let result = try withUnsafePointer(to: &number) { try unsafe applyPointer.unsafeInvoke(read, $0) }
    try check(result == 42, "Typed-pointer substitution matches the native closure discriminator")
    try check(try unsafe applyPointer.unsafeInvoke(read, nil) == -1, "Optional pointer preserves its nil representation")

    let applyVoid = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callVoidClosureValue(_:)",
        as: ((NativeSwiftClosure<Void>) -> Void).self
    )
    let calls = ClosureProbeCounter()
    let empty = try NativeSwiftClosure<Void> { calls.increment() }
    try unsafe applyVoid.unsafeInvoke(empty)
    try check(calls.count == 1, "Zero-argument Void closure matches the native signature")
    return checks
}
