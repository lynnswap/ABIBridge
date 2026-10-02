import ABIBridge
import Darwin
import Foundation

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
