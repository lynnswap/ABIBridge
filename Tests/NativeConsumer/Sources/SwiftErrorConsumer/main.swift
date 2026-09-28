import ABIBridge
import Darwin
import Foundation

private struct PayloadError: Error { let code: Int64 }

@MainActor
func prepareError(_ path: String) async throws -> NativeSwiftError {
    guard let original = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { fatalError(String(cString: dlerror())) }
    defer { dlclose(original) }
    let runtime = ABIRuntime()
    let call = try await runtime.swiftFunction(named: "ErrorLease.fail(_:)",
        as: ((UnsafeRawPointer) throws -> Void).self, in: .path(URL(fileURLWithPath: path)))
    let value: any Error = PayloadError(code: 42)
    let result: NativeSwiftError
    do {
        try withUnsafePointer(to: value) { pointer in
            let reference = UnsafeRawPointer(pointer).load(as: UnsafeRawPointer.self)
            try unsafe call.unsafeInvoke(reference)
        }
        fatalError("Expected native failure")
    } catch let error as NativeSwiftError { result = error }
    await runtime.removeCachedResults()
    return result
}

func isLoaded(_ path: String) -> Bool {
    guard let handle = dlopen(path, RTLD_NOW | RTLD_NOLOAD) else { return false }
    dlclose(handle)
    return true
}

let path = CommandLine.arguments[1]
var error: NativeSwiftError? = try await prepareError(path)
precondition(isLoaded(path))
error?.withUnderlyingError { precondition(($0 as? PayloadError)?.code == 42) }
error = nil
precondition(!isLoaded(path))
print("Native Swift errors retain their code image until final destruction")
