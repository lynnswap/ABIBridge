import ABIBridge
import Darwin
import Foundation

private struct PayloadError: Error { let code: Int64 }

@inline(never) public func handoff(_ body: @escaping (UnsafeRawPointer) throws -> Void) -> (UnsafeRawPointer) throws -> Void { body }
public typealias AsyncForeignErrorClosure = @Sendable @concurrent (UnsafeRawPointer) async throws -> Void
@inline(never) public func handoffAsync(_ body: @escaping AsyncForeignErrorClosure) -> AsyncForeignErrorClosure { body }

@MainActor
func prepareAsyncClosureError(_ path: String, factoryPath: String, handoffs: Int) async throws -> NativeSwiftError {
    guard let original = dlopen(path, RTLD_NOW | RTLD_LOCAL),
          let accessor = dlsym(original, "ABIAsyncLeaseEntry") else { fatalError(String(cString: dlerror())) }
    defer { dlclose(original) }
    let descriptor = unsafeBitCast(accessor, to: (@convention(c) () -> UnsafeRawPointer).self)()
    let runtime = ABIRuntime()
    typealias Callback = NativeSwiftClosure<@Sendable @concurrent (UnsafeRawPointer) async throws -> Void>
    let factory = try await runtime.swiftFunction(named: "ErrorClosureFactory.makeAsync(_:)",
        as: ((UnsafeRawPointer) -> Callback).self, in: .path(URL(fileURLWithPath: factoryPath)))
    let identity = try await runtime.swiftFunction(named: "SwiftErrorConsumer.handoffAsync(_:)",
        as: ((Callback) -> Callback).self)
    var closure = try unsafe factory.unsafeInvoke(descriptor)
    for _ in 0..<handoffs { closure = try unsafe identity.unsafeInvoke(closure) }
    let value: any Error = PayloadError(code: 44)
    defer { withExtendedLifetime(value) {} }
    let reference = withUnsafePointer(to: value) { UnsafeRawPointer($0).load(as: UnsafeRawPointer.self) }
    let result: NativeSwiftError
    do {
        try unsafe await closure.unsafeInvoke(reference)
        fatalError("Expected native async closure failure")
    } catch let error as NativeSwiftError { result = error }
    await runtime.removeCachedResults()
    return result
}

@MainActor
func prepareClosureError(_ path: String, factoryPath: String, handoffs: Int) async throws -> NativeSwiftError {
    guard let original = dlopen(path, RTLD_NOW | RTLD_LOCAL),
          let accessor = dlsym(original, "ABIErrorLeaseEntry") else { fatalError(String(cString: dlerror())) }
    defer { dlclose(original) }
    let entry = unsafeBitCast(accessor, to: (@convention(c) () -> UnsafeRawPointer).self)()
    let runtime = ABIRuntime()
    let factory = try await runtime.swiftFunction(named: "ErrorClosureFactory.make(_:)",
        as: ((UnsafeRawPointer) -> NativeSwiftClosure<(UnsafeRawPointer) throws -> Void>).self,
        in: .path(URL(fileURLWithPath: factoryPath)))
    var closure = try unsafe factory.unsafeInvoke(UnsafeRawPointer(entry))
    let identity = try await runtime.swiftFunction(named: "SwiftErrorConsumer.handoff(_:)",
        as: ((NativeSwiftClosure<(UnsafeRawPointer) throws -> Void>) -> NativeSwiftClosure<(UnsafeRawPointer) throws -> Void>).self)
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
let asyncPath = CommandLine.arguments[3]
for handoffs in [0, 1, 5] {
    error = try await prepareAsyncClosureError(asyncPath, factoryPath: CommandLine.arguments[2], handoffs: handoffs)
    precondition(isLoaded(asyncPath), "An escaped async closure error must retain its implementation after native handoffs")
    error?.withUnderlyingError { precondition(($0 as? PayloadError)?.code == 44) }
    error = nil
    precondition(!isLoaded(asyncPath), "Final async error destruction must release its implementation image")
}
print("Native Swift errors retain their code image until final destruction")
