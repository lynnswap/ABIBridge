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
    return checks
}
