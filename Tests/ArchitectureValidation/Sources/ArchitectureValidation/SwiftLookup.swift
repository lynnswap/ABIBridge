import ABIBridge
import Darwin
import Foundation
import SwiftReplacementFixtures

@MainActor func validateSwiftLookup() async throws -> [String] {
    let runtime = ABIRuntime()
    let module = "SwiftReplacementFixtures"
    let declaration = NativeDeclaration(name: "nominal type descriptor for \(module).ReplacementRenderer", language: .swift, kind: .data)
    var checks: [String] = []
    @MainActor func measure(_ label: String, repetitions: Int = 1, operation: @MainActor () async throws -> Void) async throws {
        print("LOOKUP started: \(label)")
        fflush(nil)
        let start = ContinuousClock.now
        for _ in 0..<repetitions { try await operation() }
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let result = "\(label): \(seconds / Double(repetitions)) s (mean of \(repetitions))"
        checks.append(result)
        print("LOOKUP completed: \(result)")
        fflush(nil)
    }
    for pass in ["cold", "warm"] {
        try await measure("nominal descriptor \(pass)", repetitions: pass == "warm" ? 100 : 1) {
            _ = try await runtime.resolve(declaration)
        }
    }
    let base = try await runtime.swiftType(named: module + ".ReplacementRenderer")
    let child = try await runtime.swiftType(named: module + ".InheritedRenderer", in: base.image, loading: .loadedOnly)
    for (label, type, receiver) in [("direct method", base, ReplacementRenderer()), ("inherited method", child, InheritedRenderer())] {
        await runtime.removeCachedResults()
        for pass in ["cold", "warm"] {
            try await measure("\(label) \(pass)", repetitions: pass == "warm" ? 100 : 1) {
                let method = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
                guard try unsafe method.unsafeInvoke(on: receiver, 40) == 42 else {
                    throw ArchitectureValidationFailure(description: "Resolved method returned an unexpected result")
                }
            }
        }
    }
    return checks
}
