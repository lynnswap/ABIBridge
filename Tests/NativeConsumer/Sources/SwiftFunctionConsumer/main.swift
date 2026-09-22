import ABIBridge
import Darwin
import Foundation

@MainActor
func prepare(_ path: String) async throws -> NativeSwiftFunction<String, String> {
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
    let function = try await runtime.swiftFunction(
        named: "SwiftFunctionFixture.decorate(_:)", as: ((String) -> String).self, in: scope
    )
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
