import ABIBridge
import Darwin
import Foundation

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
print("Swift closure consumer passed")
