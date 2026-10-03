import ABIBridge
import Darwin
import Foundation

private enum ConsumerError: Error { case load(String), wrongResult, callback(String) }

private final class State: @unchecked Sendable {
    var text = ""
    var borrow: NativeSwiftBorrowedValue?
    var owned: NativeSwiftValue?
    var closure: NativeSwiftClosure<(Int64) -> Int64>?
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

let visitTicket = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.visitRuntimeValue<A where A: ~Swift.Copyable>(A, (A) throws -> Swift.Int64) throws -> Swift.Int64",
    as: ((NativeSwiftValue, NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Int64>) throws -> Int64).self,
    genericArguments: [.type(moved.type)], in: source)
let ticketCallback = try NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Int64> { value in
    state.borrow = value
    return try unsafe readTicket.unsafeInvoke(on: value)
}
guard try unsafe visitTicket.unsafeInvoke(moved, ticketCallback) == 42, !moved.isConsumed,
      let expiredTicket = state.borrow else { throw ConsumerError.wrongResult }
do {
    _ = try unsafe readTicket.unsafeInvoke(on: expiredTicket)
    throw ConsumerError.wrongResult
} catch NativeSwiftBorrowError.expiredBorrow { }

let readTicketAsync = try await moved.type.method(named: "readAsync()", as: (nonisolated(nonsending) () async -> Int64).self,
    receiverABI: .opaque(named: moved.type.name))
typealias AsyncTicketBody = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftBorrowedValue) async throws -> Int64>
let visitTicketAsync = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.visitRuntimeValueAsync<A where A: ~Swift.Copyable>(A, nonisolated(nonsending) (A) async throws -> Swift.Int64) async throws -> Swift.Int64",
    as: (nonisolated(nonsending) (NativeSwiftValue, AsyncTicketBody) async throws -> Int64).self,
    genericArguments: [.type(moved.type)], in: source)
let readBorrow: nonisolated(nonsending) @Sendable (NativeSwiftBorrowedValue) async throws -> Int64 = { value in
    await Task.yield()
    return try unsafe await readTicketAsync.unsafeInvoke(on: value)
}
guard try unsafe await visitTicketAsync.unsafeInvoke(moved, AsyncTicketBody(readBorrow)) == 42,
      !moved.isConsumed else { throw ConsumerError.wrongResult }
print("Common Swift callbacks preserve runtime borrows through synchronous and async calls")

let makeProducer = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeRuntimeProducer<A>(A) -> () -> A",
    as: ((String) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
    genericArguments: [.type(String.self)], in: source)
let produce = try unsafe makeProducer.unsafeInvoke("returned closure")
let produced = try unsafe produce.unsafeInvoke()
typealias RuntimeCopy = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftValue) async -> NativeSwiftValue>
let makeCopy = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.makeRuntimeAsyncCopy<A>(A.Type) -> nonisolated(nonsending) (A) async -> A",
    as: ((String.Type) -> RuntimeCopy).self, genericArguments: [.type(String.self)], in: source)
let copy = try unsafe makeCopy.unsafeInvoke(String.self)
let copied = try unsafe await copy.unsafeInvoke(produced)
guard try copied.take(as: String.self) == "returned closure", !produced.isConsumed else {
    throw ConsumerError.wrongResult
}
print("Returned Swift closures share runtime value conversion across sync and async invocation")

typealias RuntimeProducer = NativeSwiftClosure<() throws -> NativeSwiftValue>
let produceTicket = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.callRuntimeProducer<A where A: ~Swift.Copyable>(() throws -> A) throws -> A",
    as: ((RuntimeProducer) throws -> NativeSwiftValue).self, genericArguments: [.type(moved.type)], in: source)
state.owned = moved
let transferTicket = try RuntimeProducer { state.owned! }
let callbackTicket = try unsafe produceTicket.unsafeInvoke(transferTicket)
guard moved.isConsumed, !callbackTicket.isCopyable,
      try unsafe readTicket.unsafeInvoke(on: callbackTicket) == 42 else { throw ConsumerError.wrongResult }
do {
    _ = try unsafe produceTicket.unsafeInvoke(transferTicket)
    throw ConsumerError.wrongResult
} catch let error as NativeSwiftError {
    guard error.withUnderlyingError({ ($0 as? NativeSwiftValueError) == .consumedValue }) else { throw error }
}
print("Host callbacks transfer runtime-only noncopyable results and preserve native conversion errors")

let makeConcrete = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.makeConcreteRuntimeCopy() -> (Swift.String) -> Swift.String",
    as: (() -> NativeSwiftClosure<(NativeSwiftValue) -> NativeSwiftValue>).self, in: source)
let concrete = try unsafe makeConcrete.unsafeInvoke()
guard try unsafe concrete.unsafeInvoke(produced).take(as: String.self) == "returned closure!" else {
    throw ConsumerError.wrongResult
}
print("Nongeneric returned closures use their native value declaration without generic arguments")

let nestedVisit = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.visitNestedClosure(_:)",
    as: ((NativeSwiftClosure<(NativeSwiftClosure<(Int64) -> Int64>) throws -> Int64>) throws -> Int64).self, in: source)
let nestedBody = try NativeSwiftClosure<(NativeSwiftClosure<(Int64) -> Int64>) throws -> Int64> { value in
    state.closure = value
    return try unsafe value.unsafeInvoke(20)
}
guard try unsafe nestedVisit.unsafeInvoke(nestedBody) == 42 else { throw ConsumerError.wrongResult }
do { _ = try unsafe state.closure!.unsafeInvoke(1); throw ConsumerError.wrongResult }
catch NativeSwiftBorrowError.expiredBorrow { }
let nestedProducer = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.callClosureProducer(_:)",
    as: ((NativeSwiftClosure<() throws -> NativeSwiftClosure<(Int64) -> Int64>>) throws -> Int64).self, in: source)
let closureProducer = try NativeSwiftClosure<() throws -> NativeSwiftClosure<(Int64) -> Int64>> {
    try NativeSwiftClosure { (value: Int64) in value + 7 }
}
guard try unsafe nestedProducer.unsafeInvoke(closureProducer) == 42 else { throw ConsumerError.wrongResult }
print("Nested closure inputs expire with native scopes and owned results reach native callers")

typealias NestedRuntimeCopy = NativeSwiftClosure<(NativeSwiftValue) -> NativeSwiftValue>
typealias NestedRuntimeBody = NativeSwiftClosure<(NestedRuntimeCopy, NativeSwiftValue) throws -> NativeSwiftValue>
let nestedRuntime = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.visitNestedRuntime<A>(A, ((A) -> A, A) throws -> A) throws -> A",
    as: ((NativeSwiftValue, NestedRuntimeBody) throws -> NativeSwiftValue).self, genericArguments: [.type(String.self)], in: source)
let nestedRuntimeBody = try NestedRuntimeBody { copy, value in try unsafe copy.unsafeInvoke(value) }
guard try unsafe nestedRuntime.unsafeInvoke(produced, nestedRuntimeBody).take(as: String.self) == "returned closure" else {
    throw ConsumerError.wrongResult
}
typealias GenericProducer = NativeSwiftClosure<() throws -> NativeSwiftClosure<(String) -> String>>
let genericClosureProducer = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.callNestedRuntimeProducer<A>(() throws -> (A) -> A, A) throws -> A",
    as: ((GenericProducer, String) throws -> String).self, genericArguments: [.type(String.self)], in: source)
let genericProducer = try GenericProducer { try NativeSwiftClosure { (value: String) in value + "!" } }
guard try unsafe genericClosureProducer.unsafeInvoke(genericProducer, "nested") == "nested!" else { throw ConsumerError.wrongResult }
print("Generic nested callbacks decode runtime values and publish native closure results")


typealias SavedInner = NativeSwiftClosure<(Int64) -> Int64>
typealias SaveInput = NativeSwiftClosure<(SavedInner) throws -> Void>
let copyVisit = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.visitEscapingNestedClosure(_:)",
    as: ((SaveInput) throws -> Void).self, in: source)
try unsafe copyVisit.unsafeInvoke(SaveInput { state.closure = try $0.copy() })
guard try unsafe state.closure!.unsafeInvoke(35) == 42 else { throw ConsumerError.wrongResult }
print("An explicit copy retains an escaping native closure beyond its callback scope")

typealias NativeNestedCaller = NativeSwiftClosure<(SavedInner, Int64) -> Int64>
let nativeNestedFactory = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeConcreteNestedCaller()",
    as: (() -> NativeNestedCaller).self, in: source)
let nativeNestedCall = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.callNestedRuntimeCaller<A>(((A) -> A, A) -> A, A) -> A",
    as: ((NativeNestedCaller, Int64) -> Int64).self, genericArguments: [.type(Int64.self)], in: source)
let nativeNestedCaller = try unsafe nativeNestedFactory.unsafeInvoke()
guard try unsafe nativeNestedCall.unsafeInvoke(nativeNestedCaller, 42) == 42 else { throw ConsumerError.wrongResult }
print("Native nested callers reabstract concrete and generic inner callback ABIs")

typealias NativeAsyncInner = NativeSwiftClosure<nonisolated(nonsending) (Int64) async -> Int64>
typealias NativeAsyncProducer = NativeSwiftClosure<nonisolated(nonsending) () async -> NativeAsyncInner>
let nativeAsyncFactory = try await runtime.swiftFunction(named: "ManagedSwiftFixtures.makeConcreteNestedAsyncProducer()",
    as: (() -> NativeAsyncProducer).self, in: source)
let nativeAsyncCall = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.callNestedRuntimeAsyncProducer<A>(nonisolated(nonsending) () async -> nonisolated(nonsending) (A) async -> A, A) async -> A",
    as: (nonisolated(nonsending) (NativeAsyncProducer, Int64) async -> Int64).self, genericArguments: [.type(Int64.self)], in: source)
let nativeAsyncProducer = try unsafe nativeAsyncFactory.unsafeInvoke()
guard try unsafe await nativeAsyncCall.unsafeInvoke(nativeAsyncProducer, 35) == 42 else { throw ConsumerError.wrongResult }
print("Native async nested results retain their context through generic handback and suspension")
