import ABIBridge
import ABIBridgeCore
import ArchitectureFixtures
import Darwin
import Foundation
import Synchronization

/// Runs against the three separately built frameworks embedded by ArchitectureTestHost.
@MainActor public func runSwiftFunctionHookValidation() async throws -> ArchitectureReport {
    let runtime = ABIRuntime()
    let root = Bundle.main.bundleURL.appendingPathComponent("Frameworks")
    func path(_ name: String) -> ImageSelector {
        .path(root.appendingPathComponent("\(name).framework/\(name)"))
    }
    let provider = path("SwiftImportProvider")
    let control = path("SwiftImportCallerControl")
    var checks: [String] = []
    func check(_ result: Bool, _ message: String) throws {
        guard result else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let failures = Mutex<[String]>([])
    let failure: @Sendable (any Error) -> Void = { error in
        failures.withLock { $0.append(String(describing: error)) }
    }
    let target = try await runtime.swiftFunction(named: "SwiftImportProvider.scalar(_:)",
        as: ((Int64) -> Int64).self, in: provider)
    let normal = try await runtime.swiftFunction(named: "SwiftImportCaller.importedScalar(_:)",
        as: ((Int64) -> Int64).self, in: path("SwiftImportCaller"))
    do {
        let hook = try await unsafe target.hookImportedCalls(in: path("SwiftImportCaller"), using: runtime,
            onFailure: failure) { call, value in try call.proceed(value + 1) + 10 }
        try check(try unsafe normal.unsafeInvoke(40) == 52, "Normal import accepts a typed Swift closure")
        hook.invalidate()
        try check(try unsafe normal.unsafeInvoke(40) == 41, "Normal import passes through after invalidation")
    } catch let error as NativeSwiftHookInstallationError {
        guard !error.registration.slots.isEmpty,
              error.registration.slots.allSatisfy({ slot in
                  guard let mutation = slot.mutation else { return false }
                  return !mutation.didWrite && mutation.status == ABIPointerSlotProtectFailed
                      && mutation.systemErrorCode == KERN_PROTECTION_FAILURE
                      && mutation.regionFlags & UInt32(VM_REGION_FLAG_TPRO_ENABLED) != 0
              }) else { throw error }
        try check(try unsafe normal.unsafeInvoke(40) == 41, "Normal import reports TPRO refusal without mutation")
    }

    let scalar = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedScalar(_:)",
        as: ((Int64) -> Int64).self, in: control)
    let first = try await unsafe target.hookImportedCalls(in: control, using: runtime, onFailure: failure) { call, value in
        try call.proceed(value + 1) + 10
    }
    defer { first.invalidate() }
    let second = try await unsafe target.hookImportedCalls(in: control, using: runtime, onFailure: failure) { call, value in
        try call.proceed(value * 2) + 100
    }
    defer { second.invalidate() }
    try check(try unsafe scalar.unsafeInvoke(40) == 192, "Typed Swift imported closures share an ordered chain")
    first.invalidate()
    try check(try unsafe scalar.unsafeInvoke(40) == 181, "Independent invalidation preserves the other callback")
    second.invalidate()
    try check(try unsafe scalar.unsafeInvoke(40) == 41, "Empty generated Swift entries call their retained predecessor")

    let opaqueScalar = try await runtime.swiftFunction(named: "SwiftImportProvider.opaqueScalar(Swift.Int64) -> some",
        as: ((Int64) -> Int64).self, declaredAs: "(Swift.Int64) -> some", in: provider)
    let opaqueScalarCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedOpaqueScalar(_:)",
        as: ((Int64) -> Int64).self, in: control)
    let opaqueScalarHook = try await unsafe opaqueScalar.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in try call.proceed(value + 1) + 10 }
    defer { opaqueScalarHook.invalidate() }
    try check(try unsafe opaqueScalarCaller.unsafeInvoke(40) == 52,
        "Opaque scalar hooks preserve the declared indirect return convention")
    opaqueScalarHook.invalidate()
    try check(try unsafe opaqueScalarCaller.unsafeInvoke(40) == 41,
        "Opaque scalar fallback preserves the original indirect result")
    let opaqueText = try await runtime.swiftFunction(named: "SwiftImportProvider.opaqueText(Swift.String) -> some",
        as: ((String) -> String).self, declaredAs: "(Swift.String) -> some", in: provider)
    let opaqueTextCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedOpaqueText(_:)",
        as: ((String) -> String).self, in: control)
    let opaqueTextHook = try await unsafe opaqueText.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in
            _ = try call.proceed(value + " discarded")
            return try call.proceed(value + " edited") + " returned"
        }
    defer { opaqueTextHook.invalidate() }
    let opaqueInput = String(repeating: "owned opaque value ", count: 100)
    for _ in 0..<10 {
        guard try unsafe opaqueTextCaller.unsafeInvoke(opaqueInput) == opaqueInput + " edited original returned" else {
            throw ArchitectureValidationFailure(description: "Opaque String hook lost its owned result")
        }
    }
    checks.append("Repeated opaque continuations retain independent managed results")
    opaqueTextHook.invalidate()
    try check(try unsafe opaqueTextCaller.unsafeInvoke(opaqueInput) == opaqueInput + " original",
        "Opaque managed-result fallback survives invalidation")

    let text = try await runtime.swiftFunction(named: "SwiftImportProvider.text(_:)",
        as: ((String) -> String).self, in: provider)
    let textCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedText(_:)",
        as: ((String) -> String).self, in: control)
    let textHook = try await unsafe text.hookImportedCalls(in: control, using: runtime, onFailure: failure) { call, value in
        _ = try call.proceed(value + " discarded")
        return try call.proceed(value + " edited") + " returned"
    }
    defer { textHook.invalidate() }
    let input = String(repeating: "owned Swift argument", count: 100)
    for _ in 0..<20 {
        guard try unsafe textCaller.unsafeInvoke(input) == "original:" + input + " edited returned" else {
            throw ArchitectureValidationFailure(description: "Owned String callback result")
        }
    }
    checks.append("Heap String arguments and repeated continuation transfer independent owned results")
    textHook.invalidate()
    try check(try unsafe textCaller.unsafeInvoke(input) == "original:" + input, "String fallback survives logical invalidation")

    let payload = try await runtime.swiftFunction(named: "SwiftImportProvider.payload(Swift.Int64) -> SwiftImportProvider.ReplacementPayload",
        as: ((Int64) -> VirtualPayload).self, in: provider)
    let payloadCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedPayload(_:)",
        as: ((Int64) -> Int64).self, in: control)
    let payloadHook = try await unsafe payload.hookImportedCalls(in: control, using: runtime, onFailure: failure) { call, value in
        var result = try call.proceed(value + 1)
        result.a += 100
        return result
    }
    defer { payloadHook.invalidate() }
    try check(try unsafe payloadCaller.unsafeInvoke(40) == 315, "Imported Swift closure preserves caller-provided indirect result storage")
    payloadHook.invalidate()
    try check(try unsafe payloadCaller.unsafeInvoke(40) == 210, "Indirect-result fallback survives logical invalidation")

    let genericInteger = try await runtime.swiftFunction(named: "SwiftImportProvider.composedHookEcho(_:)",
        as: ((Int64) -> Int64).self, genericArguments: [.type(Int64.self)], in: provider)
    let genericText = try await runtime.swiftFunction(named: "SwiftImportProvider.composedHookEcho(_:)",
        as: ((String) -> String).self, genericArguments: [.type(String.self)], in: provider)
    let genericObject = try await runtime.swiftFunction(named: "SwiftImportProvider.composedHookEcho(_:)",
        as: ((NSObject) -> NSObject).self, genericArguments: [.type(NSObject.self)], in: provider)
    let integerCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookInteger(_:)",
        as: ((Int64) -> Int64).self, in: control)
    let stringCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookString(_:)",
        as: ((String) -> String).self, in: control)
    let objectCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookObject(_:)",
        as: ((NSObject) -> NSObject).self, in: control)
    let booleanCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookBoolean(_:)",
        as: ((Bool) -> Bool).self, in: control)
    _ = try unsafe integerCaller.unsafeInvoke(40)
    let integerHook = try unsafe await genericInteger.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in try call.proceed(value + 1) + 10 }
    defer { integerHook.invalidate() }
    let stringHook = try unsafe await genericText.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in try call.proceed(value + " hook") }
    defer { stringHook.invalidate() }
    let objectCalls = Mutex(0)
    let objectHook = try unsafe await genericObject.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in
            objectCalls.withLock { $0 += 1 }
            return try call.proceed(value)
        }
    defer { objectHook.invalidate() }
    try check(try unsafe integerCaller.unsafeInvoke(40) == 51, "Generic scalar hooks select their bound native metadata")
    try check(try unsafe stringCaller.unsafeInvoke(input) == input + " hook", "A second generic binding preserves owned String values")
    let object = NSObject()
    try check(try unsafe objectCaller.unsafeInvoke(object) === object && objectCalls.withLock { $0 } == 1,
        "An unconstrained class substitution retains indirect argument passing")
    try check(try unsafe booleanCaller.unsafeInvoke(false) == false, "Unmatched generic metadata forwards the untouched native frame")
    integerHook.invalidate(); stringHook.invalidate(); objectHook.invalidate()

    let genericFactory = try await runtime.swiftFunction(named: "SwiftImportProvider.composedHookFactory(_:)",
        as: ((Int64) -> NativeSwiftClosure<() -> Int64>).self, genericArguments: [.type(Int64.self)], in: provider)
    let factoryCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookFactoryResult(_:)",
        as: ((Int64) -> Int64).self, in: control)
    _ = try unsafe factoryCaller.unsafeInvoke(40)
    let factoryHook = try unsafe await genericFactory.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in try call.proceed(value + 1) }
    defer { factoryHook.invalidate() }
    try check(try unsafe factoryCaller.unsafeInvoke(40) == 41, "Returned generic closures preserve their declared ABI and pointer authentication")
    factoryHook.invalidate()

    let throwing = try await runtime.swiftFunction(named: "SwiftImportProvider.composedHookError(_:)",
        as: ((Int64) throws(NSError) -> Int64).self, in: provider)
    let throwingCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.composedHookErrorResult(_:)",
        as: ((Int64) throws(NSError) -> Int64).self, in: control)
    _ = try unsafe throwingCaller.unsafeInvoke(40)
    let throwingHook = try unsafe await throwing.hookImportedCalls(in: control, using: runtime,
        onFailure: failure) { call, value in
            if value == 99 { throw NSError(domain: "callback-hook", code: 99) }
            return try call.proceed(value) + 10
        }
    defer { throwingHook.invalidate() }
    try check(try unsafe throwingCaller.unsafeInvoke(40) == 51, "Typed-error hooks preserve ordinary successful results")
    for (value, domain) in [(Int64(-7), "native-hook"), (Int64(99), "callback-hook")] {
        do {
            _ = try unsafe throwingCaller.unsafeInvoke(value)
            throw ArchitectureValidationFailure(description: "Expected the declared native error channel")
        } catch let error as NativeSwiftError {
            try error.withUnderlyingError {
                try check(($0 as NSError).domain == domain && ($0 as NSError).code == Int(value),
                    "Typed error channel preserves " + domain + " ownership")
            }
        }
    }
    throwingHook.invalidate()
    try check(failures.withLock { $0.isEmpty }, "No unexpected Swift callback failures")
    return ArchitectureReport(mode: "swift-function-hooks", cpuType: ABIValidationCPUType(),
        cpuSubtype: ABIValidationCPUSubtype(), pacCompiled: ABIValidationPACCompiled(),
        checks: checks, allocationTag: nil)
}
