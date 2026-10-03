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
    try check(failures.withLock { $0.isEmpty }, "No unexpected Swift callback failures")
    return ArchitectureReport(mode: "swift-function-hooks", cpuType: ABIValidationCPUType(),
        cpuSubtype: ABIValidationCPUSubtype(), pacCompiled: ABIValidationPACCompiled(),
        checks: checks, allocationTag: nil)
}
