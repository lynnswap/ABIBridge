import ABIBridge
import ABIBridgeCore
import Darwin
import SwiftReplacementCaller
import SwiftReplacementFixtures

@MainActor func validateSwiftReplacement() async throws -> [String] {
    let runtime = ABIRuntime(), receiver = ReplacementRenderer()
    let module = "SwiftReplacementFixtures"
    let descriptor = try await runtime.resolve(.init(name: "nominal type descriptor for \(module).ReplacementRenderer", language: .swift, kind: .data))
    var checks: [String] = []
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ArchitectureValidationFailure(description: message) }
    }
    @MainActor func replace(_ name: String, with replacement: String, _ body: @MainActor () throws -> Void) async throws {
        let target = try await runtime.resolve(.init(name: "\(module).ReplacementRenderer." + name, language: .swift))
        let replacement = try await runtime.resolve(.init(name: "\(module).ReplacementRenderer." + replacement, language: .swift))
        let report = try unsafe descriptor.withUnsafeAddress { descriptor in
            let flags = descriptor.load(as: UInt32.self)
            try check(flags & 0x1f == 16 && flags & 0x80 == 0 && flags & 0x80000000 != 0, "Fixture class descriptor flags")
            try check(descriptor.load(fromByteOffset: 20, as: Int32.self) == 0 && descriptor.load(fromByteOffset: 36, as: UInt32.self) == 0,
                "Fixture remains a nongeneric root class without stored fields")
            let positiveWords = Int(descriptor.load(fromByteOffset: 28, as: UInt32.self))
            let offset = Int(descriptor.load(fromByteOffset: 44, as: UInt32.self))
            let count = Int(descriptor.load(fromByteOffset: 48, as: UInt32.self))
            try check(count > 0 && offset + count <= positiveWords, "Fixture metadata extent")
            return try unsafe target.withUnsafeAddress { originalAddress in
                let metadata = unsafeBitCast(ReplacementRenderer.self, to: UnsafeMutableRawPointer.self)
                var slots: [(UnsafeMutableRawPointer, UInt)] = []
                for index in 0..<count {
                    let method = descriptor.advanced(by: 52 + 8 * index)
                    let methodFlags = method.load(as: UInt32.self)
                    let field = method.advanced(by: 4)
                    guard field.advanced(by: Int(field.load(as: Int32.self))) == originalAddress else { continue }
                    try check(methodFlags & 0x7f == 0x10, "Fixture method is synchronous, ordinary and instance-bound")
                    slots.append((metadata.advanced(by: (offset + index) * MemoryLayout<UInt>.size), UInt(methodFlags >> 16)))
                }
                try check(slots.count == 1, "Fixture declaration has one descriptor entry")
                let (slot, discriminator) = slots[0]
                let authenticated = ABIUsesPointerAuthentication()
                let key = Int32(authenticated ? ABIAuthenticationInstructionA : ABIAuthenticationUnsigned)
                let old = slot.load(as: UInt.self)
                try check(ABIUnsafeReadAuthenticatedPointer(slot, key, discriminator, authenticated) == originalAddress,
                    "Compiler slot authenticates to its declared implementation")
                return try unsafe replacement.withUnsafeAddress { address in
                    var next: UInt = 0
                    try check(ABIEncodePointerSlotFunction(ABIUnsafeFunctionAtAddress(address), slot, key, discriminator, authenticated, &next),
                        "Compiled replacement is signed for the original method slot")
                    let mutation = ABICompareExchangePointerSlot(slot, old, next)
                    if !mutation.didWrite {
                        try check(mutation.status == ABIPointerSlotProtectFailed && mutation.systemErrorCode == KERN_PROTECTION_FAILURE
                            && mutation.regionFlags & UInt32(VM_REGION_FLAG_TPRO_ENABLED) != 0 && slot.load(as: UInt.self) == old,
                            "Swift metadata mutation failed unexpectedly: \(mutation.status)/\(mutation.systemErrorCode)")
                        return "\(name): TPRO refusal without mutation"
                    }
                    var bodyError: (any Error)?
                    if mutation.status == ABIPointerSlotComplete {
                        do { try body() } catch { bodyError = error }
                    }
                    let restored = ABICompareExchangePointerSlot(slot, next, old)
                    guard mutation.status == ABIPointerSlotComplete && restored.status == ABIPointerSlotComplete
                        && restored.didWrite && slot.load(as: UInt.self) == old else {
                        throw ArchitectureValidationFailure(description: "Swift metadata publication/restoration: \(mutation.status)/\(restored.status), errors \(mutation.restoreProtectionError)/\(restored.restoreProtectionError); callback: \(String(describing: bodyError))")
                    }
                    if let bodyError { throw bodyError }
                    return "\(name): compiled replacement and restoration passed; PAC=\(authenticated), discriminator=\(discriminator), addressDiversity=\(authenticated)"
                }
            }
        }
        checks.append(report)
    }
    let captured = try await runtime.object(receiver).method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
    try check(classScalar(receiver, 40) == 42, "Swift class scalar baseline")
    try await replace("scalar(Swift.Int64) -> Swift.Int64", with: "replacementScalar(Swift.Int64) -> Swift.Int64") {
        try check(classScalar(receiver, 40) == 240, "Compiler-generated class call uses replacement")
        try check(classFinal(receiver, 40) == 43, "Final control remains direct")
        try check(try unsafe captured.unsafeInvoke(40) == 42, "Captured Swift implementation remains callable")
    }
    try check(classScalar(receiver, 40) == 42, "Swift scalar restored")
    let input = String(repeating: "owned string", count: 200)
    try check(classText(receiver, input) == "method:" + input, "Swift String baseline")
    try await replace("text(Swift.String) -> Swift.String", with: "replacementText(Swift.String) -> Swift.String") {
        for _ in 0..<20 { try check(classText(receiver, input) == "replacement-method:" + input, "Owned Swift String replacement") }
    }
    try check(classText(receiver, input) == "method:" + input, "Swift String restored")
    try check(classPayload(receiver, 40) == 220, "Indirect Swift result baseline")
    try await replace("payload(Swift.Int64) -> \(module).ReplacementPayload", with: "replacementPayload(Swift.Int64) -> \(module).ReplacementPayload") {
        try check(classPayload(receiver, 40) == 1210, "Compiler-generated indirect result preserves storage")
    }
    try check(classPayload(receiver, 40) == 220, "Indirect Swift result restored")
    checks += try await validateSwiftVirtualReplacement()
    return checks
}

struct VirtualPayload: ABIBridgeValue {
    var a, b, c, d, e: Int64
    static let abiType = try! NativeType.structure(named: "VirtualPayload", fields: Array(repeating: .int64, count: 5))
    init(nativeValue: NativeValue) throws { self = try unsafe nativeValue.read(as: Self.self) }
    static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value, as: abiType) }
}

@MainActor private func validateSwiftVirtualReplacement() async throws -> [String] {
    let runtime = ABIRuntime(), module = "SwiftReplacementFixtures"
    let base = try await runtime.swiftType(named: module + ".ReplacementRenderer")
    let replacement = try await base.method(named: "replacementScalar(_:)", as: ((Int64) -> Int64).self)
    let objects: [ReplacementRenderer] = [ReplacementRenderer(), InheritedRenderer(), OverridingRenderer()]
    let names = ["ReplacementRenderer", "InheritedRenderer", "OverridingRenderer"]
    var checks: [String] = []
    func check(_ result: Bool, _ message: String) throws {
        guard result else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    @MainActor func installed<Implementation>(_ plan: NativeSwiftVirtualReplacement<Implementation>,
        _ body: @MainActor () throws -> Void) throws {
        try unsafe plan.install()
        let result = Result { try body() }
        do { try plan.restore() } catch let cleanup {
            if case .failure(let failure) = result {
                throw ArchitectureValidationFailure(description: "\(failure); restoration: \(cleanup)")
            }
            throw cleanup
        }
        try result.get()
    }
    for (index, name) in names.enumerated() {
        let type = try await runtime.swiftType(named: module + "." + name)
        let method = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
        let plan = try unsafe method.prepareVirtualReplacement(with: replacement)
        try installed(plan) {
            for (other, object) in objects.enumerated() {
                try check(classScalar(object, 40) == (other == index ? 240 : (other == 2 ? 44 : 42)),
                    "\(name) virtual replacement scope: \(names[other])")
            }
            try check(try unsafe plan.original.unsafeInvoke(on: objects[index], 40) == (index == 2 ? 44 : 42),
                "\(name) typed predecessor preserves receiver context")
        }
        try check(classScalar(objects[index], 40) == (index == 2 ? 44 : 42), "\(name) restored")
    }
    let text = try await base.method(named: "text(_:)", as: ((String) -> String).self)
    let textReplacement = try await base.method(named: "replacementText(_:)", as: ((String) -> String).self)
    let textPlan = try unsafe text.prepareVirtualReplacement(with: textReplacement)
    let input = String(repeating: "native Swift receiver", count: 100)
    try installed(textPlan) {
        try check(classText(objects[0], input) == "replacement-method:" + input, "Public virtual replacement preserves owned String result")
        try check(try unsafe textPlan.original.unsafeInvoke(on: objects[0], input) == "method:" + input, "String predecessor remains callable")
    }
    let suffix = "(Swift.Int64) -> \(module).ReplacementPayload"
    let payload = try await base.method(named: "payload" + suffix, as: ((Int64) -> VirtualPayload).self)
    let payloadReplacement = try await base.method(named: "replacementPayload" + suffix, as: ((Int64) -> VirtualPayload).self)
    let payloadPlan = try unsafe payload.prepareVirtualReplacement(with: payloadReplacement)
    try installed(payloadPlan) {
        try check(classPayload(objects[0], 40) == 1210, "Public virtual replacement preserves indirect result")
        try check(try unsafe payloadPlan.original.unsafeInvoke(on: objects[0], 40).a == 42, "Indirect predecessor preserves caller result storage")
    }
    let child = CoalescedChild()
    let childType = try await runtime.swiftType(named: module + ".CoalescedChild")
    let valueMethod = try await childType.method(named: "value()", as: (() -> Int64).self)
    let extraMethod = try await childType.method(named: "extra()", as: (() -> Int64).self)
    let replacementMethod = try await childType.method(named: "replacement()", as: (() -> Int64).self)
    let valuePlan = try unsafe valueMethod.prepareVirtualReplacement(with: replacementMethod)
    let extraPlan = try unsafe extraMethod.prepareVirtualReplacement(with: replacementMethod)
    try check(valuePlan.address != extraPlan.address, "Identical method bodies select distinct declaration slots")
    try installed(valuePlan) {
        try check(coalescedValue(child) == 100 && coalescedExtra(child) == 42 && coalescedFinal(child) == 42,
            "Inherited declaration replacement leaves coalesced child and final calls unchanged")
    }
    try installed(extraPlan) {
        try check(coalescedValue(child) == 42 && coalescedExtra(child) == 100 && coalescedFinal(child) == 42,
            "Child declaration replacement leaves coalesced inherited and final calls unchanged")
    }
    let externalReceiver = CallerOverridingRenderer()
    let externalType = try await runtime.swiftType(named: "SwiftReplacementCaller.CallerOverridingRenderer")
    let externalMethod = try await externalType.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
    let externalPlan = try unsafe externalMethod.prepareVirtualReplacement(with: replacement)
    try installed(externalPlan) {
        try check(classScalar(externalReceiver, 40) == 240, "Cross-module override descriptor selects and authenticates the base slot")
        try check(try unsafe externalPlan.original.unsafeInvoke(on: externalReceiver, 40) == 45,
            "Cross-module override predecessor remains callable")
    }
    try check(classScalar(externalReceiver, 40) == 45, "Cross-module override restored")
    return checks
}
