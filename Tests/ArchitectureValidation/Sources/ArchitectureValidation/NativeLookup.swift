import ABIBridge
import ArchitectureFixtures
import Darwin
import Foundation

@MainActor func validateNativeLookup() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    @MainActor func measure(_ label: String, operation: @MainActor () async throws -> Void) async throws {
        print("LOOKUP started: \(label)")
        fflush(nil)
        let start = ContinuousClock.now
        try await operation()
        let elapsed = start.duration(to: .now).components
        let result = "\(label): \(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) s"
        checks.append(result)
        print("LOOKUP completed: \(result)")
        fflush(nil)
    }
    for pass in ["cold", "warm"] {
        try await measure("C function \(pass)") {
            let function = try await runtime.cFunction(named: "ABIValidationAdd", as: ((Int32, Int32) -> Int32).self)
            guard try unsafe function.unsafeInvoke(20, 22) == 42 else {
                throw ArchitectureValidationFailure(description: "C function result differs from the fixture")
            }
        }
    }
    await runtime.removeCachedResults()
    guard let counter = ABIValidationCreateCounter() else {
        throw ArchitectureValidationFailure(description: "Counter allocation failed")
    }
    defer { ABIValidationDeleteCounter(counter) }
    let object = runtime.cxxObject(unsafe NativeValue(borrowing: counter, as: try .opaque(named: "ABIArchitecture::Counter")), typeNamed: "ABIArchitecture::Counter")
    for pass in ["cold", "warm"] {
        try await measure("C++ first member \(pass)") {
            let method = try await object.method(named: "add(int)", as: ((Int32) -> Int32).self)
            guard try unsafe method.unsafeInvoke(0) == 40 else {
                throw ArchitectureValidationFailure(description: "C++ member result differs from the fixture")
            }
        }
    }
    try await measure("C++ another member of the same class") {
        let method = try await object.method(named: "current() const", as: (() -> Int32).self)
        guard try unsafe method.unsafeInvoke() == 40 else {
            throw ArchitectureValidationFailure(description: "C++ const member result differs from the fixture")
        }
    }
    for (label, declaration) in [
        ("missing C symbol", NativeDeclaration(name: "ABIBridgeLookupFixtureAbsent", language: .c)),
        ("missing C++ member", NativeDeclaration(name: "ABIBridgeLookupFixtureAbsent::Counter::missing()", language: .cxx))
    ] {
        await runtime.removeCachedResults()
        for pass in ["cold", "warm"] {
            try await measure("\(label) \(pass)") {
                do {
                    _ = try await runtime.resolve(declaration)
                    throw ArchitectureValidationFailure(description: "The absent fixture unexpectedly resolved")
                } catch ABIResolutionError.declarationNotFound(let missing) where missing == declaration {}
            }
        }
    }
    return checks
}
