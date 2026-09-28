import ABIBridge
import Darwin
import Foundation

private struct PayloadError: Error { let code: Int64 }

@inline(never) public func handoff(_ body: @escaping (UnsafeRawPointer) throws -> Void) -> (UnsafeRawPointer) throws -> Void { body }

@MainActor
func prepareClosureError(_ path: String, factoryPath: String, handoffs: Int) async throws -> NativeSwiftError {
    guard let original = dlopen(path, RTLD_NOW | RTLD_LOCAL),
          let accessor = dlsym(original, "ABIErrorLeaseEntry") else { fatalError(String(cString: dlerror())) }
    defer { dlclose(original) }
    let entry = unsafeBitCast(accessor, to: (@convention(c) () -> UnsafeRawPointer).self)()
    let runtime = ABIRuntime()
    let factory = try await runtime.swiftFunction(named: "ErrorClosureFactory.make(_:)",
        as: ((UnsafeRawPointer) -> NativeSwiftThrowingClosure<Void, any Error, UnsafeRawPointer>).self,
        in: .path(URL(fileURLWithPath: factoryPath)))
    var closure = try unsafe factory.unsafeInvoke(UnsafeRawPointer(entry))
    let identity = try await runtime.swiftFunction(named: "SwiftErrorConsumer.handoff(_:)",
        as: ((NativeSwiftThrowingClosure<Void, any Error, UnsafeRawPointer>) -> NativeSwiftThrowingClosure<Void, any Error, UnsafeRawPointer>).self)
    for _ in 0..<handoffs { closure = try unsafe identity.unsafeInvoke(closure) }
    let value: any Error = PayloadError(code: 43)
    let result: NativeSwiftError
    do {
        try withUnsafePointer(to: value) { pointer in
            let reference = UnsafeRawPointer(pointer).load(as: UnsafeRawPointer.self)
            try unsafe closure.unsafeInvoke(reference)
        }
        fatalError("Expected native closure failure")
    } catch let error as NativeSwiftError { result = error }
    await runtime.removeCachedResults()
    return result
}

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
for handoffs in [0, 1, 5] {
    error = try await prepareClosureError(path, factoryPath: CommandLine.arguments[2], handoffs: handoffs)
    precondition(isLoaded(path), "An escaped closure error must retain the entry's image after every native handoff")
    error?.withUnderlyingError { precondition(($0 as? PayloadError)?.code == 43) }
    error = nil
    precondition(!isLoaded(path), "Final error destruction must release the entry image")
}
print("Native Swift errors retain their code image until final destruction")
