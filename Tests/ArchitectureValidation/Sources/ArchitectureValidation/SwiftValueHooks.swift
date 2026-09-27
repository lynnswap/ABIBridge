import ABIBridge
import ArchitectureFixtures
import Foundation
import Synchronization

private enum ValueHookProbeFailure: Error { case afterProceed }

/// Verifies concrete value receivers against separately compiled Swift callers.
@MainActor public func runSwiftValueHookValidation() async throws -> ArchitectureReport {
    let runtime = ABIRuntime()
    let root = Bundle.main.bundleURL.appendingPathComponent("Frameworks")
    func path(_ name: String) -> ImageSelector {
        .path(root.appendingPathComponent("\(name).framework/\(name)"))
    }
    let provider = path("SwiftImportProvider"), caller = path("SwiftImportCallerControl")
    var checks: [String] = []
    func check(_ result: Bool, _ message: String) throws {
        guard result else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let failures = Mutex<[String]>([])
    let failure: @Sendable (any Error) -> Void = { error in failures.withLock { $0.append(String(describing: error)) } }
    let counter = try await runtime.swiftType(named: "SwiftImportProvider.HookCounter", as: Int64.self, in: provider)
    let adding = try await counter.method(named: "adding(_:)", as: ((Int64) -> Int64).self)
    let addCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.hookValueAdd(_:)",
        as: ((Int64) -> Int64).self, in: caller)
    let addHook = try await unsafe adding.hookImportedCalls(in: caller, using: runtime, onFailure: failure) { call, value in
        guard try call.receiver(as: Int64.self) == 40 else { throw ArchitectureValidationFailure(description: "Register self snapshot") }
        return try call.proceed(value + 1) + 100
    }
    defer { addHook.invalidate() }
    try check(try unsafe addCaller.unsafeInvoke(2) == 143, "Register-passed self remains separate from explicit arguments")
    addHook.invalidate()
    try check(try unsafe addCaller.unsafeInvoke(2) == 42, "Value receiver fallback survives invalidation")

    let increment = try await counter.method(named: "increment(_:)", as: ((Int64) -> Int64).self, mutating: true)
    let incrementCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.hookValueIncrement(_:_:)",
        as: ((Int64, Int64) -> Int64).self, in: caller)
    let incrementHook = try await unsafe increment.hookImportedCalls(in: caller, using: runtime, onFailure: failure) { call, delta in
        let before = try call.receiver(as: Int64.self)
        let result = try call.proceed(delta + 1)
        guard try call.receiver(as: Int64.self) == before + delta + 1 else { throw ArchitectureValidationFailure(description: "Mutating self snapshot") }
        if delta == 3 { throw ValueHookProbeFailure.afterProceed }
        return result + 100
    }
    defer { incrementHook.invalidate() }
    try check(try unsafe incrementCaller.unsafeInvoke(40, 2) == 43143, "Native mutation writes through the original receiver address")
    try check(try unsafe incrementCaller.unsafeInvoke(40, 3) == 44044, "Failure after proceeding preserves receiver mutation and the completed result")
    incrementHook.invalidate()

    let wide = try await runtime.swiftType(named: "SwiftImportProvider.HookWideValue", as: VirtualPayload.self, in: provider)
    for (member, callName, consuming) in [("sum", "hookWideValueSum", false), ("consume", "hookWideValueConsume", true)] {
        let method = try await wide.method(named: member + "(_:)", as: ((Int64) -> Int64).self, consuming: consuming)
        let call = try await runtime.swiftFunction(named: "SwiftImportCallerControl." + callName + "(_:_:)",
            as: ((Int64, Int64) -> Int64).self, in: caller)
        let hook = try await unsafe method.hookImportedCalls(in: caller, using: runtime, onFailure: failure) { call, value in
            let receiver = try call.receiver(as: VirtualPayload.self)
            guard receiver.a == 40 && receiver.e == 44 else { throw ArchitectureValidationFailure(description: "Indirect self snapshot") }
            _ = try call.proceed(value + 1)
            return try call.proceed(value + 2) + 100
        }
        defer { hook.invalidate() }
        try check(try unsafe call.unsafeInvoke(40, 2) == 314, "Indirect " + member + " receiver preserves its native layout and ownership")
        hook.invalidate()
    }

    let textType = try await runtime.swiftType(named: "SwiftImportProvider.HookTextValue", as: String.self, in: provider)
    let consume = try await textType.method(named: "consume()", as: (() -> String).self, consuming: true)
    let textCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.hookValueConsumeText(_:)",
        as: ((String) -> String).self, in: caller)
    let consumed = try await unsafe consume.hookImportedCalls(in: caller, using: runtime, onFailure: failure) { call in
        let value = try call.receiver(as: String.self)
        if value == "skip" { return "skipped" }
        _ = try call.proceed()
        let result = try call.proceed()
        guard try call.receiver(as: String.self) == value else { throw ArchitectureValidationFailure(description: "Consumed String snapshot") }
        return result + " edited"
    }
    defer { consumed.invalidate() }
    let input = String(repeating: "owned value receiver", count: 100)
    for _ in 0..<20 {
        guard try unsafe textCaller.unsafeInvoke(input) == "value:" + input + " edited" else {
            throw ArchitectureValidationFailure(description: "Consumed String continuation")
        }
    }
    checks.append("Consumed String self is copied independently for repeated continuations")
    try check(try unsafe textCaller.unsafeInvoke("skip") == "skipped", "Skipping the original disposes of consumed value ownership")
    consumed.invalidate()
    try check(try unsafe textCaller.unsafeInvoke(input) == "value:" + input, "Consumed value fallback retains its compiler convention")

    let append = try await textType.method(named: "append(_:)", as: ((String) -> String).self, mutating: true)
    let appendCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.hookValueAppendText(_:_:)",
        as: ((String, String) -> String).self, in: caller)
    let appendHook = try await unsafe append.hookImportedCalls(in: caller, using: runtime, onFailure: failure) { call, suffix in
        let before = try call.receiver(as: String.self)
        let result = try call.proceed(suffix + " edited")
        guard try call.receiver(as: String.self) == before + suffix + " edited" else { throw ArchitectureValidationFailure(description: "String writeback snapshot") }
        return result + " returned"
    }
    defer { appendHook.invalidate() }
    try check(try unsafe appendCaller.unsafeInvoke(input, " suffix") == input + " suffix edited returned|" + input + " suffix edited",
        "Mutating String self updates caller storage and subsequent snapshots")
    appendHook.invalidate()

    let stack = try await counter.method(named: "stack(_:_:_:_:_:_:_:_:_:_:_:_:)",
        as: ((Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) -> Int64).self)
    let stackCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.hookValueStack()", as: (() -> Int64).self, in: caller)
    let stacked = try await unsafe stack.hookImportedCalls(in: caller, using: runtime, onFailure: failure) { call,a,b,c,d,e,f,g,h,i,j,k,l in
        guard try call.receiver(as: Int64.self) == 40 else { throw ArchitectureValidationFailure(description: "Stack self snapshot") }
        return try call.proceed(a+1,b,c,d,e,f,g,h,i,j,k,l+100)
    }
    defer { stacked.invalidate() }
    try check(try unsafe stackCaller.unsafeInvoke() == 219, "Stack arguments preserve the trailing value receiver")
    try check(failures.withLock { $0 } == ["afterProceed"], "Only the deliberate callback failure is reported")
    return ArchitectureReport(mode: "swift-value-hooks", cpuType: ABIValidationCPUType(),
        cpuSubtype: ABIValidationCPUSubtype(), pacCompiled: ABIValidationPACCompiled(), checks: checks, allocationTag: nil)
}
