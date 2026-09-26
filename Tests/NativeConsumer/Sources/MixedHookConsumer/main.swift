import ABIBridge
import ABIBridgeCore
import Foundation
import HookFixture

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func take() -> [Int] { lock.lock(); defer { lock.unlock() }; let result = values; values = []; return result }
}
private let events = Events()
let type: AnyClass = ABIHookFixtureClass()
let swift = try unsafe ABIRuntime.shared.hookMethod(on: type, selector: "add:to:",
    as: ((Int32, Int32) -> Int32).self, onFailure: { _ in events.append(999) }) { call, a, b in
        events.append(10); let result = try call.proceed(a,b); events.append(-10); return result + 10
    }
let native = ABIHookFixtureInstallMethod(Unmanaged.passRetained(events).toOpaque(), { context, event in
    Unmanaged<Events>.fromOpaque(context!).takeUnretainedValue().append(Int(event))
}, { context in
    let events = Unmanaged<Events>.fromOpaque(context!).takeRetainedValue(); events.append(100)
})!
let receiver = ABIHookFixtureCreate(0)!
precondition(ABIHookFixtureAdd(receiver, 20, 21) == 52)
precondition(events.take() == [20,10,-10,-20])
swift.invalidate()
precondition(ABIHookFixtureAdd(receiver, 20, 21) == 42)
precondition(events.take() == [20,-20])
ABIInvalidateObjCMethodHook(native)
precondition(events.take() == [100])
ABIReleaseObjCMethodHook(native)
precondition(events.take().isEmpty)
ABIHookFixtureRelease(receiver)

let initialization = try unsafe ABIRuntime.shared.hookInitializer(on: type, selector: "initWithSeed:",
    as: ((Int32) -> NSObject?).self, onFailure: { _ in events.append(999) },
    transformingArguments: { $0 < 0 ? $0 : $0 + 10 }, before: { _ in events.append(10) }, after: { result in
        events.append(-10)
        if let result { let pointer = Unmanaged.passUnretained(result).toOpaque(); ABIHookFixtureSetSeed(pointer, ABIHookFixtureSeed(pointer) + 10) }
    })
let nativeInit = ABIHookFixtureInstallInitializer(Unmanaged.passRetained(events).toOpaque(), { context, event in
    Unmanaged<Events>.fromOpaque(context!).takeUnretainedValue().append(Int(event))
}, { context in
    let events = Unmanaged<Events>.fromOpaque(context!).takeRetainedValue(); events.append(100)
})!
let initialized = ABIHookFixtureCreate(1)!
precondition(ABIHookFixtureSeed(initialized) == 23)
precondition(events.take() == [30,10,-10,-30])
ABIHookFixtureRelease(initialized)
precondition(ABIHookFixtureCreate(-1) == nil)
precondition(events.take() == [30,10,-10,-30])
initialization.invalidate(); ABIReleaseObjCMethodHook(nativeInit)
precondition(events.take() == [100])
print("Mixed Swift/C hook consumer passed")
