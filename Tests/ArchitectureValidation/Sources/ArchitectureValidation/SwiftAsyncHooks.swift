import ABIBridge
import Foundation
import Synchronization

private enum AsyncHookValidationFailure: Error { case callback }

@MainActor
func validateAsyncFunctionHooks(runtime: ABIRuntime, provider: ImageSelector, caller: ImageSelector) async throws -> [String] {
    var checks: [String] = []
    func check(_ result: Bool, _ message: String) throws {
        guard result else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let failures = Mutex(0)
    let failure: @Sendable (any Error) -> Void = { _ in failures.withLock { $0 += 1 } }
    typealias Echo = nonisolated(nonsending) (Int64) async -> Int64
    let function = try await runtime.swiftFunction(named: "SwiftImportProvider.asyncHookEcho(_:)",
        as: Echo.self, genericArguments: [.type(Int64.self)], in: provider)
    let integer = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedAsyncHookInteger(_:)", as: Echo.self, in: caller)
    let text = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedAsyncHookString(_:)",
        as: (nonisolated(nonsending) (String) async -> String).self, in: caller)
    _ = try unsafe await integer.unsafeInvoke(1)
    let hook = try unsafe await function.hookImportedCalls(in: caller, using: runtime, onFailure: failure) { call, value in
        await Task.yield()
        return try await call.proceed(value + 10) + 100
    }
    defer { hook.invalidate() }
    try check(try unsafe await integer.unsafeInvoke(1) == 111, "Async generic hook edits arguments and resumes with its predecessor result")
    try check(try unsafe await text.unsafeInvoke("unmatched") == "unmatched", "Async generic mismatch passes the original native frame unchanged")
    hook.invalidate()
    try check(try unsafe await integer.unsafeInvoke(1) == 1, "Invalidated async import remains callable through its saved dispatcher")

    typealias Throwing = nonisolated(nonsending) (Int64) async throws(NSError) -> String
    let throwing = try await runtime.swiftFunction(named: "SwiftImportProvider.asyncHookThrowing(_:)", as: Throwing.self, in: provider)
    let throwingCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedAsyncHookThrowing(_:)", as: Throwing.self, in: caller)
    _ = try unsafe await throwingCaller.unsafeInvoke(1)
    let throwingHook = try unsafe await throwing.hookImportedCalls(in: caller, using: runtime, onFailure: failure) { call, value in
        if value == 99 { throw NSError(domain: "callback-async-hook", code: 99) }
        let result = try await call.proceed(value)
        if value == 98 { throw AsyncHookValidationFailure.callback }
        return result + "-hook"
    }
    defer { throwingHook.invalidate() }
    try check(try unsafe await throwingCaller.unsafeInvoke(1) == String(repeating: "value:1", count: 100) + "-hook",
        "Async hooks transfer an owned String after suspension")
    try check(try unsafe await throwingCaller.unsafeInvoke(98) == String(repeating: "value:98", count: 100),
        "Unrepresentable async callback failure preserves the completed native value")
    for (value, domain) in [(Int64(-1), "native-async-hook"), (99, "callback-async-hook")] {
        do { _ = try unsafe await throwingCaller.unsafeInvoke(value); throw ArchitectureValidationFailure(description: "Expected async native error") }
        catch let error as NativeSwiftError {
            try error.withUnderlyingError { try check(($0 as NSError).domain == domain, "Async error channel preserves " + domain) }
        }
    }
    throwingHook.invalidate()

    let actor = try await runtime.swiftFunction(named: "SwiftImportProvider.asyncHookActor(_:)",
        as: (@Sendable @concurrent (Int64) async -> Int64).self, in: provider)
    let actorCaller = try await runtime.swiftFunction(named: "SwiftImportCallerControl.importedAsyncHookActor(_:)",
        as: (@concurrent (Int64) async -> Int64).self, in: caller)
    _ = try unsafe await actorCaller.unsafeInvoke(1)
    let actorHook = try unsafe await actor.hookMainActorImportedCalls(in: caller, using: runtime, onFailure: failure) { call, value in
        MainActor.preconditionIsolated()
        let result = try await call.proceed(value + 10)
        MainActor.preconditionIsolated()
        return result + 100
    }
    defer { actorHook.invalidate() }
    try check(try unsafe await actorCaller.unsafeInvoke(1) == 112, "MainActor async hook and continuation resume on their declared executor")
    try check(failures.withLock { $0 } == 1, "Only the expected unrepresentable async failure reaches its observer")
    return checks
}

@MainActor
func validateAsyncMethodHooks(runtime: ABIRuntime, provider: ImageSelector, caller: ImageSelector) async throws -> [String] {
    var checks: [String] = []
    func check(_ result: Bool, _ message: String) throws {
        guard result else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let failures = Mutex(0)
    let name = "SwiftImportProvider.AsyncHookRenderer"
    let type = try await runtime.swiftType(named: name, in: provider)
    let method = try await type.method(named: "render(_:)",
        as: (nonisolated(nonsending) (String) async throws(NSError) -> String).self)
    let make = try await runtime.swiftFunction(named: "SwiftImportProvider.makeAsyncHookRenderer() -> " + name,
        as: (() -> AnyObject).self, in: provider)
    var object: AnyObject? = try unsafe make.unsafeInvoke()
    weak var observed = object
    let identity = ObjectIdentifier(object!)
    let oracle = try await runtime.swiftFunction(
        named: "SwiftImportCallerControl.importedAsyncHookMethod(" + name + ", Swift.String) async throws(__C.NSError) -> Swift.String",
        as: (nonisolated(nonsending) (AnyObject, String) async throws(NSError) -> String).self, in: caller)
    let hook = try unsafe await method.hookVirtualCalls(onFailure: { _ in failures.withLock { $0 += 1 } }) { call, value in
        guard ObjectIdentifier(try call.receiver(as: AnyObject.self)) == identity else { throw AsyncHookValidationFailure.callback }
        let result = try await call.proceed(value)
        guard ObjectIdentifier(try call.receiver(as: AnyObject.self)) == identity else { throw AsyncHookValidationFailure.callback }
        return result + "-hook"
    }
    defer { hook.invalidate() }
    try check(try unsafe await oracle.unsafeInvoke(object!, "value") == "value-native-hook", "Async virtual descriptors authenticate and preserve the receiver across suspension")
    do { _ = try unsafe await oracle.unsafeInvoke(object!, "fail"); throw ArchitectureValidationFailure(description: "Expected async method error") }
    catch let error as NativeSwiftError {
        try error.withUnderlyingError { try check(($0 as NSError).domain == "native-async-method", "Async virtual continuation preserves its typed native error") }
    }
    hook.invalidate()
    try check(try unsafe await oracle.unsafeInvoke(object!, "value") == "value-native", "Invalidated async metadata slot passes through with the captured context size")
    object = nil
    try check(observed == nil, "Async virtual registrations do not retain receiver instances")
    try check(failures.withLock { $0 } == 0, "Async virtual calls report no unexpected callback failure")
    return checks
}
