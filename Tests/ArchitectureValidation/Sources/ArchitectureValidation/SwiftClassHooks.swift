import ABIBridge
import ArchitectureFixtures
import Foundation
import Synchronization

/// Verifies managed class receivers through the host's signed import fixtures.
@MainActor public func runSwiftClassHookValidation() async throws -> ArchitectureReport {
    let runtime = ABIRuntime()
    let root = Bundle.main.bundleURL.appendingPathComponent("Frameworks")
    func path(_ name: String) -> ImageSelector {
        .path(root.appendingPathComponent("\(name).framework/\(name)"))
    }
    let provider = path("SwiftImportProvider"), caller = path("SwiftImportCallerControl")
    let name = "SwiftImportProvider.HookRenderer"
    let type = try await runtime.swiftType(named: name, in: provider)
    let make = try await runtime.swiftFunction(named: "SwiftImportProvider.makeHookRenderer(Swift.Int64) -> " + name,
        as: ((Int64) -> AnyObject).self, in: provider)
    var object: AnyObject? = try unsafe make.unsafeInvoke(10)
    weak var observed = object
    let identity = ObjectIdentifier(object!)
    let failures = Mutex<[String]>([])
    let failure: @Sendable (any Error) -> Void = { error in failures.withLock { $0.append(String(describing: error)) } }
    var checks: [String] = []
    func check(_ result: Bool, _ message: String) throws {
        guard result else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }

    let getter = try await type.getter(named: "count", as: (() -> Int64).self)
    let setter = try await type.setter(named: "count", as: Int64.self)
    let method = try await type.method(named: "render(_:)", as: ((Int64) -> Int64).self)
    let oracle = try await runtime.swiftFunction(named: "SwiftImportCallerControl.hookRender(\(name), Swift.Int64) -> Swift.Int64",
        as: ((AnyObject, Int64) -> Int64).self, in: caller)
    let first = try await unsafe method.hookVirtualCalls(onFailure: failure) { call, value in
        let receiver = try call.receiver(as: AnyObject.self)
        guard ObjectIdentifier(receiver) == identity else { throw ArchitectureValidationFailure(description: "Receiver identity") }
        try unsafe setter.unsafeInvoke(on: receiver, Int64(20))
        let result = try call.proceed(value + 1)
        try unsafe setter.unsafeInvoke(on: receiver, Int64(30))
        return result + 100
    }
    defer { first.invalidate() }
    try check(try unsafe oracle.unsafeInvoke(object!, 2) == 123, "Virtual closure edits receiver properties before and after proceeding")
    try check(try unsafe getter.unsafeInvoke(on: object!) == 30, "Receiver edits reach the original object")
    let second = try await unsafe method.hookVirtualCalls(onFailure: failure) { call, value in try call.proceed(value * 2) + 1000 }
    defer { second.invalidate() }
    try check(try unsafe oracle.unsafeInvoke(object!, 2) == 1125, "Class metadata registrations share an ordered chain")
    first.invalidate()
    try check(try unsafe oracle.unsafeInvoke(object!, 2) == 1034, "Removing one virtual hook preserves the other")
    second.invalidate()
    try check(try unsafe oracle.unsafeInvoke(object!, 2) == 32, "Virtual invalidation preserves callable pass-through code")

    let direct = try await type.method(named: "directRender(_:)", as: ((Int64) -> Int64).self)
    let directOracle = try await runtime.swiftFunction(named: "SwiftImportCallerControl.hookDirectRender(\(name), Swift.Int64) -> Swift.Int64",
        as: ((AnyObject, Int64) -> Int64).self, in: caller)
    let imported = try await unsafe direct.hookImportedCalls(in: caller, using: runtime, onFailure: failure) { call, value in
        guard ObjectIdentifier(try call.receiver(as: AnyObject.self)) == identity else {
            throw ArchitectureValidationFailure(description: "Imported receiver identity")
        }
        return try call.proceed(value + 1) + 100
    }
    defer { imported.invalidate() }
    try check(try unsafe directOracle.unsafeInvoke(object!, 2) == 133, "Imported final methods preserve their hidden receiver")
    imported.invalidate()
    try check(try unsafe directOracle.unsafeInvoke(object!, 2) == 32, "Imported member fallback remains callable")

    let textSetter = try await type.setter(named: "text", as: String.self)
    let textGetter = try await type.getter(named: "text", as: (() -> String).self)
    let textOracle = try await runtime.swiftFunction(named: "SwiftImportCallerControl.hookSetText(\(name), Swift.String) -> Swift.String",
        as: ((AnyObject, String) -> String).self, in: caller)
    let setHook = try await unsafe textSetter.hookVirtualCalls(onFailure: failure) { call, value in try call.proceed(value + " set") }
    let getHook = try await unsafe textGetter.hookVirtualCalls(onFailure: failure) { call in try call.proceed() + " get" }
    defer { setHook.invalidate(); getHook.invalidate() }
    let input = String(repeating: "owned setter argument", count: 100)
    for _ in 0..<20 {
        guard try unsafe textOracle.unsafeInvoke(object!, input) == input + " set get" else {
            throw ArchitectureValidationFailure(description: "Getter/setter ownership")
        }
    }
    checks.append("Setter argument ownership and getter String results survive repeated virtual calls")
    setHook.invalidate(); getHook.invalidate()

    let consume = try await type.method(named: "consume(_:)", as: ((Int64) -> Int64).self, consuming: true)
    let consumeOracle = try await runtime.swiftFunction(named: "SwiftImportCallerControl.hookConsume(\(name), Swift.Int64) -> Swift.Int64",
        as: ((AnyObject, Int64) -> Int64).self, in: caller)
    let consumed = try await unsafe consume.hookVirtualCalls(onFailure: failure) { call, value in
        if value == 0 { return 1000 }
        _ = try call.proceed(value + 1)
        let result = try call.proceed(value + 2)
        guard ObjectIdentifier(try call.receiver(as: AnyObject.self)) == identity else {
            throw ArchitectureValidationFailure(description: "Consumed receiver lifetime")
        }
        return result
    }
    defer { consumed.invalidate() }
    try check(try unsafe consumeOracle.unsafeInvoke(object!, 2) == 34, "Consuming methods receive an independent reference per continuation")
    try check(try unsafe consumeOracle.unsafeInvoke(object!, 0) == 1000, "Skipping a consuming implementation releases its incoming ownership")
    consumed.invalidate()
    try check(try unsafe consumeOracle.unsafeInvoke(object!, 2) == 32, "Consuming fallback preserves the compiler ownership convention")
    let childName = "SwiftImportCallerControl.CallerOverridingRenderer"
    let childType = try await runtime.swiftType(named: childName, in: caller)
    let makeChild = try await runtime.swiftFunction(named: "SwiftImportCallerControl.makeCallerRenderer() -> " + childName,
        as: (() -> AnyObject).self, in: caller)
    let child = try unsafe makeChild.unsafeInvoke()
    let childText = try await childType.method(named: "text(_:)", as: ((String) -> String).self)
    let childOracle = try await runtime.swiftFunction(named: "SwiftImportCallerControl.classText(SwiftImportProvider.ReplacementRenderer, Swift.String) -> Swift.String",
        as: ((AnyObject, String) -> String).self, in: caller)
    let virtualChild = try await unsafe childText.hookVirtualCalls(onFailure: failure) { call, value in try call.proceed(value + "V") + "v" }
    defer { virtualChild.invalidate() }
    let importedChild = try await unsafe childText.hookImportedCalls(in: caller, using: runtime, onFailure: failure) { call, value in try call.proceed(value + "I") + "i" }
    defer { importedChild.invalidate() }
    try check(importedChild.slots.contains { $0.address == virtualChild.address && $0.mutation == nil },
        "Import and class metadata selection share the same authenticated inherited entry")
    try check(try unsafe childOracle.unsafeInvoke(child, "x") == "method:xIVvi", "Mixed entry selection keeps a single callback chain")
    importedChild.invalidate(); virtualChild.invalidate()
    try check(try unsafe childOracle.unsafeInvoke(child, "x") == "method:x", "Inherited shared entry passes through after invalidation")

    object = nil
    try check(observed == nil, "Published dispatchers do not retain receiver instances")
    try check(failures.withLock { $0.isEmpty }, "No unexpected class hook failures")
    return ArchitectureReport(mode: "swift-method-hooks", cpuType: ABIValidationCPUType(),
        cpuSubtype: ABIValidationCPUSubtype(), pacCompiled: ABIValidationPACCompiled(), checks: checks, allocationTag: nil)
}
