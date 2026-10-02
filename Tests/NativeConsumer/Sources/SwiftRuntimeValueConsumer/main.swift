import ABIBridge
import Darwin
import Foundation

private enum ConsumerError: Error { case load(String), wrongResult, callback(String) }

private final class State: @unchecked Sendable {
    var text = ""
    var borrow: NativeSwiftBorrowedValue?
    var owned: NativeSwiftValue?
    var error: (any Error)?
}

private struct Prepared {
    let type: NativeSwiftType
    let text: NativeSwiftMethod<() -> String>
    let cancel: NativeSwiftMethod<() -> Void>
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
        text: type.getter(named: "text", as: (() -> String).self, receiverABI: .opaque(named: type.name)),
        cancel: type.method(named: "cancel()", as: (() -> Void).self, receiverABI: .opaque(named: type.name)),
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
        state.owned = try value.copy()
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
guard let owned = state.owned,
      try unsafe prepared.text.unsafeInvoke(on: owned) == input else { throw ConsumerError.wrongResult }
print("Direct generic invocation and ordinary members on owned and borrowed runtime values passed")

let runtime = ABIRuntime()
let source = ImageSelector.path(URL(fileURLWithPath: CommandLine.arguments[1]))
let makeTicket = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeRuntimeTicket(_:)",
    as: ((AnyObject) -> NativeSwiftValue).self, in: source)
let ticket = try unsafe makeTicket.unsafeInvoke(NSObject())
let moveTicket = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.moveRuntimeValue<A where A: ~Swift.Copyable>(__owned A) -> A",
    as: ((NativeSwiftConsuming<NativeSwiftValue>) -> NativeSwiftValue).self,
    genericArguments: [.type(ticket.type)], in: source)
let moved = try unsafe moveTicket.unsafeInvoke(NativeSwiftConsuming(ticket))
guard ticket.isConsumed && !moved.isCopyable else { throw ConsumerError.wrongResult }
let readTicket = try await moved.type.method(named: "read()", as: (() -> Int64).self,
    receiverABI: .opaque(named: moved.type.name))
guard try unsafe readTicket.unsafeInvoke(on: moved) == 42 else { throw ConsumerError.wrongResult }
let copyRecord = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
    as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(owned.type)], in: source)
let copiedRecord = try unsafe copyRecord.unsafeInvoke(owned)
guard !owned.isConsumed && copiedRecord.isCopyable,
      try unsafe prepared.text.unsafeInvoke(on: copiedRecord) == input else { throw ConsumerError.wrongResult }
print("Runtime-only generic arguments preserve native copying and noncopyable transfer")
