import ABIBridge
import Darwin
import Foundation

public final class StoredForeignClosure {
    let callback: (Int64) -> Int64
    init(_ callback: @escaping (Int64) -> Int64) { self.callback = callback }
    public func callAsFunction(_ value: Int64) -> Int64 { callback(value) }
}

@inline(never) public func storeForeign(_ callback: @escaping (Int64) -> Int64) -> StoredForeignClosure {
    StoredForeignClosure(callback)
}

@MainActor
func prepareEscapingForeignClosure(_ path: String) async throws -> StoredForeignClosure {
    guard let original = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { fatalError(String(cString: dlerror())) }
    defer { dlclose(original) }
    let runtime = ABIRuntime()
    let factory = try await runtime.swiftFunction(
        named: "ClosureLease.makeClosure()", as: (() -> NativeSwiftClosure<Int64, Int64>).self,
        in: .path(URL(fileURLWithPath: path))
    )
    let retain = try await runtime.swiftFunction(
        named: "SwiftClosureConsumer.storeForeign(_:)",
        as: ((NativeSwiftClosure<Int64, Int64>) -> StoredForeignClosure).self
    )
    let value = try unsafe factory.unsafeInvoke()
    let result = try unsafe retain.unsafeInvoke(value)
    await runtime.removeCachedResults()
    return result
}

func isLoaded(_ path: String) -> Bool {
    guard let handle = dlopen(path, RTLD_NOW | RTLD_NOLOAD) else { return false }
    dlclose(handle)
    return true
}

@MainActor
func prepareClosure(_ path: String) async throws -> NativeSwiftClosure<Int64, Int64> {
    guard let original = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        fatalError(String(cString: dlerror()))
    }
    defer { dlclose(original) }
    let runtime = ABIRuntime()
    let scope = ImageSelector.path(URL(fileURLWithPath: path))
    let apply = try await runtime.swiftFunction(
        named: "SwiftFunctionFixture.applyClosure(_:_:)",
        as: ((NativeSwiftClosure<Int64, Int64>, Int64) -> Int64).self, in: scope
    )
    let callback = try NativeSwiftClosure { (value: Int64) in value + 7 }
    let applied = try unsafe apply.unsafeInvoke(callback, 35)
    precondition(applied == 42)
    let make = try await runtime.swiftFunction(
        named: "SwiftFunctionFixture.makeAdder(_:)",
        as: ((Int64) -> NativeSwiftClosure<Int64, Int64>).self, in: scope
    )
    let result = try unsafe make.unsafeInvoke(7)
    await runtime.removeCachedResults()
    return result
}

let callback = try await prepareClosure(CommandLine.arguments[1])
// The lookup runtime, factory handles, and original loader reference have ended.
for value: Int64 in [0, 35, 100] {
    let result = try unsafe callback.unsafeInvoke(value)
    precondition(result == value + 7)
}
let foreignPath = CommandLine.arguments[2]
var stored: StoredForeignClosure? = try await prepareEscapingForeignClosure(foreignPath)
precondition(isLoaded(foreignPath), "The escaping native copy must retain its entry image")
precondition(stored!(35) == 42)
stored = nil
precondition(!isLoaded(foreignPath), "The final native context release must release its entry image")
print("Swift closure consumer passed")
