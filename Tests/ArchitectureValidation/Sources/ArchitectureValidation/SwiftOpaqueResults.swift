import ABIBridge
import SwiftValueFixtures
import SwiftOpaqueExtensions
import Foundation

@MainActor func validateSwiftOpaqueResults() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let make = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaque(_:_:)",
        as: ((ErrorToken, Int64) -> NativeSwiftOpaqueValue).self)
    let counts = ArgumentCounts()
    weak var observed: ErrorToken?
    var stored: NativeSwiftOpaqueValue?
    do {
        let token = ErrorToken { counts.destroyed() }
        observed = token
        stored = try unsafe make.unsafeInvoke(token, 42)
    }
    try stored!.withValue {
        try check(($0 as? any ExistentialValue)?.number == 42 && ($0 as? any ExistentialLabel)?.label.count == 600,
                  "Opaque metadata supports an aligned hidden managed value and existing protocol witnesses")
        try check(ObjectIdentifier(Swift.type(of: $0)) == ObjectIdentifier(stored!.valueType),
                  "Opaque handle exposes the actual underlying runtime type")
    }
    var copy = stored
    stored = nil
    await runtime.removeCachedResults()
    try copy!.withValue { try check(($0 as? any ExistentialValue)?.number == 42 && observed != nil,
                                   "Copied opaque handle remains valid after resolver cache removal") }
    copy = nil
    try check(observed == nil && counts.destructions == 1, "Final opaque release destroys its hidden payload exactly once")

    let integer = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueInteger(_:)",
        as: ((Int64) -> NativeSwiftOpaqueValue).self)
    try unsafe integer.unsafeInvoke(42).withValue {
        try check($0 as? Int64 == 42, "Scalar opaque values use the native indirect result convention")
    }
    let empty = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueEmpty()",
        as: (() -> NativeSwiftOpaqueValue).self)
    try unsafe empty.unsafeInvoke().withValue { try check($0 is Void, "Empty opaque values preserve their runtime type") }

    let throwing = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueThrowing(_:_:)",
        as: ((ErrorToken, Bool) throws(SmallError) -> NativeSwiftOpaqueValue).self)
    do {
        _ = try unsafe throwing.unsafeInvoke(ErrorToken(), true)
        throw ArchitectureValidationFailure(description: "Expected opaque failure")
    } catch let error as NativeSwiftError {
        try error.withUnderlyingError { try check(($0 as? SmallError)?.code == 42,
            "Throwing opaque calls keep error storage separate from uninitialized result storage") }
    }

    let type = try await runtime.swiftType(named: "SwiftValueFixtures.OpaqueOwner")
    let owner = OpaqueOwner(ErrorToken())
    let getter = try await type.getter(named: "summary", as: NativeSwiftOpaqueValue.self)
    try unsafe getter.unsafeInvoke(on: owner).withValue {
        try check(($0 as? any ExistentialValue)?.number == 42, "Opaque getter resolves the property's descriptor")
    }

    let async = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueAsync(_:_:_:)",
        as: (@concurrent (AsyncValueGate, ErrorToken, Bool) async throws(SmallError) -> NativeSwiftOpaqueValue).self)
    for cancel in [false, true] {
        let gate = AsyncValueGate()
        let task = Task {
            let result = try unsafe await async.unsafeInvoke(gate, ErrorToken(), false)
            return result.withValue { ($0 as? any ExistentialValue)?.number ?? -100 }
        }
        await gate.waitUntilSuspended()
        if cancel { task.cancel() }
        await gate.open()
        do { try check(try await task.value == 42 && !cancel, "Async opaque result survives native suspension") }
        catch let error as NativeSwiftError {
            try error.withUnderlyingError { try check(cancel && ($0 as? SmallError)?.code == -1,
                "Cancelled opaque call preserves its native error without adopting a result") }
        }
    }
    for (name, expected) in [("makeOpaqueClassAny", 41), ("makeOpaqueClassProtocol", 42),
                              ("makeOpaqueSuperclass", 43), ("makeOpaqueUnconstrainedClass", 44)] {
        let call = try await runtime.swiftFunction(named: "SwiftValueFixtures." + name + "(_:)",
            as: ((ErrorToken) -> NativeSwiftOpaqueValue).self)
        try unsafe call.unsafeInvoke(ErrorToken()).withValue {
            try check(($0 as? OpaqueBase)?.number == Int64(expected), name + " follows its declared class constraint")
        }
    }
    let objc = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueObjC(_:)",
        as: ((ErrorToken) -> NativeSwiftOpaqueValue).self)
    try unsafe objc.unsafeInvoke(ErrorToken()).withValue { try check($0 is NSObject, "ObjC protocol constraint uses a direct object result") }
    let extensionMethod = try await type.method(named: "extensionOpaque(_:)", as: ((Int64) -> NativeSwiftOpaqueValue).self)
    let extensionGetter = try await type.getter(named: "extensionSummary", as: NativeSwiftOpaqueValue.self)
    let extensionObject = try await type.method(named: "extensionClassOpaque()", as: (() -> NativeSwiftOpaqueValue).self)
    try unsafe extensionMethod.unsafeInvoke(on: owner, 47).withValue {
        try check(($0 as? any ExistentialValue)?.number == 47, "Extension method locates its matched opaque descriptor")
    }
    try unsafe extensionGetter.unsafeInvoke(on: owner).withValue {
        try check(($0 as? any ExistentialValue)?.number == 48, "Extension getter retains its declaring module qualifier")
    }
    try unsafe extensionObject.unsafeInvoke(on: owner).withValue {
        try check(($0 as? any ExistentialObjectValue)?.number == 49, "Imported class protocol descriptor is authenticated through its indirect reference")
    }
    let directAsync = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeOpaqueClassAsync(_:_:)",
        as: (@concurrent (AsyncValueGate, ErrorToken) async -> NativeSwiftOpaqueValue).self)
    let directGate = AsyncValueGate()
    let directTask = Task {
        let value = try unsafe await directAsync.unsafeInvoke(directGate, ErrorToken())
        return value.withValue { ($0 as? any ExistentialObjectValue)?.number }
    }
    await directGate.waitUntilSuspended(); await directGate.open()
    try check(try await directTask.value == 46, "Async class-constrained opaque result resumes with a direct object pointer")
    return checks
}
