import ABIBridge
import Foundation
import InitializerFixture

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; events.append(value) }
    func read() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
}
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "InitializerHookConsumer", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private let events = Events()
let hook = try unsafe ABIRuntime.shared.hookInitializer(
    on: ABISwiftInitializerFixture.self, selector: "initWithLeft:right:fail:",
    as: ((Int, Int, Bool) -> ABISwiftInitializerFixture?).self,
    onFailure: { events.append("failure: \($0)") },
    transformingArguments: { left, right, fail in (left + 1, right + 2, fail) },
    before: { _, _, _ in events.append("before") },
    after: { result in events.append(result == nil ? "nil" : "after"); result?.total += 1 }
)
try autoreleasepool {
    let object = ABISwiftInitializerFixture(left: 20, right: 18, fail: false)
    try require(object?.total == 42, "Tuple transformation or initialized-object mutation failed")
    try require(ABISwiftInitializerFixture(left: 0, right: 0, fail: true) == nil, "Nil initialization changed")
}
hook.invalidate()
try require(events.read() == ["before", "after", "before", "nil"], "Initializer callback order failed")
try require(ABISwiftInitializerFixture.prematureRetains == 0, "Uninitialized self was retained")
try require(ABISwiftInitializerFixture.liveObjects == 0, "Initializer ownership leaked")
print("Swift initializer hook consumer passed")
