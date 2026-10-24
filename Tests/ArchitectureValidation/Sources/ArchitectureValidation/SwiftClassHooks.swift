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
    let type = try await runtime.resolveSwiftType(named: name, in: provider)
    let make = try await runtime.resolve(
        .function(
            "SwiftImportProvider.makeHookRenderer(Swift.Int64) -> " + name,
            as: ((Int64) -> AnyObject).self
        ),
        in: provider
    )
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

    let getter = try await type.resolve(.getter("count", as: (() -> Int64).self))
    let setter = try await type.resolve(.setter("count", as: ((Int64) -> Void).self))
    let method = try await type.resolve(.method("render(_:)", as: ((Int64) -> Int64).self))
    let oracle = try await runtime.resolve(
        .function(
            "SwiftImportCallerControl.hookRender(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self
        ),
        in: caller
    )
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

    let direct = try await type.resolve(.method("directRender(_:)", as: ((Int64) -> Int64).self))
    let directOracle = try await runtime.resolve(
        .function(
            "SwiftImportCallerControl.hookDirectRender(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self
        ),
        in: caller
    )
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

    let textSetter = try await type.resolve(.setter("text", as: ((String) -> Void).self))
    let textGetter = try await type.resolve(.getter("text", as: (() -> String).self))
    let textOracle = try await runtime.resolve(
        .function(
            "SwiftImportCallerControl.hookSetText(\(name), Swift.String) -> Swift.String",
            as: ((AnyObject, String) -> String).self
        ),
        in: caller
    )
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

    let consume = try await type.resolve(
        .method(
            "consume(_:)",
            as: ((Int64) -> Int64).self,
            receiver: .consuming
        )
    )
    let consumeOracle = try await runtime.resolve(
        .function(
            "SwiftImportCallerControl.hookConsume(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self
        ),
        in: caller
    )
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
    let childType = try await runtime.resolveSwiftType(named: childName, in: caller)
    let makeChild = try await runtime.resolve(
        .function(
            "SwiftImportCallerControl.makeCallerRenderer() -> " + childName,
            as: (() -> AnyObject).self
        ),
        in: caller
    )
    let child = try unsafe makeChild.unsafeInvoke()
    let childText = try await childType.resolve(.method("text(_:)", as: ((String) -> String).self))
    let childOracle = try await runtime.resolve(
        .function(
            "SwiftImportCallerControl.classText(SwiftImportProvider.ReplacementRenderer, Swift.String) -> Swift.String",
            as: ((AnyObject, String) -> String).self
        ),
        in: caller
    )
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
    checks += try await validateClassMemberHooks(
        runtime: runtime,
        provider: provider,
        caller: caller,
        onFailure: failure
    )
    checks += try await validateAsyncMethodHooks(runtime: runtime, provider: provider, caller: caller)
    try check(failures.withLock { $0.isEmpty }, "No unexpected class hook failures")
    checks += try await validateSwiftWitnessHooks()
    return ArchitectureReport(mode: "swift-method-hooks", cpuType: ABIValidationCPUType(),
        cpuSubtype: ABIValidationCPUSubtype(), pacCompiled: ABIValidationPACCompiled(), checks: checks, allocationTag: nil)
}

/// Hooks a class func and a class var's accessors in a base and an
/// overriding class, which dispatch through their metatypes' entries.
private func validateClassMemberHooks(
    runtime: ABIRuntime,
    provider: ImageSelector,
    caller: ImageSelector,
    onFailure failure: @escaping @Sendable (any Error) -> Void
) async throws -> [String] {
    var checks: [String] = []
    func check(_ result: Bool, _ message: String) throws {
        guard result else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let baseName = "SwiftImportProvider.ReplacementRenderer"
    let kindOracle = try await runtime.resolve(
        .function(
            "SwiftImportCallerControl.classKind(\(baseName), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self
        ),
        in: caller
    )
    // Sets the class var, then reads it, through the object's metatype.
    let levelOracle = try await runtime.resolve(
        .function(
            "SwiftImportCallerControl.classLevel(\(baseName), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self
        ),
        in: caller
    )
    var objects: [AnyObject] = []
    for factory in ["makeRenderer", "makeOverridingRenderer"] {
        let make = try await runtime.resolve(
            .function(
                "SwiftImportProvider.\(factory)() -> " + baseName,
                as: (() -> AnyObject).self
            ),
            in: provider
        )
        objects.append(try unsafe make.unsafeInvoke())
    }
    let names = ["ReplacementRenderer", "OverridingRenderer"]
    // The override adds 1 to kind and 1000 to level. A hook adds 101 to
    // kind, doubles the stored level, and adds 10_000 to the level it reads.
    func values(_ index: Int, hooked: Bool) throws -> Bool {
        let kind: Int64 = (index == 0 ? 46 : 47) + (hooked ? 101 : 0)
        let level: Int64 = (index == 0 ? 0 : 1000) + (hooked ? 10_010 : 5)
        let kindResult = try unsafe kindOracle.unsafeInvoke(objects[index], 40)
        let levelResult = try unsafe levelOracle.unsafeInvoke(objects[index], 5)
        return kindResult == kind && levelResult == level
    }
    for (index, name) in names.enumerated() {
        let type = try await runtime.resolveSwiftType(
            named: "SwiftImportProvider." + name,
            in: provider
        )
        let kind = try await type.resolve(
            .staticMethod(
                "kind(_:)",
                as: ((Int64) -> Int64).self
            )
        )
        let getter = try await type.resolve(.staticGetter("level", as: (() -> Int64).self))
        let setter = try await type.resolve(.staticSetter("level", as: ((Int64) -> Void).self))
        let hooks = [
            try await unsafe kind.hookVirtualCalls(onFailure: failure) { call, value in
                try call.proceed(value + 1) + 100
            },
            try await unsafe getter.hookVirtualCalls(onFailure: failure) { call in
                try call.proceed() + 10_000
            },
            try await unsafe setter.hookVirtualCalls(onFailure: failure) { call, value in
                try call.proceed(value * 2)
            },
        ]
        defer { hooks.forEach { $0.invalidate() } }
        for other in names.indices {
            let state = other == index ? "hooked" : "unchanged"
            try check(
                try values(other, hooked: other == index),
                "\(name) class func and class var hooks: \(names[other]) \(state)"
            )
        }
        hooks.forEach { $0.invalidate() }
        try check(
            try values(index, hooked: false),
            "\(name) class members pass through after invalidation"
        )
    }
    return checks
}
