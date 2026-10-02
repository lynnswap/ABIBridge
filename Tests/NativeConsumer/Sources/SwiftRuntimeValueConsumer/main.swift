import ABIBridge
import Darwin
import Foundation

private enum ConsumerError: Error { case load(String), wrongResult, callback(String) }

private final class State: @unchecked Sendable {
    var text = ""
    var borrow: NativeSwiftBorrowedValue?
    var error: (any Error)?
}

private struct Prepared {
    let type: NativeSwiftType
    let text: NativeSwiftBorrowedMethod<String>
    let cancel: NativeSwiftBorrowedMethod<Void>
    let run: NativeSwiftFunction<(NativeSwiftClosure<() -> Bool>, AnyObject, String, UnsafeMutablePointer<Int32>, NativeSwiftBorrowingClosure<Void>) -> Bool>
    let reference: NativeSwiftFunction<(AnyObject, String, UnsafeMutablePointer<Int32>) -> String>
}

@MainActor private func prepare(_ path: String) async throws -> Prepared {
    guard let loader = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw ConsumerError.load(String(cString: dlerror())) }
    defer { dlclose(loader) }
    let runtime = ABIRuntime()
    let scope = ImageSelector.path(URL(fileURLWithPath: path))
    let type = try await runtime.swiftType(named: "ManagedSwiftFixtures.RuntimeRecord", in: scope)
    return try await Prepared(type: type,
        text: type.borrowedGetter(named: "text", as: String.self),
        cancel: type.borrowedMethod(named: "cancel()", as: (() -> Void).self),
        run: runtime.swiftFunction(
            named: "ManagedSwiftFixtures.runAndVisitGeneric<A>(() -> A, Swift.AnyObject, Swift.String, Swift.UnsafeMutablePointer<Swift.Int32>, (ManagedSwiftFixtures.RuntimeRecord) -> ()) -> A",
            as: ((NativeSwiftClosure<() -> Bool>, AnyObject, String, UnsafeMutablePointer<Int32>, NativeSwiftBorrowingClosure<Void>) -> Bool).self,
            genericArguments: [.type(Bool.self)], in: scope),
        reference: runtime.swiftFunction(named: "ManagedSwiftFixtures.referenceRuntimeRecord(_:_:_:)",
            as: ((AnyObject, String, UnsafeMutablePointer<Int32>) -> String).self, in: scope))
}

private let prepared = try await prepare(CommandLine.arguments[1])
// The provider's concrete type is not imported. Preparation's runtime and
// original loader reference have ended; the public handles retain their images.
private let state = State()
let callback = try NativeSwiftBorrowingClosure(borrowing: prepared.type) { value in
    do {
        state.text += try unsafe prepared.text.unsafeInvoke(on: value)
        try unsafe prepared.cancel.unsafeInvoke(on: value)
        state.borrow = value
    } catch { state.error = error }
}
let count = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
count.initialize(to: 0)
defer { count.deinitialize(count: 1); count.deallocate() }
let object = NSObject()
let input = String(repeating: "managed", count: 100)
var applications = 0
let result = try unsafe NativeSwiftClosure<() -> Bool>.withUnsafeNonescaping({ applications += 1; return true }) {
    try unsafe prepared.run.unsafeInvoke($0, object, input, count, callback)
}
if let error = state.error { throw ConsumerError.callback(String(describing: error)) }
guard result && applications == 1 && count.pointee == 3 else { throw ConsumerError.wrongResult }
let expected = try unsafe prepared.reference.unsafeInvoke(object, input, count)
guard state.text == expected, let expired = state.borrow else { throw ConsumerError.wrongResult }
do {
    _ = try unsafe prepared.text.unsafeInvoke(on: expired)
    throw ConsumerError.wrongResult
} catch NativeSwiftBorrowError.expiredBorrow { }
print("Direct generic invocation and runtime-only borrowed values passed")
