import ABIBridge
import ArchitectureFixtures
import Foundation

private final class InvocationTimingReceiver: NSObject {
    @objc dynamic func adding(_ value: Int32) -> Int32 { value + 40 }
    @objc dynamic func echo(_ value: NSObject?) -> NSObject? { value }
}

@inline(never) public func architectureTimingMix(_ a: Int32, _ b: Double, _ c: Float, _ d: UInt64) -> Double {
    Double(a) + b + Double(c) + Double(d)
}

@MainActor func validateInvocationTiming() async throws -> [String] {
    let runtime = ABIRuntime()
    let add = try await runtime.cFunction(named: "ABIValidationAdd", as: ((Int32, Int32) -> Int32).self)
    let pointer = try await runtime.cFunction(named: "ABIValidationAdvance", as: ((UnsafeMutablePointer<CChar>, Int) -> UnsafeMutableRawPointer).self)
    let sum = try await runtime.swiftFunction(named: "ArchitectureValidation.architectureSum(_:_:_:_:_:_:_:_:_:_:)", as: ((Int, Int, Int, Int, Int, Int, Int, Int, Int, Int) -> Int).self)
    let decorate = try await runtime.swiftFunction(named: "ArchitectureValidation.architectureDecorate(_:)", as: ((String) -> String).self)
    let mix = try await runtime.swiftFunction(named: "ArchitectureValidation.architectureTimingMix(_:_:_:_:)", as: ((Int32, Double, Float, UInt64) -> Double).self)
    let counter = ABIValidationCreateCounter()!
    defer { ABIValidationDeleteCounter(counter) }
    let cxxObject = runtime.cxxObject(unsafe NativeValue(borrowing: counter, as: try .opaque(named: "ABIArchitecture::Counter")), typeNamed: "ABIArchitecture::Counter")
    let cxxMethod = try await cxxObject.method(named: "add(int)", as: ((Int32) -> Int32).self)
    let object = runtime.object(InvocationTimingReceiver())
    let method = try object.method(selector: "adding:", as: ((Int32) -> Int32).self)
    let echo = try object.method(selector: "echo:", as: ((NSObject?) -> NSObject?).self)
    let value = NSObject()
    let string = String(repeating: "owned string", count: 8)
    let expected = string + "!"
    var checks: [String] = []
    func measure(_ label: String, body: () throws -> Bool) throws {
        guard try body() else { throw ArchitectureValidationFailure(description: label) }
        let repetitions = 100_000
        let start = ContinuousClock.now
        for _ in 0..<repetitions {
            guard try body() else { throw ArchitectureValidationFailure(description: label) }
        }
        let elapsed = start.duration(to: .now).components
        checks.append("\(label): \((Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) / Double(repetitions)) s (mean of \(repetitions))")
    }
    try measure("C scalar invocation") { try unsafe add.unsafeInvoke(20, 22) == 42 }
    try withUnsafeTemporaryAllocation(of: CChar.self, capacity: 2) { buffer in
        try measure("C pointer invocation") { try unsafe pointer.unsafeInvoke(buffer.baseAddress!, 1) == UnsafeMutableRawPointer(buffer.baseAddress! + 1) }
    }
    try measure("C++ receiver invocation") { try unsafe cxxMethod.unsafeInvoke(0) == 40 }
    try measure("Swift mixed invocation") { try unsafe mix.unsafeInvoke(1, 2.5, 3.5, 35) == 42 }
    try measure("Swift ten-argument invocation") { try unsafe sum.unsafeInvoke(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) == 0xa987654321 }
    try measure("Swift owned-string invocation") { try unsafe decorate.unsafeInvoke(string) == expected }
    try measure("Objective-C scalar invocation") { try unsafe method.unsafeInvoke(2) == 42 }
    try measure("Objective-C object invocation") { try unsafe echo.unsafeInvoke(value) === value }
    return checks
}
