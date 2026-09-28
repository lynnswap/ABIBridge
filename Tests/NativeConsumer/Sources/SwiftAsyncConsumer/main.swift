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
print("Public async consumer passed: native suspension, task locals, caller executor, and typed errors")
