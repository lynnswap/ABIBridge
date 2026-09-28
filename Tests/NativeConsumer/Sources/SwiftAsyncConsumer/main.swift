import ABIBridge

public enum Context { @TaskLocal public static var value: Int64 = 0 }
@frozen public struct Failure: Error, ABIBridgeSwiftValue {
    public let code: Int64
    public static var swiftABIType: NativeType { .int64 }
}
@concurrent public func decorate(_ value: String) async -> String { await Task.yield(); return value + "!" }
nonisolated(nonsending) public func inherited(_ value: Int64) async -> Int64 { await Task.yield(); return value + Context.value }
@concurrent public func checked(_ fail: Bool) async throws(Failure) -> Int64 {
    await Task.yield()
    if fail { throw Failure(code: 42) }
    return 7
}

let runtime = ABIRuntime()
let decorate = try await runtime.swiftFunction(named: "SwiftAsyncConsumer.decorate(_:)",
    as: ((String) async -> String).self)
let result = try unsafe await decorate.unsafeInvoke("public")
precondition(result == "public!")
MainActor.preconditionIsolated()
let inherited = try await runtime.swiftFunction(named: "SwiftAsyncConsumer.inherited(_:)",
    as: (nonisolated(nonsending) (Int64) async -> Int64).self)
let sum = try await Context.$value.withValue(35) { try unsafe await inherited.unsafeInvoke(7) }
precondition(sum == 42)
let checked = try await runtime.swiftFunction(named: "SwiftAsyncConsumer.checked(_:)",
    as: (@concurrent (Bool) async throws(Failure) -> Int64).self)
let success = try unsafe await checked.unsafeInvoke(false)
precondition(success == 7)
do {
    _ = try unsafe await checked.unsafeInvoke(true)
    fatalError("Expected native failure")
} catch let error as NativeSwiftError {
    error.withUnderlyingError { precondition(($0 as? Failure)?.code == 42) }
}
let callbackBody: (nonisolated(nonsending) @Sendable (Int64) async throws(Failure) -> Int64) = {
    (value: Int64) async throws(Failure) in
    await Task.yield()
    if value < 0 { throw Failure(code: 43) }
    return value + Context.value
}
let callback = try NativeSwiftAsyncClosure<Int64, Failure, Int64>(callbackBody)
let callbackResult = try await Context.$value.withValue(35) { try unsafe await callback.unsafeInvoke(7) }
precondition(callbackResult == 42)
do {
    _ = try unsafe await callback.unsafeInvoke(-1)
    fatalError("Expected async closure failure")
} catch let error as NativeSwiftError {
    error.withUnderlyingError { precondition(($0 as? Failure)?.code == 43) }
}
@concurrent public func update(_ text: inout String, _ suffix: consuming String, _ prefix: borrowing String) async throws(Failure) -> String {
    await Task.yield()
    text += suffix
    if prefix.isEmpty { throw Failure(code: 44) }
    return prefix + text
}
let update = try await runtime.swiftFunction(named: "SwiftAsyncConsumer.update(_:_:_:)",
    as: (@concurrent (NativeSwiftInout<String>, NativeSwiftConsuming<String>, NativeSwiftBorrowing<String>) async throws(Failure) -> String).self)
let buffer = try NativeSwiftInout("value")
let updated = try unsafe await update.unsafeInvoke(buffer, .init("!"), .init("public:"))
precondition(updated == "public:value!" && buffer.value == "value!")
do {
    _ = try unsafe await update.unsafeInvoke(buffer, .init("?"), .init(""))
    fatalError("Expected inout failure")
} catch let error as NativeSwiftError {
    error.withUnderlyingError { precondition(($0 as? Failure)?.code == 44) }
}
precondition(buffer.value == "value!?")
public protocol Summary: Sendable { var number: Int64 { get } }
public struct SummaryValue: Summary { public let number: Int64 }
public func echoSummary(_ value: any Summary) -> any Summary { value }
let echoSummary = try await runtime.swiftFunction(named: "SwiftAsyncConsumer.echoSummary(_:)",
    as: ((any Summary) -> any Summary).self)
let summary = try unsafe echoSummary.unsafeInvoke(SummaryValue(number: 42))
precondition(summary.number == 42 && summary is SummaryValue)
private struct HiddenSummary: Summary { let number: Int64 }
public func makeSummary() -> some Summary { HiddenSummary(number: 43) }
let makeSummaryFunction = try await runtime.swiftFunction(named: "SwiftAsyncConsumer.makeSummary()",
    as: (() -> NativeSwiftOpaqueValue).self)
let opaque = try unsafe makeSummaryFunction.unsafeInvoke()
opaque.withValue { precondition(($0 as? any Summary)?.number == 43) }
print("Public async consumer passed: suspension, task locals, caller executor, typed errors, inout, per-argument ownership, existentials, and opaque results")
