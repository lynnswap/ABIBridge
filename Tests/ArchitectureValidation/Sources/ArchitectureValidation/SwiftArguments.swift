import ABIBridge
import SwiftValueFixtures

@MainActor func validateSwiftArguments() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let mutate = try await runtime.swiftFunction(named: "SwiftValueFixtures.mutateArguments(_:_:_:_:)",
        as: ((NativeSwiftInout<String>, NativeSwiftInout<[String]>, NativeSwiftInout<Int64>, Bool) throws(SmallError) -> Void).self)
    let text = NativeSwiftInout(String(repeating: "text", count: 100))
    let values = NativeSwiftInout([String]())
    let count = NativeSwiftInout(Int64(40))
    try unsafe mutate.unsafeInvoke(text, values, count, false)
    try check(count.value == 41 && values.value == [text.value], "Inout writes back managed and scalar Swift values")
    do {
        try unsafe mutate.unsafeInvoke(text, values, count, true)
        throw ArchitectureValidationFailure(description: "Expected inout failure")
    } catch let error as NativeSwiftError {
        try error.withUnderlyingError { try check(($0 as? SmallError)?.code == 42 && count.value == 42 && values.value.count == 2, "Throwing completion preserves all inout mutations") }
    }

    let consume = try await runtime.swiftFunction(named: "SwiftValueFixtures.consumeArgument(_:_:_:)",
        as: ((NativeSwiftConsuming<LargeError>, NativeSwiftBorrowing<String>, Bool) throws(SmallError) -> String).self)
    let counts = ArgumentCounts()
    for fail in [false, true] {
        weak var observed: ErrorToken?
        do {
            let token = ErrorToken { counts.destroyed() }
            observed = token
            let value = LargeError(token)
            do {
                let result = try unsafe consume.unsafeInvoke(.init(value), .init("value:"), fail)
                guard !fail && result == "value:4" else { throw ArchitectureValidationFailure(description: "Invalid consumed result") }
            } catch let error as NativeSwiftError {
                try error.withUnderlyingError {
                    guard fail && ($0 as? SmallError)?.code == 4 else { throw ArchitectureValidationFailure(description: "Invalid consumed error") }
                }
            }
            guard observed === value.token else { throw ArchitectureValidationFailure(description: "Original value released") }
        }
        try check(observed == nil, "Consumed indirect value releases its copy on \(fail ? "failure" : "success")")
    }
    try check(counts.destructions == 2, "Consuming copies destroy their final references exactly once")

    let type = try await runtime.swiftType(named: "SwiftValueFixtures.ArgumentOwner")
    let make = try await type.initializer(named: "init(_:_:_:)",
        as: ((NativeSwiftBorrowing<String>, NativeSwiftConsuming<String>, NativeSwiftBorrowing<ErrorToken>) -> ArgumentOwner).self)
    let token = ErrorToken()
    let owner = try unsafe make.unsafeInvoke(.init("first"), .init("second"), .init(token))
    try check(owner.first == "first" && owner.second == "second" && owner.token === token, "Allocating initializer mixes guaranteed and owned parameters")

    let async = try await runtime.swiftFunction(named: "SwiftValueFixtures.asyncArguments(_:_:_:_:)",
        as: (@concurrent (AsyncValueGate, NativeSwiftInout<String>, NativeSwiftConsuming<String>, NativeSwiftBorrowing<String>) async throws(SmallError) -> String).self)
    for cancelled in [false, true] {
        let gate = AsyncValueGate()
        let buffer = NativeSwiftInout("value")
        let task = Task { @MainActor in try unsafe await async.unsafeInvoke(gate, buffer, .init("!"), .init("?")) }
        await gate.waitUntilSuspended()
        if cancelled { task.cancel() }
        await gate.open()
        do {
            let result = try await task.value
            guard !cancelled && result == "value!?" else { throw ArchitectureValidationFailure(description: "Invalid async result") }
        } catch let error as NativeSwiftError {
            try error.withUnderlyingError {
                guard cancelled && ($0 as? SmallError)?.code == -1 else { throw ArchitectureValidationFailure(description: "Invalid cancellation result") }
            }
        }
        try check(buffer.value == "value!", "Inout storage survives suspension and \(cancelled ? "cancellation" : "normal completion")")
    }

    let asyncMake = try await type.initializer(named: "init(_:_:_:_:_:)",
        as: (@concurrent (NativeSwiftBorrowing<String>, NativeSwiftConsuming<String>, NativeSwiftBorrowing<ErrorToken>, AsyncValueGate, Bool) async throws(SmallError) -> ArgumentOwner).self)
    let gate = AsyncValueGate()
    let task = Task { try unsafe await asyncMake.unsafeInvoke(.init("async"), .init("owned"), .init(token), gate, false) }
    await gate.waitUntilSuspended(); await gate.open()
    let asyncOwner = try await task.value
    try check(asyncOwner.first == "async" && asyncOwner.second == "owned" && asyncOwner.token === token, "Async initializer retains mixed-ownership arguments until completion")
    return checks
}
