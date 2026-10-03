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
    let run: NativeSwiftFunction<(NativeSwiftClosure<() -> Bool>, AnyObject, String, UnsafeMutablePointer<Int32>, NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void>) -> Bool>
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
            as: ((NativeSwiftClosure<() -> Bool>, AnyObject, String, UnsafeMutablePointer<Int32>, NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void>) -> Bool).self,
            genericArguments: [.type(Bool.self)], valueABIs: [type: .opaque(named: type.name)], in: scope),
        reference: runtime.swiftFunction(named: "ManagedSwiftFixtures.referenceRuntimeRecord(_:_:_:)",
            as: ((AnyObject, String, UnsafeMutablePointer<Int32>) -> String).self, in: scope))
}

private let prepared = try await prepare(CommandLine.arguments[1])
// The provider's concrete type is not imported. Preparation's runtime and
// original loader reference have ended; the public handles retain their images.
private let state = State()
let callback = try NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void> { value in
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


typealias ConsumingInput = NativeSwiftClosure<(NativeSwiftConsuming<NativeSwiftValue>) -> Int64>
let consumeInput = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.visitNonthrowingConsumingRuntimeValue<A where A: ~Swift.Copyable>(__owned A, (__owned A) -> Swift.Int64) -> Swift.Int64",
    as: ((NativeSwiftConsuming<NativeSwiftValue>, ConsumingInput) -> Int64).self,
    genericArguments: [.type(moved.type)], in: source)
let consumedInputTicket = try unsafe makeTicket.unsafeInvoke(NSObject())
let consumingInput = try ConsumingInput { incoming in state.owned = incoming.value; return 42 }
guard try unsafe consumeInput.unsafeInvoke(NativeSwiftConsuming(consumedInputTicket), consumingInput) == 42,
      consumedInputTicket.isConsumed, let received = state.owned,
      try unsafe readTicket.unsafeInvoke(on: received) == 42 else { throw ConsumerError.wrongResult }
print("Consuming callback inputs transfer noncopyable native ownership into retained runtime handles")


typealias InoutInput = NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Void>
let mutateInput = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.visitRuntimeInout<A where A: ~Swift.Copyable>(inout A, (inout A) throws -> ()) throws -> ()",
    as: ((NativeSwiftInout<NativeSwiftValue>, InoutInput) throws -> Void).self,
    genericArguments: [.type(received.type)], in: source)
let addTicket = try await received.type.method(named: "add(_:)", as: ((Int64) -> Void).self,
    receiverABI: .opaque(named: received.type.name), mutating: true)
let mutateBody = try InoutInput { view in
    state.borrow = view
    try unsafe addTicket.unsafeInvoke(on: view, Int64(8))
}
try unsafe mutateInput.unsafeInvoke(NativeSwiftInout(received), mutateBody)
guard try unsafe readTicket.unsafeInvoke(on: received) == 50 else { throw ConsumerError.wrongResult }
do { try unsafe addTicket.unsafeInvoke(on: state.borrow!, Int64(1)); throw ConsumerError.wrongResult }
catch NativeSwiftBorrowError.expiredBorrow { }
print("Runtime inout callback views mutate noncopyable values and expire after native completion")


typealias OwnedNested = NativeSwiftClosure<(NativeSwiftConsuming<NativeSwiftClosure<(Int64) -> Int64>>) -> Void>
let deliverOwned = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.visitOwnedNested<A>(A, () -> (), (__owned (A) -> A) -> ()) -> ()",
    as: ((Int64, NativeSwiftClosure<() -> Void>, OwnedNested) -> Void).self,
    genericArguments: [.type(Int64.self)], in: source)
state.text = "live"
try unsafe deliverOwned.unsafeInvoke(42, NativeSwiftClosure { state.text = "destroyed" },
    OwnedNested { state.closure = $0.value })
guard try unsafe state.closure!.unsafeInvoke(0) == 42, state.text == "live" else { throw ConsumerError.wrongResult }
state.closure = nil
guard state.text == "destroyed" else { throw ConsumerError.wrongResult }
print("Consuming nested closure inputs remain callable after delivery and release captures exactly once")


let pairType = try await runtime.swiftType(named: "ManagedSwiftFixtures.RuntimeFixedPair", in: source)
let pairABI = try NativeType.structure(named: pairType.name, fields: [.int64, .int64])
let pairABIs = [pairType: pairABI]
let makePair = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.makeRuntimeFixedPair(Swift.Int64, Swift.Int64) -> ManagedSwiftFixtures.RuntimeFixedPair",
    as: ((Int64, Int64) -> NativeSwiftValue).self, valueABIs: pairABIs, in: source)
let pair = try unsafe makePair.unsafeInvoke(35, 7)
let sumPair = try await pairType.method(named: "sum()", as: (() -> Int64).self, receiverABI: pairABI)
typealias PairBody = NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Int64>
let inspectPair = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.inspectRuntimeFixedPair(ManagedSwiftFixtures.RuntimeFixedPair, (ManagedSwiftFixtures.RuntimeFixedPair) -> Swift.Int64) -> Swift.Int64",
    as: ((NativeSwiftValue, PairBody) -> Int64).self, valueABIs: pairABIs, in: source)
state.error = nil
let pairBody = try PairBody { value in
    do { return try unsafe sumPair.unsafeInvoke(on: value) }
    catch { state.error = error; return -1 }
}
guard try unsafe inspectPair.unsafeInvoke(pair, pairBody) == 42, pairABIs[pair.type] == pairABI else { throw ConsumerError.wrongResult }
if let error = state.error { throw error }
print("Explicit fixed Swift components compose runtime-only values and callbacks without importing their type")


typealias ClosureData = NativeSwiftClosure<() -> Int64>
let closureData = try ClosureData { Int64(42) }
let copyClosureData = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.callRuntimeCopy<A>((A) -> A, A) -> A",
    as: ((NativeSwiftClosure<(ClosureData) -> ClosureData>, ClosureData) -> ClosureData).self,
    genericArguments: [.type(ClosureData.self)], in: source)
let closureIdentity = try NativeSwiftClosure<(ClosureData) -> ClosureData> { $0 }
let copiedClosureData = try unsafe copyClosureData.unsafeInvoke(closureIdentity, closureData)
guard try unsafe copiedClosureData.unsafeInvoke() == 42 else { throw ConsumerError.wrongResult }
typealias ConsumingClosureDataReader = NativeSwiftClosure<(NativeSwiftConsuming<ClosureData>) -> Int64>
let consumeClosureData = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.visitNonthrowingConsumingRuntimeValue<A where A: ~Swift.Copyable>(__owned A, (__owned A) -> Swift.Int64) -> Swift.Int64",
    as: ((NativeSwiftConsuming<ClosureData>, ConsumingClosureDataReader) -> Int64).self,
    genericArguments: [.type(ClosureData.self)], in: source)
let consumeClosureBody = try ConsumingClosureDataReader { value in
    do { return try unsafe value.value.copy().unsafeInvoke() }
    catch { return -1 }
}
guard try unsafe consumeClosureData.unsafeInvoke(NativeSwiftConsuming(closureData), consumeClosureBody) == 42 else { throw ConsumerError.wrongResult }
typealias BorrowingClosureDataReader = NativeSwiftClosure<(NativeSwiftBorrowing<ClosureData>) throws -> Int64>
let borrowClosureData = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.visitRuntimeValue<A where A: ~Swift.Copyable>(A, (A) throws -> Swift.Int64) throws -> Swift.Int64",
    as: ((ClosureData, BorrowingClosureDataReader) throws -> Int64).self,
    genericArguments: [.type(ClosureData.self)], in: source)
let borrowClosureBody = try BorrowingClosureDataReader { try unsafe $0.value.copy().unsafeInvoke() }
guard try unsafe borrowClosureData.unsafeInvoke(closureData, borrowClosureBody) == 42 else { throw ConsumerError.wrongResult }
typealias AsyncClosureDataReader = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftBorrowing<ClosureData>) async throws -> Int64>
let readClosureData = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.visitRuntimeValueAsync<A where A: ~Swift.Copyable>(A, nonisolated(nonsending) (A) async throws -> Swift.Int64) async throws -> Swift.Int64",
    as: (nonisolated(nonsending) (ClosureData, AsyncClosureDataReader) async throws -> Int64).self,
    genericArguments: [.type(ClosureData.self)], in: source)
let readClosureBody: nonisolated(nonsending) @Sendable (NativeSwiftBorrowing<ClosureData>) async throws -> Int64 = { value in
    await Task.yield()
    return try unsafe value.value.copy().unsafeInvoke()
}
guard try unsafe await readClosureData.unsafeInvoke(closureData, AsyncClosureDataReader(readClosureBody)) == 42 else { throw ConsumerError.wrongResult }
print("Callbacks copy and return closure wrappers bound as native generic data, including after suspension")


do {
        typealias Reader = NativeSwiftClosure<(NativeSwiftValue, NativeSwiftValue) -> Int64>
        typealias AsyncReader = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftValue, NativeSwiftValue) async -> Int64>
        let factory = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeMixedRuntimeReader<A, B>(A.Type, B.Type) -> (A, B) -> Swift.Int64",
            as: ((Int64.Type, NativeSwiftValue.Type) -> Reader).self,
            genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)])
        let reader = try unsafe factory.unsafeInvoke(Int64.self, NativeSwiftValue.self)
        let correct = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.callMixedRuntimeReader<A, B>((A, B) -> Swift.Int64, A, B) -> Swift.Int64",
            as: ((Reader, Int64, NativeSwiftValue) -> Int64).self,
            genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)])
        guard try unsafe correct.unsafeInvoke(reader, 35, pair) == 42 else { throw ConsumerError.wrongResult }
        let swapped = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.callMixedRuntimeReader<A, B>((A, B) -> Swift.Int64, A, B) -> Swift.Int64",
            as: ((Reader, NativeSwiftValue, Int64) -> Int64).self,
            genericArguments: [.type(NativeSwiftValue.self), .type(Int64.self)])
        do { _ = try unsafe swapped.unsafeInvoke(reader, pair, 35) as Int64; throw ConsumerError.wrongResult }
        catch ABIResolutionError.signatureMismatch { }

        let asyncFactory = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.makeMixedRuntimeAsyncReader<A, B>(A.Type, B.Type) -> nonisolated(nonsending) (A, B) async -> Swift.Int64",
            as: ((Int64.Type, NativeSwiftValue.Type) -> AsyncReader).self,
            genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)])
        let asyncReader = try unsafe asyncFactory.unsafeInvoke(Int64.self, NativeSwiftValue.self)
        let asyncCorrect = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.callMixedRuntimeAsyncReader<A, B>(nonisolated(nonsending) (A, B) async -> Swift.Int64, A, B) async -> Swift.Int64",
            as: (nonisolated(nonsending) (AsyncReader, Int64, NativeSwiftValue) async -> Int64).self,
            genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)])
        guard try unsafe await asyncCorrect.unsafeInvoke(asyncReader, 35, pair) == 42 else { throw ConsumerError.wrongResult }
        let asyncSwapped = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.callMixedRuntimeAsyncReader<A, B>(nonisolated(nonsending) (A, B) async -> Swift.Int64, A, B) async -> Swift.Int64",
            as: (nonisolated(nonsending) (AsyncReader, NativeSwiftValue, Int64) async -> Int64).self,
            genericArguments: [.type(NativeSwiftValue.self), .type(Int64.self)])
        do { _ = try unsafe await asyncSwapped.unsafeInvoke(asyncReader, pair, 35) as Int64; throw ConsumerError.wrongResult }
        catch ABIResolutionError.signatureMismatch { }
}
print("Native closure compatibility preserves every mixed runtime-value argument position")

do {
    typealias Callback = NativeSwiftClosure<(Int64) -> Int64>
    typealias Snapshot = (lead: Int8, record: NativeSwiftValue, nested: (callback: Callback, text: String, tail: Int8))
    typealias BorrowedSnapshot = (lead: Int8, record: NativeSwiftBorrowedValue, nested: (callback: Callback, text: String, tail: Int8))
    typealias Inspect = NativeSwiftClosure<(BorrowedSnapshot) throws -> Int64>
    let nativeSnapshot = "(lead: Swift.Int8, record: ManagedSwiftFixtures.RuntimeFixedPair, nested: (callback: (Swift.Int64) -> Swift.Int64, text: Swift.String, tail: Swift.Int8))"
    let make = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.makeCompositionSnapshot(Swift.AnyObject, Swift.Int64, Swift.Int64, Swift.String) -> " + nativeSnapshot,
        as: ((AnyObject, Int64, Int64, String) -> Snapshot).self, valueABIs: pairABIs, in: source)
    let echo = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.echoCompositionSnapshot(" + nativeSnapshot + ") -> " + nativeSnapshot,
        as: ((Snapshot) -> Snapshot).self, valueABIs: pairABIs, in: source)
    let inspect = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.inspectCompositionSnapshot(" + nativeSnapshot + ", (" + nativeSnapshot + ") throws -> Swift.Int64) throws -> Swift.Int64",
        as: ((Snapshot, Inspect) throws -> Int64).self, valueABIs: pairABIs, in: source)
    let consume = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.consumeCompositionSnapshot(__owned " + nativeSnapshot + ") -> " + nativeSnapshot,
        as: ((NativeSwiftConsuming<Snapshot>) -> Snapshot).self, valueABIs: pairABIs, in: source)
    let text = String(repeating: "tuple", count: 100)
    let snapshot = try unsafe make.unsafeInvoke(NSObject(), 35, 7, text)
    guard snapshot.lead == 11, snapshot.nested.text == text, snapshot.nested.tail == -7,
          try unsafe sumPair.unsafeInvoke(on: snapshot.record) == 42,
          try unsafe snapshot.nested.callback.unsafeInvoke(0) == 42 else { throw ConsumerError.wrongResult }
    let echoed = try unsafe echo.unsafeInvoke(snapshot)
    let body = try Inspect { value in
        guard value.lead == 11, value.nested.text == text, value.nested.tail == -7 else { throw ConsumerError.wrongResult }
        return try unsafe sumPair.unsafeInvoke(on: value.record) + value.nested.callback.unsafeInvoke(0)
    }
    guard try unsafe inspect.unsafeInvoke(echoed, body) == 84 else { throw ConsumerError.wrongResult }
    let moved = try unsafe consume.unsafeInvoke(NativeSwiftConsuming(snapshot))
    guard snapshot.record.isConsumed, !echoed.record.isConsumed,
          try unsafe sumPair.unsafeInvoke(on: moved.record) == 42,
          try unsafe moved.nested.callback.unsafeInvoke(0) == 42 else { throw ConsumerError.wrongResult }
    print("Nested tuples carry runtime-only records, native closures, and owned results without importing provider types")

    typealias OwnedTuple = (Int8, NativeSwiftValue, Int64)
    typealias BorrowedTuple = (Int8, NativeSwiftBorrowedValue, Int64)
    typealias AsyncBody = NativeSwiftClosure<nonisolated(nonsending) (BorrowedTuple) async throws -> OwnedTuple>
    let transform = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.transformRuntimeTupleAsync<A>((Swift.Int8, A, Swift.Int64), nonisolated(nonsending) ((Swift.Int8, A, Swift.Int64)) async throws -> (Swift.Int8, A, Swift.Int64)) async throws -> (Swift.Int8, A, Swift.Int64)",
        as: (nonisolated(nonsending) (OwnedTuple, AsyncBody) async throws -> OwnedTuple).self,
        genericArguments: [.type(pairType)], in: source)
    let copy: nonisolated(nonsending) @Sendable (BorrowedTuple) async throws -> OwnedTuple = { value in
        await Task.yield()
        guard try unsafe sumPair.unsafeInvoke(on: value.1) == 42 else { throw ConsumerError.wrongResult }
        return (value.0 + 1, try value.1.copy(), value.2 + 1)
    }
    let resumed = try unsafe await transform.unsafeInvoke((11, pair, 90), AsyncBody(copy))
    guard resumed.0 == 12, resumed.2 == 91, !pair.isConsumed,
          try unsafe sumPair.unsafeInvoke(on: resumed.1) == 42 else { throw ConsumerError.wrongResult }
    print("Async tuple callbacks copy borrowed native fields and return owned values after awaiting")

    typealias Edit = NativeSwiftClosure<(NativeSwiftInout<Callback>) throws -> Void>
    typealias EditPair = NativeSwiftClosure<(NativeSwiftInout<Callback>, NativeSwiftInout<Callback>) throws -> Int64>
    let swap = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.swapRuntimeClosures<A>(inout (A) -> A, inout (A) -> A) -> ()",
        as: ((NativeSwiftInout<Callback>, NativeSwiftInout<Callback>) -> Void).self,
        genericArguments: [.type(Int64.self)], in: source)
    let visit = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.visitRuntimeClosure<A>(inout (A) -> A, (inout (A) -> A) throws -> ()) throws -> ()",
        as: ((NativeSwiftInout<Callback>, Edit) throws -> Void).self, genericArguments: [.type(Int64.self)], in: source)
    let first = NativeSwiftInout(try Callback { $0 + 7 })
    let second = NativeSwiftInout(try Callback { $0 * 2 })
    try unsafe swap.unsafeInvoke(first, second)
    guard try unsafe first.value.unsafeInvoke(21) == 42,
          try unsafe second.value.unsafeInvoke(35) == 42 else { throw ConsumerError.wrongResult }
    let replaceAndThrow = try Edit { value in
        value.value = try Callback { $0 + 1 }
        throw ConsumerError.callback("body")
    }
    do { try unsafe visit.unsafeInvoke(first, replaceAndThrow); throw ConsumerError.wrongResult }
    catch let error as NativeSwiftError {
        guard error.withUnderlyingError({ if case ConsumerError.callback("body") = $0 { return true }; return false }) else { throw error }
    }
    guard try unsafe first.value.unsafeInvoke(41) == 42,
          try unsafe second.value.unsafeInvoke(35) == 42 else { throw ConsumerError.wrongResult }
    print("Inout closures swap native contexts and publish replacements even when the callback throws")

    let capture = try NativeSwiftClosure<(Callback) throws -> Int64> { value in
        state.closure = value
        return try unsafe value.unsafeInvoke(0)
    }
    _ = try unsafe nestedVisit.unsafeInvoke(capture)
    guard let expired = state.closure else { throw ConsumerError.wrongResult }
    do { _ = try expired.copy(); throw ConsumerError.wrongResult }
    catch NativeSwiftBorrowError.expiredBorrow { }
    let visitPair = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.visitRuntimeClosurePair<A>(inout (A) -> A, inout (A) -> A, (inout (A) -> A, inout (A) -> A) throws -> Swift.Int64) throws -> Swift.Int64",
        as: ((NativeSwiftInout<Callback>, NativeSwiftInout<Callback>, EditPair) throws -> Int64).self,
        genericArguments: [.type(Int64.self)], in: source)
    for bodyFails in [false, true] {
        let invalid = try EditPair { first, second in
            first.value = try Callback { $0 + 100 }
            second.value = expired
            if bodyFails { throw ConsumerError.callback("body") }
            return 99
        }
        do { _ = try unsafe visitPair.unsafeInvoke(first, second, invalid); throw ConsumerError.wrongResult }
        catch let error as NativeSwiftError {
            let preservesErrors = error.withUnderlyingError { underlying in
                let writeback: any Error
                if bodyFails {
                    guard let combined = underlying as? NativeSwiftWritebackError,
                          case ConsumerError.callback("body") = combined.invocationError else { return false }
                    writeback = combined.writebackError
                } else { writeback = underlying }
                if case ABIResolutionError.unsupportedDeclaration = writeback { return true }
                return false
            }
            guard preservesErrors else { throw error }
        }
        guard try unsafe first.value.unsafeInvoke(41) == 42,
              try unsafe second.value.unsafeInvoke(35) == 42 else { throw ConsumerError.wrongResult }
    }
    print("Failed closure writeback preserves both native slots and reports the callback and conversion failures")
}

let genericOpaque = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.makeRuntimeOpaque<A>(A) -> some",
    as: ((String) -> NativeSwiftValue).self, genericArguments: [.type(String.self)], in: source)
let opaqueValue = try unsafe genericOpaque.unsafeInvoke("opaque")
guard try opaqueValue.withCopy({ $0 as? String }) == "opaque" else { throw ConsumerError.wrongResult }
let opaquePair = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.makeRuntimeOpaquePair<A, B>(A, B) -> (some, some)",
    as: ((String, Int) -> (NativeSwiftValue, NativeSwiftValue)).self,
    genericArguments: [.type(String.self), .type(Int.self)], in: source)
let pairResult = try unsafe opaquePair.unsafeInvoke("pair", 42)
guard try pairResult.0.withCopy({ $0 as? String }) == "pair",
      try pairResult.1.withCopy({ $0 as? Int }) == 42 else { throw ConsumerError.wrongResult }
let opaqueClosure = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.makeRuntimeOpaqueClosure<A>(A) -> () -> some",
    as: ((String) -> NativeSwiftClosure<() -> NativeSwiftValue>).self,
    genericArguments: [.type(String.self)], in: source)
let closureResult = try unsafe opaqueClosure.unsafeInvoke("closure")
guard try unsafe closureResult.unsafeInvoke().withCopy({ $0 as? String }) == "closure" else { throw ConsumerError.wrongResult }
let opaqueOwner = try await runtime.swiftType(named: "ManagedSwiftFixtures.RuntimeOpaqueOwner",
    in: source, genericArguments: [.type(String.self)])
let ownerInit = try await opaqueOwner.initializer(named: "init(_:)", as: ((String) -> AnyObject).self)
let instance = try unsafe ownerInit.unsafeInvoke("owner")
let ownerGetter = try await opaqueOwner.getter(named: "opaque", as: (() -> NativeSwiftValue).self)
guard try unsafe ownerGetter.unsafeInvoke(on: instance).withCopy({ $0 as? String }) == "owner" else { throw ConsumerError.wrongResult }
let ownerMethod = try await opaqueOwner.method(named: "make(_:)", as: ((Int) -> NativeSwiftValue).self,
    genericArguments: [.type(Int.self)])
let memberResult = try unsafe ownerMethod.unsafeInvoke(on: instance, 42)
guard try memberResult.withCopy({ ($0 as? (String, Int))?.1 }) == 42 else { throw ConsumerError.wrongResult }
print("Generic opaque factories, nested results, and enclosing member bindings work without importing provider types")
for name in ["makeRuntimeExtended", "makeRuntimeExtendedObject"] {
    let protocolName = name == "makeRuntimeExtended" ? "RuntimeExtendedSource" : "RuntimeExtendedObject"
    let call = try await runtime.swiftFunction(
        named: "ManagedSwiftFixtures.\(name)<A>(A) -> any ManagedSwiftFixtures.\(protocolName)<Self.Element == A>",
        as: ((Int) -> NativeSwiftValue).self, genericArguments: [.type(Int.self)], in: source)
    let value = try unsafe call.unsafeInvoke(42)
    guard try value.withCopy({ ($0 as? any CustomStringConvertible)?.description }) == "42" else { throw ConsumerError.wrongResult }
}
typealias ExtendedCallback = NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Int>
let applyExtended = try await runtime.swiftFunction(
    named: "ManagedSwiftFixtures.applyRuntimeExtendedObject<A>((any ManagedSwiftFixtures.RuntimeExtendedObject<Self.Element == A>) -> Swift.Int, A) -> Swift.Int",
    as: ((ExtendedCallback, Int) -> Int).self, genericArguments: [.type(Int.self)], in: source)
let extendedCallback = try ExtendedCallback { value in
    do { return try value.copy().withCopy { ($0 as? any CustomStringConvertible)?.description == "42" ? 42 : -1 } }
    catch { return -2 }
}
guard try unsafe applyExtended.unsafeInvoke(extendedCallback, 42) == 42 else { throw ConsumerError.wrongResult }
print("Runtime-only parameterized protocols preserve opaque and class payloads without compiler-emitted shapes")
