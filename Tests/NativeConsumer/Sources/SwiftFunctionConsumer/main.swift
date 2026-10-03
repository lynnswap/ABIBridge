import ABIBridge
import Darwin
import Foundation
import Synchronization

private enum ConsumerHookFailure: Error { case unrepresentable }

@MainActor
func validateHooks(providerPath: String, callerPath: String) async throws {
    func check(_ condition: Bool) { precondition(condition) }
    guard let caller = dlopen(callerPath, RTLD_NOW | RTLD_LOCAL) else { fatalError(String(cString: dlerror())) }
    defer { dlclose(caller) }
    let runtime = ABIRuntime()
    let provider = ImageSelector.path(URL(fileURLWithPath: providerPath))
    let importer = ImageSelector.path(URL(fileURLWithPath: callerPath))
    let integer = try await runtime.swiftFunction(named: "SwiftFunctionFixture.hookEcho(_:)",
        as: ((Int64) -> Int64).self, genericArguments: [.type(Int64.self)], in: provider)
    let text = try await runtime.swiftFunction(named: "SwiftFunctionFixture.hookEcho(_:)",
        as: ((String) -> String).self, genericArguments: [.type(String.self)], in: provider)
    let intCaller = try await runtime.swiftFunction(named: "SwiftExtensionFixture.importedHookInteger(_:)",
        as: ((Int64) -> Int64).self, in: importer)
    let textCaller = try await runtime.swiftFunction(named: "SwiftExtensionFixture.importedHookString(_:)",
        as: ((String) -> String).self, in: importer)
    let arrayCaller = try await runtime.swiftFunction(named: "SwiftExtensionFixture.importedHookArray(_:)",
        as: (([String]) -> [String]).self, in: importer)
    check(try unsafe intCaller.unsafeInvoke(40) == 40)
    let failures = Mutex(0)
    let failure: @Sendable (any Error) -> Void = { _ in failures.withLock { $0 += 1 } }
    let intHook = try unsafe await integer.hookImportedCalls(in: importer, using: runtime, onFailure: failure) {
        (call: NativeSwiftFunctionInvocation<(Int64) -> Int64>, value) in
        try call.proceed(value + 1) + 10
    }
    defer { intHook.invalidate() }
    let textHook = try unsafe await text.hookImportedCalls(in: importer, using: runtime, onFailure: failure) {
        (call: NativeSwiftFunctionInvocation<(String) -> String>, value) in
        try call.proceed(value + " hook")
    }
    defer { textHook.invalidate() }
    check(try unsafe intCaller.unsafeInvoke(40) == 51)
    check(try unsafe textCaller.unsafeInvoke("value") == "value hook")
    check(try unsafe arrayCaller.unsafeInvoke(["untouched"]) == ["untouched"])
    intHook.invalidate(); textHook.invalidate()
    check(try unsafe textCaller.unsafeInvoke("value") == "value")

    let throwing = try await runtime.swiftFunction(named: "SwiftFunctionFixture.hookThrowing(_:)",
        as: ((Int64) throws(NSError) -> Int64).self, in: provider)
    let throwingCaller = try await runtime.swiftFunction(named: "SwiftExtensionFixture.importedHookThrowing(_:)",
        as: ((Int64) throws(NSError) -> Int64).self, in: importer)
    check(try unsafe throwingCaller.unsafeInvoke(1) == 2)
    let errorHook = try unsafe await throwing.hookImportedCalls(in: importer, using: runtime, onFailure: failure) {
        (call: NativeSwiftFunctionInvocation<(Int64) throws(NSError) -> Int64>, value) in
        if value == 99 { throw NSError(domain: "hook-consumer", code: 99) }
        let result = try call.proceed(value)
        if value == 98 { throw ConsumerHookFailure.unrepresentable }
        return result + 5
    }
    defer { errorHook.invalidate() }
    check(try unsafe throwingCaller.unsafeInvoke(1) == 7)
    check(try unsafe throwingCaller.unsafeInvoke(98) == 99)
    for (value, domain) in [(Int64(-1), "native-hook-consumer"), (Int64(99), "hook-consumer")] {
        do { _ = try unsafe throwingCaller.unsafeInvoke(value); fatalError("Expected a native error") }
        catch let error as NativeSwiftError {
            error.withUnderlyingError { check(($0 as NSError).domain == domain && ($0 as NSError).code == Int(value)) }
        }
    }
    check(failures.withLock { $0 } == 1)
    errorHook.invalidate()
    check(try unsafe throwingCaller.unsafeInvoke(1) == 2)
}

@MainActor
func validateAsyncHooks(providerPath: String, callerPath: String) async throws {
    func check(_ condition: Bool) { precondition(condition) }
    guard let caller = dlopen(callerPath, RTLD_NOW | RTLD_LOCAL) else { fatalError(String(cString: dlerror())) }
    defer { dlclose(caller) }
    let runtime = ABIRuntime()
    let provider = ImageSelector.path(URL(fileURLWithPath: providerPath))
    let importer = ImageSelector.path(URL(fileURLWithPath: callerPath))
    let failures = Mutex(0)
    let failure: @Sendable (any Error) -> Void = { _ in failures.withLock { $0 += 1 } }
    typealias Echo = nonisolated(nonsending) (Int64) async -> Int64
    let integer = try await runtime.swiftFunction(named: "SwiftFunctionFixture.hookAsyncEcho(_:)",
        as: Echo.self, genericArguments: [.type(Int64.self)], in: provider)
    let integerCaller = try await runtime.swiftFunction(named: "SwiftExtensionFixture.importedAsyncHookInteger(_:)", as: Echo.self, in: importer)
    let textCaller = try await runtime.swiftFunction(named: "SwiftExtensionFixture.importedAsyncHookString(_:)",
        as: (nonisolated(nonsending) (String) async -> String).self, in: importer)
    check(try unsafe await integerCaller.unsafeInvoke(1) == 1)
    let integerHook = try unsafe await integer.hookImportedCalls(in: importer, using: runtime, onFailure: failure) {
        (call: NativeSwiftFunctionInvocation<Echo>, value) in
        await Task.yield()
        return try await call.proceed(value + 10) + 100
    }
    defer { integerHook.invalidate() }
    check(try unsafe await integerCaller.unsafeInvoke(1) == 111)
    check(try unsafe await textCaller.unsafeInvoke("unmatched") == "unmatched")
    integerHook.invalidate()
    check(try unsafe await integerCaller.unsafeInvoke(1) == 1)
    typealias Throwing = nonisolated(nonsending) (Int64) async throws(NSError) -> String
    let throwing = try await runtime.swiftFunction(named: "SwiftFunctionFixture.hookAsyncThrowing(_:)", as: Throwing.self, in: provider)
    let throwingCaller = try await runtime.swiftFunction(named: "SwiftExtensionFixture.importedAsyncHookThrowing(_:)", as: Throwing.self, in: importer)
    _ = try unsafe await throwingCaller.unsafeInvoke(1)
    let errorHook = try unsafe await throwing.hookImportedCalls(in: importer, using: runtime, onFailure: failure) { call, value in
        let result = try await call.proceed(value)
        if value == 98 { throw ConsumerHookFailure.unrepresentable }
        return result + "-hook"
    }
    defer { errorHook.invalidate() }
    check(try unsafe await throwingCaller.unsafeInvoke(1) == String(repeating: "value:1", count: 100) + "-hook")
    check(try unsafe await throwingCaller.unsafeInvoke(98) == String(repeating: "value:98", count: 100))
    do { _ = try unsafe await throwingCaller.unsafeInvoke(-1); fatalError("Expected a native async failure") }
    catch let error as NativeSwiftError {
        error.withUnderlyingError { check(($0 as NSError).domain == "native-async-hook-consumer") }
    }
    errorHook.invalidate()
    let type = try await runtime.swiftType(named: "SwiftFunctionFixture.AsyncHookRenderer", in: provider)
    let method = try await type.method(named: "render(_:)", as: (nonisolated(nonsending) (String) async -> String).self)
    let make = try await runtime.swiftFunction(named: "SwiftFunctionFixture.makeAsyncHookRenderer() -> SwiftFunctionFixture.AsyncHookRenderer",
        as: (() -> AnyObject).self, in: provider)
    let object = try unsafe make.unsafeInvoke()
    let methodCaller = try await runtime.swiftFunction(
        named: "SwiftExtensionFixture.importedAsyncHookMethod(SwiftFunctionFixture.AsyncHookRenderer, Swift.String) async -> Swift.String",
        as: (nonisolated(nonsending) (AnyObject, String) async -> String).self, in: importer)
    let identity = ObjectIdentifier(object)
    let methodHook = try unsafe await method.hookVirtualCalls(onFailure: failure) { call, value in
        let receiver = try call.receiver(as: AnyObject.self)
        precondition(ObjectIdentifier(receiver) == identity)
        return try await call.proceed(value + "-hook")
    }
    defer { methodHook.invalidate() }
    check(try unsafe await methodCaller.unsafeInvoke(object, "value") == "value-hook-native")
    methodHook.invalidate()
    check(try unsafe await methodCaller.unsafeInvoke(object, "value") == "value-native")
    check(failures.withLock { $0 } == 1)
}

@MainActor
func prepareGenericGetters(type: NativeSwiftType, object: NativeObject) async throws {
    _ = try await type.getter(named: "checked", as: (() throws -> String).self,
                       declaredAs: "() throws(B) -> A")
    _ = try await type.staticGetter(named: "checkedType", as: (() throws -> String.Type).self,
                             declaredAs: "() throws(B) -> A.Type")
    _ = try await object.getter(named: "delayedChecked", as: (() async throws -> String).self,
                               declaredAs: "() async throws(B) -> A")
}

func prepare<Signature>(named name: String, as signature: Signature.Type, in scope: ImageSelector,
                        using runtime: ABIRuntime) async throws -> NativeSwiftFunction<Signature> {
    try await runtime.swiftFunction(named: name, as: signature, in: scope)
}

// Compile the Sendable entry points outside ABIBridge; the independent provider
// tests exercise their mutations and predecessor calls with actual import slots.
@MainActor
func prepareSendableHooks(function: NativeSwiftFunction<@Sendable (Int64) -> Int64>,
                          method: NativeSwiftMethod<@Sendable (Int64) -> Int64>,
                          importer: ImageSelector) async throws {
    let first = try await unsafe function.hookImportedCalls(in: importer, onFailure: { _ in }) { call, value in
        try call.proceed(value)
    }
    first.invalidate()
    let second = try await unsafe function.hookMainActorImportedCalls(in: importer, onFailure: { _ in }) { call, value in
        try call.proceed(value)
    }
    second.invalidate()
    let third = try await unsafe method.hookImportedCalls(in: importer, onFailure: { _ in }) { call, value in
        try call.proceed(value)
    }
    third.invalidate()
    let fourth = try await unsafe method.hookMainActorImportedCalls(in: importer, onFailure: { _ in }) { call, value in
        try call.proceed(value)
    }
    fourth.invalidate()
    let fifth = try await unsafe method.hookVirtualCalls(onFailure: { _ in }) { call, value in try call.proceed(value) }
    fifth.invalidate()
    let sixth = try await unsafe method.hookMainActorVirtualCalls(onFailure: { _ in }) { call, value in try call.proceed(value) }
    sixth.invalidate()
    _ = try await unsafe function.prepareImportedReplacement(with: function, in: importer)
    _ = try await unsafe method.prepareImportedReplacement(with: method, in: importer)
    _ = try unsafe method.prepareVirtualReplacement(with: method)
}

struct ThreeValue: ABIBridgeValue {
    static let abiType = try! NativeType.structure(
        named: "SwiftFunctionFixture.Three", fields: [.int64, .int64, .int64]
    )
    let values: (Int64, Int64, Int64)
    init(_ a: Int64, _ b: Int64, _ c: Int64) { values = (a, b, c) }
    init(nativeValue: NativeValue) throws {
        values = try unsafe nativeValue.read(as: (Int64, Int64, Int64).self)
    }
    static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value.values, as: abiType)
    }
}

@MainActor
func prepare(_ path: String) async throws -> NativeSwiftFunction<(String) -> String> {
    guard let original = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        fatalError(String(cString: dlerror()))
    }
    defer { dlclose(original) }
    let runtime = ABIRuntime()
    let scope = ImageSelector.path(URL(fileURLWithPath: path))
    let answer = try await runtime.swiftFunction(
        named: "SwiftFunctionFixture.answer()", as: (() -> Int64).self, in: scope
    )
    let value = try unsafe answer.unsafeInvoke()
    precondition(value == 42)
    let function = try await prepare(
        named: "SwiftFunctionFixture.decorate(_:)", as: ((String) -> String).self, in: scope, using: runtime
    )
    let transform = try await runtime.swiftFunction(
        named: "SwiftFunctionFixture.transform(SwiftFunctionFixture.Three) -> SwiftFunctionFixture.Three",
        as: ((ThreeValue) -> ThreeValue).self, in: scope
    )
    let transformed = try unsafe transform.unsafeInvoke(.init(1, 2, 3))
    precondition(transformed.values == (2, 4, 6))
    await runtime.removeCachedResults()
    return function
}

let path = CommandLine.arguments[1]
let function = try await prepare(path)
for length in [0, 1, 100, 4096] {
    let value = String(repeating: "a", count: length)
    let result = try unsafe function.unsafeInvoke(value)
    precondition(result == value + "!")
}
guard let retained = dlopen(path, RTLD_NOW | RTLD_NOLOAD) else {
    fatalError("The function's image must remain loaded.")
}
dlclose(retained)
// Swift's runtime may itself keep an image loaded after its last explicit
// loader reference. This fixture only asserts the invocation lifetime.
print("Swift function consumer passed")
if CommandLine.arguments.count > 2 {
    try await validateHooks(providerPath: path, callerPath: CommandLine.arguments[2])
    print("Swift generic and throwing hook consumer passed")
    try await validateAsyncHooks(providerPath: path, callerPath: CommandLine.arguments[2])
    print("Swift async hook consumer passed")
}
