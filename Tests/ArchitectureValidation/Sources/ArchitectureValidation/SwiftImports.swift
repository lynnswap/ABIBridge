import ABIBridge
import ABIBridgeCore
import ArchitectureFixtures
import Darwin
import Foundation

private struct ImportPayload: ABIBridgeValue {
    var a, b, c, d, e: Int64
    static let abiType = try! NativeType.structure(named: "ImportPayload", fields: Array(repeating: .int64, count: 5))
    init(nativeValue: NativeValue) throws { self = try unsafe nativeValue.read(as: Self.self) }
    static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value, as: abiType) }
}

/// Requires the three frameworks produced by build-swift-import-fixtures.py,
/// embedded and signed in the host, without statically linking their modules.
@MainActor public func runSwiftImportReplacementValidation() async throws -> ArchitectureReport {
    let runtime = ABIRuntime()
    let root = Bundle.main.bundleURL.appendingPathComponent("Frameworks")
    func path(_ name: String) -> ImageSelector { .path(root.appendingPathComponent("\(name).framework/\(name)")) }
    var checks: [String] = []
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    @MainActor func finish<Implementation>(_ plan: NativeSwiftImportedReplacement<Implementation>,
        _ message: String, _ body: @MainActor () throws -> Bool) throws {
        let result = Result { try body() }
        do { try plan.restore() } catch let cleanup {
            if case .failure(let error) = result { throw ArchitectureValidationFailure(description: "\(error); cleanup: \(cleanup)") }
            throw cleanup
        }
        try check(result.get(), message)
    }
    let target = try await runtime.swiftFunction(named: "SwiftImportProvider.scalar(_:)", as: ((Int64) -> Int64).self, in: path("SwiftImportProvider"))
    let replacement = try await runtime.swiftFunction(named: "SwiftImportProvider.replacementScalar(_:)", as: ((Int64) -> Int64).self, in: path("SwiftImportProvider"))
    for caller in ["SwiftImportCaller", "SwiftImportCallerControl"] {
        let oracle = try await runtime.swiftFunction(named: caller + ".importedScalar(_:)", as: ((Int64) -> Int64).self, in: path(caller))
        let plan = try await unsafe target.prepareImportedReplacement(with: replacement, in: path(caller), using: runtime)
        try check(try unsafe oracle.unsafeInvoke(40) == 41, "\(caller): preparation leaves original dispatch")
        guard let original = plan.slots.first?.original else { throw ArchitectureValidationFailure(description: "Original scalar entry missing") }
        do {
            try unsafe plan.install()
        } catch {
            let slots = plan.slots
            guard caller == "SwiftImportCaller", !slots.isEmpty, slots.allSatisfy({ slot in
                guard let mutation = slot.mutation else { return false }
                return !mutation.didWrite && mutation.status == ABIPointerSlotProtectFailed
                    && mutation.systemErrorCode == KERN_PROTECTION_FAILURE
                    && mutation.regionFlags & UInt32(VM_REGION_FLAG_TPRO_ENABLED) != 0
            }) else { throw error }
            try check(try unsafe oracle.unsafeInvoke(40) == 41, "Normal Swift imports: TPRO refusal without mutation")
            continue
        }
        try finish(plan, "\(caller): compiled scalar replacement and captured predecessor") {
            try unsafe oracle.unsafeInvoke(40) == 140 && original.unsafeInvoke(40) == 41
        }
        try check(try unsafe oracle.unsafeInvoke(40) == 41, "\(caller): restored scalar dispatch")
    }
    let caller = "SwiftImportCallerControl"
    let text = try await runtime.swiftFunction(named: "SwiftImportProvider.text(_:)", as: ((String) -> String).self, in: path("SwiftImportProvider"))
    let newText = try await runtime.swiftFunction(named: "SwiftImportProvider.replacementText(_:)", as: ((String) -> String).self, in: path("SwiftImportProvider"))
    let textOracle = try await runtime.swiftFunction(named: caller + ".importedText(_:)", as: ((String) -> String).self, in: path(caller))
    let textPlan = try await unsafe text.prepareImportedReplacement(with: newText, in: path(caller), using: runtime)
    try unsafe textPlan.install()
    let input = String(repeating: "owned Swift argument", count: 100)
    try finish(textPlan, "Compiled String replacement and retained predecessor") {
        try unsafe textOracle.unsafeInvoke(input) == "replacement:" + input
            && textPlan.slots[0].original!.unsafeInvoke(input) == "original:" + input
    }
    try check(try unsafe textOracle.unsafeInvoke(input) == "original:" + input, "String dispatch restored")

    let suffix = "(Swift.Int64) -> SwiftImportProvider.ReplacementPayload"
    let large = try await runtime.swiftFunction(named: "SwiftImportProvider.payload" + suffix, as: ((Int64) -> ImportPayload).self, in: path("SwiftImportProvider"))
    let newLarge = try await runtime.swiftFunction(named: "SwiftImportProvider.replacementPayload" + suffix, as: ((Int64) -> ImportPayload).self, in: path("SwiftImportProvider"))
    let largeOracle = try await runtime.swiftFunction(named: caller + ".importedPayload(_:)", as: ((Int64) -> Int64).self, in: path(caller))
    let largePlan = try await unsafe large.prepareImportedReplacement(with: newLarge, in: path(caller), using: runtime)
    try unsafe largePlan.install()
    try finish(largePlan, "Compiled indirect result and captured predecessor") {
        let previous = try unsafe largePlan.slots[0].original!.unsafeInvoke(40)
        return try unsafe largeOracle.unsafeInvoke(40) == 710 && previous.a == 40 && previous.e == 44
    }
    try check(try unsafe largeOracle.unsafeInvoke(40) == 210, "Indirect result dispatch restored")
    let type = try await runtime.swiftType(named: "SwiftImportProvider.ReplacementValue", as: Int64.self, in: path("SwiftImportProvider"))
    let method = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
    let newMethod = try await type.method(named: "replacementScalar(_:)", as: ((Int64) -> Int64).self)
    let methodOracle = try await runtime.swiftFunction(named: caller + ".importedValueMethod(_:)", as: ((Int64) -> Int64).self, in: path(caller))
    let methodPlan = try await unsafe method.prepareImportedReplacement(with: newMethod, in: path(caller), using: runtime)
    try unsafe methodPlan.install()
    try finish(methodPlan, "Compiled struct member preserves receiver context and captured predecessor") {
        try unsafe methodOracle.unsafeInvoke(2) == 142 && methodPlan.slots[0].original!.unsafeInvoke(on: Int64(40), 2) == 42
    }
    try check(try unsafe methodOracle.unsafeInvoke(2) == 42, "Struct member dispatch restored")
    return ArchitectureReport(mode: "swift-import-replacement", cpuType: ABIValidationCPUType(), cpuSubtype: ABIValidationCPUSubtype(),
        pacCompiled: ABIValidationPACCompiled(), checks: checks, allocationTag: nil)
}
