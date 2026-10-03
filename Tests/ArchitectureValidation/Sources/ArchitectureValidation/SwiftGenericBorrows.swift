import ABIBridge
import Foundation
import Synchronization
import SwiftValueFixtures

private final class GenericBorrowCounter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private final class GenericBorrowCapture: Sendable {
    let deaths: GenericBorrowCounter
    init(_ deaths: GenericBorrowCounter) { self.deaths = deaths }
    deinit { deaths.increment() }
}

private final class GenericBorrowState: @unchecked Sendable {
    var texts: [String] = []
    var lengths: [Int] = []
    var borrow: NativeSwiftBorrowedValue?
    var object: AnyObject?
    var failure: (any Error)?
    var owned: NativeSwiftValue?
    var closure: NativeSwiftClosure<(Int64) -> Int64>?
    var ownedClosure: NativeSwiftClosure<(String) -> String>?
    var ownedAsyncClosure: NativeSwiftClosure<nonisolated(nonsending) (String) async -> String>?
}

private enum GenericBorrowConversionError: Error { case converted }
private struct GenericBorrowPointer: ABIBridgeValue, Equatable {
    let address: UInt
    let marker: Int64
    static var abiType: NativeType { .pointer }
    init(_ address: UInt, _ marker: Int64) { self.address = address; self.marker = marker }
    init(nativeValue: NativeValue) throws { throw GenericBorrowConversionError.converted }
    static func nativeValue(from value: Self) throws -> NativeValue { throw GenericBorrowConversionError.converted }
}

@MainActor func validateSwiftGenericBorrows() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let produce = try await runtime.swiftFunction(named: "SwiftValueFixtures.produceGeneric<A>(() -> A) -> A",
        as: ((NativeSwiftClosure<() -> Bool>) -> Bool).self, genericArguments: [.type(Bool.self)])
    var applications = 0
    let scalar = try unsafe NativeSwiftClosure<() -> Bool>.withUnsafeNonescaping({ applications += 1; return true }) {
        try unsafe produce.unsafeInvoke($0)
    }
    try check(scalar && applications == 1, "Generic Bool result and scoped callback preserve caller isolation")

    let stringType = try await runtime.swiftType(named: "Swift.String")
    let string = try await runtime.swiftFunction(named: "SwiftValueFixtures.produceGeneric<A>(() -> A) -> A",
        as: ((NativeSwiftClosure<() -> String>) -> String).self, genericArguments: [.type(stringType)])
    let reference = try await runtime.swiftFunction(named: "SwiftValueFixtures.referenceProducedString(_:)", as: ((String) -> String).self)
    let input = String(repeating: "managed", count: 100)
    let apply = try NativeSwiftClosure { input + "!" }
    let expected = try unsafe reference.unsafeInvoke(input)
    for _ in 0..<20 {
        guard try unsafe string.unsafeInvoke(apply) == expected else {
            throw ArchitectureValidationFailure(description: "Generic String callback differs from compiler-generated call")
        }
    }
    checks.append("Capturing generic String callback matches compiler calls across repeated authenticated entries")

    let echo = try await runtime.swiftFunction(named: "SwiftValueFixtures.replayGeneric<A>(A) -> A",
        as: ((GenericBorrowPointer?) -> GenericBorrowPointer?).self, genericArguments: [.type(GenericBorrowPointer?.self)])
    let pointer = GenericBorrowPointer(0x1000, 42)
    try check(try unsafe echo.unsafeInvoke(pointer) == pointer, "Generic optional wrapper uses actual Swift storage rather than its foreign pointer conversion")
    try check(try unsafe echo.unsafeInvoke(nil) == nil, "Generic optional wrapper preserves nil")

    typealias ClosureData = NativeSwiftClosure<() -> Int64>
    let closureData = try ClosureData { Int64(42) }
    let copyClosureData = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.callRuntimeCallbackCopy<A>((A) -> A, A) -> A",
        as: ((NativeSwiftClosure<(ClosureData) -> ClosureData>, ClosureData) -> ClosureData).self,
        genericArguments: [.type(ClosureData.self)])
    let closureIdentity = try NativeSwiftClosure<(ClosureData) -> ClosureData> { $0 }
    let copiedClosureData = try unsafe copyClosureData.unsafeInvoke(closureIdentity, closureData)
    try check(try unsafe copiedClosureData.unsafeInvoke() == 42,
        "Callbacks copy and return a closure wrapper bound as native generic data")
    typealias ConsumingClosureDataReader = NativeSwiftClosure<(NativeSwiftConsuming<ClosureData>) -> Int64>
    let consumeClosureData = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitNonthrowingConsumingRuntimeValue<A where A: ~Swift.Copyable>(__owned A, (__owned A) -> Swift.Int64) -> Swift.Int64",
        as: ((NativeSwiftConsuming<ClosureData>, ConsumingClosureDataReader) -> Int64).self,
        genericArguments: [.type(ClosureData.self)])
    let consumeClosureBody = try ConsumingClosureDataReader { value in
        do { return try unsafe value.value.copy().unsafeInvoke() }
        catch { return -1 }
    }
    try check(unsafe consumeClosureData.unsafeInvoke(NativeSwiftConsuming(closureData), consumeClosureBody) == 42,
        "Consuming callback inputs preserve closure wrappers bound as ordinary generic data")
    typealias BorrowingClosureDataReader = NativeSwiftClosure<(NativeSwiftBorrowing<ClosureData>) throws -> Int64>
    let borrowClosureData = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitRuntimeCallback<A where A: ~Swift.Copyable>(A, (A) throws -> Swift.Int64) throws -> Swift.Int64",
        as: ((ClosureData, BorrowingClosureDataReader) throws -> Int64).self,
        genericArguments: [.type(ClosureData.self)])
    let borrowClosureBody = try BorrowingClosureDataReader { try unsafe $0.value.copy().unsafeInvoke() }
    try check(unsafe borrowClosureData.unsafeInvoke(closureData, borrowClosureBody) == 42,
        "Borrowing callback inputs preserve closure wrappers bound as ordinary generic data")
    typealias AsyncClosureDataReader = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftBorrowing<ClosureData>) async throws -> Int64>
    let readClosureData = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitRuntimeCallbackAsync<A where A: ~Swift.Copyable>(A, nonisolated(nonsending) (A) async throws -> Swift.Int64) async throws -> Swift.Int64",
        as: (nonisolated(nonsending) (ClosureData, AsyncClosureDataReader) async throws -> Int64).self,
        genericArguments: [.type(ClosureData.self)])
    let readClosureBody: nonisolated(nonsending) @Sendable (NativeSwiftBorrowing<ClosureData>) async throws -> Int64 = { value in
        await Task.yield()
        return try unsafe value.value.copy().unsafeInvoke()
    }
    try check(try unsafe await readClosureData.unsafeInvoke(closureData, AsyncClosureDataReader(readClosureBody)) == 42,
        "Async callbacks preserve owned closure wrappers used as generic data across suspension")

    let type = try await runtime.swiftType(named: "SwiftValueFixtures.BorrowedRuntimeRecord")
    let text = try await type.getter(named: "text", as: (() -> String).self, receiverABI: .opaque(named: type.name))
    let changed = try await type.getter(named: "changed", as: (() -> AnyObject?).self, receiverABI: .opaque(named: type.name))
    let length = try await type.method(named: "length()", as: (() -> Int).self, receiverABI: .opaque(named: type.name))
    let cancel = try await type.method(named: "cancel()", as: (() -> Void).self, receiverABI: .opaque(named: type.name))
    let observe = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.observeGeneric<A>(() -> A, Swift.String, Swift.AnyObject, Swift.UnsafeMutablePointer<Swift.Int32>, (SwiftValueFixtures.BorrowedRuntimeRecord) -> ()) -> A",
        as: ((NativeSwiftClosure<() -> Bool>, String, AnyObject, UnsafeMutablePointer<Int32>, NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void>) -> Bool).self,
        genericArguments: [.type(Bool.self)], valueABIs: [type: .opaque(named: type.name)])
    let fire = try await runtime.swiftFunction(named: "SwiftValueFixtures.fireBorrowedRecord(_:_:_:)",
        as: ((String, AnyObject, UnsafeMutablePointer<Int32>) -> Void).self)
    let clear = try await runtime.swiftFunction(named: "SwiftValueFixtures.clearBorrowedRecord()", as: (() -> Void).self)
    let state = GenericBorrowState()
    let captureDeaths = GenericBorrowCounter()
    let valueDeaths = GenericBorrowCounter()
    let cancellations = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    cancellations.initialize(to: 0)
    defer { cancellations.deinitialize(count: 1); cancellations.deallocate() }
    do {
        let capture = GenericBorrowCapture(captureDeaths)
        let callback = try NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Void> { value in
            withExtendedLifetime(capture) {
                do {
                    state.texts.append(try unsafe text.unsafeInvoke(on: value))
                    state.lengths.append(try unsafe length.unsafeInvoke(on: value))
                    state.object = try unsafe changed.unsafeInvoke(on: value)
                    try unsafe cancel.unsafeInvoke(on: value)
                    state.borrow = value
                } catch { state.failure = error }
            }
        }
        let object = GenericBorrowCapture(valueDeaths)
        let result = try unsafe observe.unsafeInvoke(NativeSwiftClosure { true }, input, object, cancellations, callback)
        try check(result, "Generic outer entry accepts a runtime-only borrowed callback")
        if let error = state.failure { throw error }
        try check(state.texts == Array(repeating: input, count: 3), "Borrowed String getter transfers owned results")
        try check(state.lengths == [700, 700, 700], "Borrowed method uses native indirect self")
        try check(state.object === object, "Borrowed object getter preserves native reference identity")
        try check(cancellations.pointee == 3, "Nonmutating borrowed method updates the native referenced state")
    }
    try check(captureDeaths.count == 0, "Native escaping callback retains its captures after wrapper release")
    try check(valueDeaths.count == 0, "Owned getter result outlives the borrowed input")
    state.object = nil
    try check(valueDeaths.count == 1, "Final owned getter result releases its reference once")
    guard let expired = state.borrow else { throw ArchitectureValidationFailure(description: "Missing borrowed callback") }
    do {
        _ = try unsafe text.unsafeInvoke(on: expired)
        throw ArchitectureValidationFailure(description: "Expired borrow remained usable")
    } catch NativeSwiftBorrowError.expiredBorrow { checks.append("Saved borrow rejects access after callback return") }
    try unsafe fire.unsafeInvoke("later", NSObject(), cancellations)
    if let error = state.failure { throw error }
    try check(state.texts.last == "later" && cancellations.pointee == 4, "Retained native callback creates a fresh valid borrow")
    try unsafe clear.unsafeInvoke()
    try check(captureDeaths.count == 1, "Final native callback release destroys captures once")
    checks += try await validateCommonRuntimeCallbacks()
    return checks
}

@MainActor private func validateCommonRuntimeCallbacks() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let copyValue = try await runtime.swiftFunction(named: "SwiftValueFixtures.copyRuntimeValue<A>(A) -> A",
        as: ((String) -> NativeSwiftValue).self, genericArguments: [.type(String.self)])
    let value = try unsafe copyValue.unsafeInvoke("runtime")
    do {
        typealias Reader = NativeSwiftClosure<(NativeSwiftValue, NativeSwiftValue) -> Int64>
        typealias AsyncReader = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftValue, NativeSwiftValue) async -> Int64>
        let factory = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.makeMixedRuntimeReader<A, B>(A.Type, B.Type) -> (A, B) -> Swift.Int64",
            as: ((Int64.Type, NativeSwiftValue.Type) -> Reader).self,
            genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)])
        let reader = try unsafe factory.unsafeInvoke(Int64.self, NativeSwiftValue.self)
        let correct = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.callMixedRuntimeReader<A, B>((A, B) -> Swift.Int64, A, B) -> Swift.Int64",
            as: ((Reader, Int64, NativeSwiftValue) -> Int64).self,
            genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)])
        try check(try unsafe correct.unsafeInvoke(reader, 35, value) == 42, "Mixed runtime payload and ordinary handle inputs preserve their native positions")
        let swapped = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.callMixedRuntimeReader<A, B>((A, B) -> Swift.Int64, A, B) -> Swift.Int64",
            as: ((Reader, NativeSwiftValue, Int64) -> Int64).self,
            genericArguments: [.type(NativeSwiftValue.self), .type(Int64.self)])
        do { _ = try unsafe swapped.unsafeInvoke(reader, value, 35) as Int64; throw ArchitectureValidationFailure(description: "Swapped runtime arguments were accepted") }
        catch ABIResolutionError.signatureMismatch { checks.append("Swapped runtime payload and ordinary handle inputs fail before native invocation") }

        let asyncFactory = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.makeMixedRuntimeAsyncReader<A, B>(A.Type, B.Type) -> nonisolated(nonsending) (A, B) async -> Swift.Int64",
            as: ((Int64.Type, NativeSwiftValue.Type) -> AsyncReader).self,
            genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)])
        let asyncReader = try unsafe asyncFactory.unsafeInvoke(Int64.self, NativeSwiftValue.self)
        let asyncCorrect = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.callMixedRuntimeAsyncReader<A, B>(nonisolated(nonsending) (A, B) async -> Swift.Int64, A, B) async -> Swift.Int64",
            as: (nonisolated(nonsending) (AsyncReader, Int64, NativeSwiftValue) async -> Int64).self,
            genericArguments: [.type(Int64.self), .type(NativeSwiftValue.self)])
        try check(try unsafe await asyncCorrect.unsafeInvoke(asyncReader, 35, value) == 42, "Mixed async closure inputs preserve their native positions across suspension")
        let asyncSwapped = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.callMixedRuntimeAsyncReader<A, B>(nonisolated(nonsending) (A, B) async -> Swift.Int64, A, B) async -> Swift.Int64",
            as: (nonisolated(nonsending) (AsyncReader, NativeSwiftValue, Int64) async -> Int64).self,
            genericArguments: [.type(NativeSwiftValue.self), .type(Int64.self)])
        do { _ = try unsafe await asyncSwapped.unsafeInvoke(asyncReader, value, 35) as Int64; throw ArchitectureValidationFailure(description: "Swapped async runtime arguments were accepted") }
        catch ABIResolutionError.signatureMismatch { checks.append("Swapped async runtime inputs fail before native invocation") }
    }
    do {
        typealias Inner = NativeSwiftClosure<(Int64) -> Int64>
        typealias Producer = NativeSwiftClosure<() -> Inner>
        let factory = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.makeRawRuntimeProducer<A>(A) -> () -> A",
            as: ((Inner) -> Producer).self, genericArguments: [.type(Inner.self)])
        let producer = try unsafe factory.unsafeInvoke(Inner { $0 + 7 })
        try check(try unsafe producer.unsafeInvoke().unsafeInvoke(35) == 42, "Native generic closure data results retain the ordinary Swift wrapper")
        let call = try await runtime.swiftFunction(
            named: "SwiftValueFixtures.callNonthrowingNestedRuntimeProducer<A>(() -> (A) -> A, A) -> A",
            as: ((Producer, Int64) -> Int64).self, genericArguments: [.type(Int64.self)])
        do { _ = try unsafe call.unsafeInvoke(producer, 35) as Int64; throw ArchitectureValidationFailure(description: "Raw closure data was treated as a native function result") }
        catch ABIResolutionError.signatureMismatch { checks.append("Raw generic closure data cannot be reinterpreted as a native function result") }
    }
    let visit = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitRuntimeCallback<A where A: ~Swift.Copyable>(A, (A) throws -> Swift.Int64) throws -> Swift.Int64",
        as: ((NativeSwiftValue, NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Int64>) throws -> Int64).self,
        genericArguments: [.type(value.type)])
    let state = GenericBorrowState()
    let body = try NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Int64> { borrowed in
        state.borrow = borrowed
        return Int64(try borrowed.copy().take(as: String.self).count)
    }
    try check(unsafe visit.unsafeInvoke(value, body) == 7, "Common callback input authenticates and exposes a scoped runtime borrow")
    do {
        _ = try state.borrow!.copy()
        throw ArchitectureValidationFailure(description: "Expired common callback borrow remained usable")
    } catch NativeSwiftBorrowError.expiredBorrow {
        checks.append("Common callback borrow expires after native completion")
    }
    let copyInput = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitRuntimeCallback<A where A: ~Swift.Copyable>(A, (A) throws -> Swift.Int64) throws -> Swift.Int64",
        as: ((NativeSwiftValue, NativeSwiftClosure<(NativeSwiftValue) throws -> Int64>) throws -> Int64).self,
        genericArguments: [.type(value.type)])
    let owned = try NativeSwiftClosure<(NativeSwiftValue) throws -> Int64> { Int64(try $0.take(as: String.self).count) }
    try check(unsafe copyInput.unsafeInvoke(value, owned) == 7 && !value.isConsumed,
        "Common callback input can take an independent copy without consuming its native caller's value")
    typealias AsyncBody = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftBorrowedValue) async throws -> Int64>
    let visitAsync = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitRuntimeCallbackAsync<A where A: ~Swift.Copyable>(A, nonisolated(nonsending) (A) async throws -> Swift.Int64) async throws -> Swift.Int64",
        as: (nonisolated(nonsending) (NativeSwiftValue, AsyncBody) async throws -> Int64).self,
        genericArguments: [.type(value.type)])
    let operation: nonisolated(nonsending) @Sendable (NativeSwiftBorrowedValue) async throws -> Int64 = { borrowed in
        await Task.yield()
        return Int64(try borrowed.copy().take(as: String.self).count)
    }
    try check(unsafe await visitAsync.unsafeInvoke(value, AsyncBody(operation)) == 7,
        "Common async callback input preserves its native borrow across suspension")
    typealias Copy = NativeSwiftClosure<(NativeSwiftValue) -> NativeSwiftValue>
    let make = try await runtime.swiftFunction(named: "SwiftValueFixtures.bindingClosure<A>(A) -> (A) -> A",
        as: ((String) -> Copy).self, genericArguments: [.type(String.self)])
    let copy = try unsafe make.unsafeInvoke("returned")
    let result = try unsafe copy.unsafeInvoke(value)
    try check(result.take(as: String.self) == "returned", "Returned runtime closure authenticates native arguments and owned results")
    let makeConcrete = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeConcreteRuntimeCallback() -> (Swift.String) -> Swift.String", as: (() -> Copy).self)
    let concrete = try unsafe makeConcrete.unsafeInvoke()
    try check(unsafe concrete.unsafeInvoke(value).take(as: String.self) == "runtime!",
        "Nongeneric returned runtime closure preserves its concrete authenticated value ABI")
    let apply = try await runtime.swiftFunction(named: "SwiftValueFixtures.callRuntimeCallbackCopy<A>((A) -> A, A) -> A",
        as: ((Copy, NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(value.type)])
    let passedBack = try unsafe apply.unsafeInvoke(copy, value)
    try check(passedBack.take(as: String.self) == "returned" && !value.isConsumed,
        "Returned runtime closure can be passed back through its native value declaration")
    typealias AsyncCopy = NativeSwiftClosure<nonisolated(nonsending) @Sendable (NativeSwiftValue) async -> NativeSwiftValue>
    let makeAsync = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.bindingAsyncClosure<A where A: Swift.Sendable>(A) -> nonisolated(nonsending) @Sendable (A) async -> A",
        as: ((String) -> AsyncCopy).self, genericArguments: [.type(String.self)])
    let asyncCopy = try unsafe makeAsync.unsafeInvoke("async returned")
    let asyncResult = try unsafe await asyncCopy.unsafeInvoke(value)
    try check(asyncResult.take(as: String.self) == "async returned", "Returned async runtime closure authenticates after native suspension")
    typealias HostCopy = NativeSwiftClosure<(NativeSwiftValue) throws -> NativeSwiftValue>
    let applyHost = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.callRuntimeCallbackResult<A>((A) throws -> A, A) throws -> A",
        as: ((HostCopy, String) throws -> String).self, genericArguments: [.type(String.self)])
    let hostCopy = try HostCopy { value in state.owned = value; return value }
    try check(unsafe applyHost.unsafeInvoke(hostCopy, "host result") == "host result" && state.owned?.isConsumed == true,
        "Host runtime callback result transfers its owned value through the authenticated native entry")
    let invalid = try HostCopy { _ in state.owned! }
    do {
        _ = try unsafe applyHost.unsafeInvoke(invalid, "invalid")
        throw ArchitectureValidationFailure(description: "Consumed callback result remained usable")
    } catch let error as NativeSwiftError {
        try check(error.withUnderlyingError { ($0 as? NativeSwiftValueError) == .consumedValue },
            "Runtime callback result conversion errors propagate through native throws")
    }
    typealias AsyncHostCopy = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftValue) async throws -> NativeSwiftValue>
    let applyAsyncHost = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.callRuntimeAsyncCallbackResult<A>(nonisolated(nonsending) (A) async throws -> A, A) async throws -> A",
        as: (nonisolated(nonsending) (AsyncHostCopy, String) async throws -> String).self, genericArguments: [.type(String.self)])
    let copyAsync: nonisolated(nonsending) @Sendable (NativeSwiftValue) async throws -> NativeSwiftValue = { value in
        await Task.yield()
        return value
    }
    try check(unsafe await applyAsyncHost.unsafeInvoke(AsyncHostCopy(copyAsync), "async host result") == "async host result",
        "Async host runtime callback returns an owned native value after suspension")
    typealias NestedBody = NativeSwiftClosure<(Copy, NativeSwiftValue) throws -> NativeSwiftValue>
    let visitNested = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitNestedRuntime<A>(A, ((A) -> A, A) throws -> A) throws -> A",
        as: ((NativeSwiftValue, NestedBody) throws -> NativeSwiftValue).self, genericArguments: [.type(String.self)])
    let nestedBody = try NestedBody { callback, value in try unsafe callback.unsafeInvoke(value) }
    try check(unsafe visitNested.unsafeInvoke(value, nestedBody).take(as: String.self) == "runtime",
        "Nested runtime callback input uses its generic authenticated value plan")
    let makeNestedCaller = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeNestedRuntimeCaller<A>(A.Type) -> ((A) -> A, A) -> A",
        as: ((String.Type) -> NativeSwiftClosure<(Copy, NativeSwiftValue) -> NativeSwiftValue>).self,
        genericArguments: [.type(String.self)])
    let nestedCaller = try unsafe makeNestedCaller.unsafeInvoke(String.self)
    try check(unsafe nestedCaller.unsafeInvoke(copy, value).take(as: String.self) == "returned",
        "Returned closure passes nested runtime closures through the generic native interface")
    typealias NestedProducer = NativeSwiftClosure<() throws -> NativeSwiftClosure<(String) -> String>>
    let produceNested = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.callNestedRuntimeProducer<A>(() throws -> (A) -> A, A) throws -> A",
        as: ((NestedProducer, String) throws -> String).self, genericArguments: [.type(String.self)])
    let nestedProducer = try NestedProducer { try NativeSwiftClosure { (value: String) in value + "!" } }
    try check(unsafe produceNested.unsafeInvoke(nestedProducer, "nested") == "nested!",
        "Host callback results reabstract nested closures to native generic authentication")
    typealias NestedPackBody = NativeSwiftClosure<(NativeSwiftClosure<(Int64) -> Int64>, NativeSwiftClosure<(String) -> String>) throws -> Int64>
    let visitNestedPack = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitNestedRuntimePack<each A>(_: repeat A.Type, body: (repeat (A) -> A) throws -> Swift.Int64) throws -> Swift.Int64",
        as: ((Int64.Type, String.Type, NestedPackBody) throws -> Int64).self,
        genericArguments: [.pack([.type(Int64.self), .type(String.self)])])
    let nestedPack = try NestedPackBody { number, text in
        let count = try unsafe text.unsafeInvoke("1234567").count
        return try unsafe number.unsafeInvoke(35) + Int64(count)
    }
    try check(unsafe visitNestedPack.unsafeInvoke(Int64.self, String.self, nestedPack) == 42,
        "Nested closure parameter packs retain each native generic function signature")
    typealias NestedAsyncCopy = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftValue) async -> NativeSwiftValue>
    typealias NestedAsyncBody = NativeSwiftClosure<nonisolated(nonsending) (NestedAsyncCopy, NativeSwiftValue) async throws -> NativeSwiftValue>
    let visitNestedAsync = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitNestedRuntimeAsync<A>(A, nonisolated(nonsending) (nonisolated(nonsending) (A) async -> A, A) async throws -> A) async throws -> A",
        as: (nonisolated(nonsending) (String, NestedAsyncBody) async throws -> String).self,
        genericArguments: [.type(String.self)])
    let nestedAsyncBody: nonisolated(nonsending) @Sendable (NestedAsyncCopy, NativeSwiftValue) async throws -> NativeSwiftValue = { copy, value in
        await Task.yield()
        return try unsafe await copy.unsafeInvoke(value)
    }
    try check(unsafe await visitNestedAsync.unsafeInvoke("nested async", NestedAsyncBody(nestedAsyncBody)) == "nested async",
        "Nested async runtime closures preserve native authentication and scoped values after suspension")
    typealias ConsumingInput = NativeSwiftClosure<(NativeSwiftConsuming<NativeSwiftValue>) -> Int64>
    let consumeInput = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitNonthrowingConsumingRuntimeValue<A where A: ~Swift.Copyable>(__owned A, (__owned A) -> Swift.Int64) -> Swift.Int64",
        as: ((NativeSwiftConsuming<NativeSwiftValue>, ConsumingInput) -> Int64).self, genericArguments: [.type(String.self)])
    let consumed = try unsafe copyValue.unsafeInvoke("consumed")
    let captureInput = try ConsumingInput { state.owned = $0.value; return 42 }
    try check(unsafe consumeInput.unsafeInvoke(NativeSwiftConsuming(consumed), captureInput) == 42 && consumed.isConsumed,
        "Consuming runtime callback input authenticates and transfers native ownership")
    try check(state.owned!.take(as: String.self) == "consumed",
        "Consumed callback input retains its payload after native return")
    typealias ConsumingAsyncInput = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftConsuming<NativeSwiftValue>) async throws -> Int64>
    let consumeAsync = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitConsumingRuntimeValueAsync<A where A: ~Swift.Copyable>(__owned A, nonisolated(nonsending) (__owned A) async throws -> Swift.Int64) async throws -> Swift.Int64",
        as: (nonisolated(nonsending) (NativeSwiftConsuming<NativeSwiftValue>, ConsumingAsyncInput) async throws -> Int64).self,
        genericArguments: [.type(String.self)])
    let consumeOperation: nonisolated(nonsending) @Sendable (NativeSwiftConsuming<NativeSwiftValue>) async throws -> Int64 = { incoming in
        await Task.yield()
        state.owned = incoming.value
        return 42
    }
    let suspendedInput = try unsafe copyValue.unsafeInvoke("suspended")
    try check(unsafe await consumeAsync.unsafeInvoke(NativeSwiftConsuming(suspendedInput), ConsumingAsyncInput(consumeOperation)) == 42
        && suspendedInput.isConsumed, "Async consuming input stays owned across suspension")
    try check(state.owned!.take(as: String.self) == "suspended",
        "Async consuming input retains its payload beyond callback completion")
    typealias MutableInput = NativeSwiftClosure<(NativeSwiftBorrowedValue) throws -> Void>
    let mutateInput = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitRuntimeInout<A where A: ~Swift.Copyable>(inout A, (inout A) throws -> ()) throws -> ()",
        as: ((NativeSwiftInout<NativeSwiftValue>, MutableInput) throws -> Void).self, genericArguments: [.type(String.self)])
    let replaceInput = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.replaceRuntimeValue<A where A: ~Swift.Copyable>(inout A, __owned A) -> ()",
        as: ((NativeSwiftInout<NativeSwiftBorrowedValue>, NativeSwiftConsuming<NativeSwiftValue>) -> Void).self,
        genericArguments: [.type(String.self)])
    let mutable = try unsafe copyValue.unsafeInvoke("before")
    state.owned = try unsafe copyValue.unsafeInvoke("after")
    let mutateBody = try MutableInput { view in
        state.borrow = view
        try unsafe replaceInput.unsafeInvoke(NativeSwiftInout(view), NativeSwiftConsuming(state.owned!))
    }
    try unsafe mutateInput.unsafeInvoke(NativeSwiftInout(mutable), mutateBody)
    try check(mutable.take(as: String.self) == "after" && state.owned!.isConsumed,
        "Runtime inout callback authenticates and mutates native storage through its borrowed view")
    do { _ = try state.borrow!.copy(); throw ArchitectureValidationFailure(description: "Mutable borrow escaped") }
    catch NativeSwiftBorrowError.expiredBorrow { checks.append("Mutable callback borrow expires after native completion") }
    typealias TypedInout = NativeSwiftClosure<(NativeSwiftInout<String>) -> Void>
    let typedInout = try await runtime.swiftFunction(named: "SwiftValueFixtures.visitStringInout(_:_:)",
        as: ((NativeSwiftInout<String>, TypedInout) -> Void).self)
    let typedBuffer = NativeSwiftInout("before")
    try unsafe typedInout.unsafeInvoke(typedBuffer, TypedInout { $0.value += " after" })
    try check(typedBuffer.value == "before after", "Known inout callback type authenticates and writes its buffer back")
    typealias OwnedCopy = NativeSwiftClosure<(String) -> String>
    typealias OwnedBody = NativeSwiftClosure<(NativeSwiftConsuming<OwnedCopy>) -> Void>
    let ownedDelivery = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitOwnedNested<A>(A, () -> (), (__owned (A) -> A) -> ()) -> ()",
        as: ((String, NativeSwiftClosure<() -> Void>, OwnedBody) -> Void).self, genericArguments: [.type(String.self)])
    let ownedDeaths = GenericBorrowCounter()
    try unsafe ownedDelivery.unsafeInvoke("owned captured", NativeSwiftClosure { ownedDeaths.increment() },
        OwnedBody { state.ownedClosure = $0.value })
    try check(try unsafe state.ownedClosure!.unsafeInvoke("ignored") == "owned captured" && ownedDeaths.count == 0,
        "Consuming nested input retains its native context and authenticates after delivery")
    state.ownedClosure = nil
    try check(ownedDeaths.count == 1, "Consuming nested input releases its native capture once")
    typealias OwnedAsyncCopy = NativeSwiftClosure<nonisolated(nonsending) (String) async -> String>
    typealias OwnedAsyncBody = NativeSwiftClosure<nonisolated(nonsending) (NativeSwiftConsuming<OwnedAsyncCopy>) async -> Void>
    let ownedAsyncDelivery = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitOwnedNestedAsync<A>(A, () -> (), nonisolated(nonsending) (__owned nonisolated(nonsending) (A) async -> A) async -> ()) async -> ()",
        as: (nonisolated(nonsending) (String, NativeSwiftClosure<() -> Void>, OwnedAsyncBody) async -> Void).self,
        genericArguments: [.type(String.self)])
    let ownedOperation: nonisolated(nonsending) @Sendable (NativeSwiftConsuming<OwnedAsyncCopy>) async -> Void = { incoming in
        await Task.yield()
        state.ownedAsyncClosure = incoming.value
    }
    try unsafe await ownedAsyncDelivery.unsafeInvoke("owned async", NativeSwiftClosure { ownedDeaths.increment() }, OwnedAsyncBody(ownedOperation))
    try check(try unsafe await state.ownedAsyncClosure!.unsafeInvoke("ignored") == "owned async",
        "Consuming async nested input survives delivery and authenticates across suspension")
    state.ownedAsyncClosure = nil
    try check(ownedDeaths.count == 2, "Consuming async nested input releases its native capture once")
    typealias OwnedNumber = NativeSwiftClosure<(Int64) -> Int64>
    typealias OwnedCaller = NativeSwiftClosure<(NativeSwiftConsuming<OwnedNumber>, Int64) -> Int64>
    let ownedFactory = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeConcreteOwnedNestedCaller()", as: (() -> OwnedCaller).self)
    let ownedCall = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.callOwnedNestedRuntimeCaller<A>((__owned (A) -> A, A) -> A, A, () -> ()) -> A",
        as: ((OwnedCaller, Int64, NativeSwiftClosure<() -> Void>) -> Int64).self, genericArguments: [.type(Int64.self)])
    try check(try unsafe ownedCall.unsafeInvoke(ownedFactory.unsafeInvoke(), 42, NativeSwiftClosure { ownedDeaths.increment() }) == 42
        && ownedDeaths.count == 3, "Native consuming nested reabstraction authenticates and transfers exactly one owned context")
    let fixedType = try await runtime.swiftType(named: "SwiftValueFixtures.RuntimeFixedPair")
    let fixedABI = try NativeType.structure(named: fixedType.name, fields: [.int64, .int64])
    let fixedABIs = [fixedType: fixedABI]
    let fixedMake = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeRuntimeFixedPair(Swift.Int64, Swift.Int64) -> SwiftValueFixtures.RuntimeFixedPair",
        as: ((Int64, Int64) -> NativeSwiftValue).self, valueABIs: fixedABIs)
    let fixedValue = try unsafe fixedMake.unsafeInvoke(35, 7)
    let fixedSum = try await fixedType.method(named: "sum()", as: (() -> Int64).self, receiverABI: fixedABI)
    typealias FixedBody = NativeSwiftClosure<(NativeSwiftBorrowedValue) -> Int64>
    let fixedState = GenericBorrowState()
    let fixedBody = try FixedBody { value in
        do { return try unsafe fixedSum.unsafeInvoke(on: value) }
        catch { fixedState.failure = error; return -1 }
    }
    let fixedInspect = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.inspectRuntimeFixedPair(SwiftValueFixtures.RuntimeFixedPair, (SwiftValueFixtures.RuntimeFixedPair) -> Swift.Int64) -> Swift.Int64",
        as: ((NativeSwiftValue, FixedBody) -> Int64).self, valueABIs: fixedABIs)
    try check(try unsafe fixedInspect.unsafeInvoke(fixedValue, fixedBody) == 42 && fixedState.failure == nil,
        "Explicit fixed Swift components authenticate a runtime-only callback input")
    let fixedMember = try await fixedType.method(named: "inspect(_:)", as: ((FixedBody) -> Int64).self,
        valueABIs: fixedABIs, receiverABI: fixedABI)
    try check(try unsafe fixedMember.unsafeInvoke(on: fixedValue, fixedBody) == 42 && fixedABIs[fixedValue.type] == fixedABI,
        "Member callbacks share explicit value ABIs and concrete type identity")
    checks += try await validateComposedRuntimeValues(runtime: runtime, type: fixedType, abi: fixedABI,
        value: fixedValue, sum: fixedSum)
    return checks
}

@MainActor private func validateComposedRuntimeValues(
    runtime: ABIRuntime, type: NativeSwiftType, abi: NativeType, value: NativeSwiftValue,
    sum: NativeSwiftMethod<() -> Int64>
) async throws -> [String] {
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    typealias Callback = NativeSwiftClosure<(Int64) -> Int64>
    typealias Snapshot = (lead: Int8, record: NativeSwiftValue, nested: (callback: Callback, text: String, tail: Int8))
    typealias BorrowedSnapshot = (lead: Int8, record: NativeSwiftBorrowedValue, nested: (callback: Callback, text: String, tail: Int8))
    typealias Inspect = NativeSwiftClosure<(BorrowedSnapshot) throws -> Int64>
    let nativeSnapshot = "(lead: Swift.Int8, record: SwiftValueFixtures.RuntimeFixedPair, nested: (callback: (Swift.Int64) -> Swift.Int64, text: Swift.String, tail: Swift.Int8))"
    let abis = [type: abi]
    let make = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.makeCompositionSnapshot(Swift.AnyObject, Swift.Int64, Swift.Int64, Swift.String) -> " + nativeSnapshot,
        as: ((AnyObject, Int64, Int64, String) -> Snapshot).self, valueABIs: abis)
    let echo = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.echoCompositionSnapshot(" + nativeSnapshot + ") -> " + nativeSnapshot,
        as: ((Snapshot) -> Snapshot).self, valueABIs: abis)
    let inspect = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.inspectCompositionSnapshot(" + nativeSnapshot + ", (" + nativeSnapshot + ") throws -> Swift.Int64) throws -> Swift.Int64",
        as: ((Snapshot, Inspect) throws -> Int64).self, valueABIs: abis)
    let consume = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.consumeCompositionSnapshot(__owned " + nativeSnapshot + ") -> " + nativeSnapshot,
        as: ((NativeSwiftConsuming<Snapshot>) -> Snapshot).self, valueABIs: abis)
    let text = String(repeating: "tuple", count: 100)
    let snapshot = try unsafe make.unsafeInvoke(NSObject(), 35, 7, text)
    try check(snapshot.lead == 11 && snapshot.nested.text == text && snapshot.nested.tail == -7
        && (try unsafe sum.unsafeInvoke(on: snapshot.record)) == 42
        && (try unsafe snapshot.nested.callback.unsafeInvoke(0)) == 42,
        "Nested tuple results preserve runtime-only records, labels, and authenticated native closures")
    let echoed = try unsafe echo.unsafeInvoke(snapshot)
    let inspectBody = try Inspect { incoming in
        guard incoming.lead == 11, incoming.nested.text == text, incoming.nested.tail == -7 else {
            throw ArchitectureValidationFailure(description: "Nested tuple callback fields changed")
        }
        return try unsafe sum.unsafeInvoke(on: incoming.record) + incoming.nested.callback.unsafeInvoke(0)
    }
    try check(try unsafe inspect.unsafeInvoke(echoed, inspectBody) == 84,
        "Tuple callback inputs borrow native fields and authenticate their nested closure")
    let moved = try unsafe consume.unsafeInvoke(NativeSwiftConsuming(snapshot))
    try check(snapshot.record.isConsumed && !echoed.record.isConsumed
        && (try unsafe sum.unsafeInvoke(on: moved.record)) == 42
        && (try unsafe moved.nested.callback.unsafeInvoke(0)) == 42,
        "Consuming tuple arguments transfer runtime fields while independent returned copies remain usable")

    typealias OwnedTuple = (Int8, NativeSwiftValue, Int64)
    typealias BorrowedTuple = (Int8, NativeSwiftBorrowedValue, Int64)
    typealias AsyncBody = NativeSwiftClosure<nonisolated(nonsending) (BorrowedTuple) async throws -> OwnedTuple>
    let transform = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.transformRuntimeTupleAsync<A>((Swift.Int8, A, Swift.Int64), nonisolated(nonsending) ((Swift.Int8, A, Swift.Int64)) async throws -> (Swift.Int8, A, Swift.Int64)) async throws -> (Swift.Int8, A, Swift.Int64)",
        as: (nonisolated(nonsending) (OwnedTuple, AsyncBody) async throws -> OwnedTuple).self,
        genericArguments: [.type(type)])
    let gate = AsyncValueGate()
    let copy: nonisolated(nonsending) @Sendable (BorrowedTuple) async throws -> OwnedTuple = { incoming in
        await gate.wait()
        guard try unsafe sum.unsafeInvoke(on: incoming.1) == 42 else {
            throw ArchitectureValidationFailure(description: "Suspended tuple borrow changed")
        }
        return (incoming.0 + 1, try incoming.1.copy(), incoming.2 + 1)
    }
    var resumed: OwnedTuple?
    let task = Task { @MainActor in
        resumed = try unsafe await transform.unsafeInvoke((11, value, 90), AsyncBody(copy))
    }
    await gate.waitUntilSuspended()
    await gate.open()
    try await task.value
    guard let resumed else { throw ArchitectureValidationFailure(description: "Missing async tuple result") }
    try check(resumed.0 == 12 && resumed.2 == 91 && !value.isConsumed
        && (try unsafe sum.unsafeInvoke(on: resumed.1)) == 42,
        "Async tuple callbacks retain borrowed native fields through suspension and publish owned results")

    typealias Edit = NativeSwiftClosure<(NativeSwiftInout<Callback>) throws -> Void>
    typealias EditPair = NativeSwiftClosure<(NativeSwiftInout<Callback>, NativeSwiftInout<Callback>) throws -> Int64>
    let swap = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.swapRuntimeClosures<A>(inout (A) -> A, inout (A) -> A) -> ()",
        as: ((NativeSwiftInout<Callback>, NativeSwiftInout<Callback>) -> Void).self,
        genericArguments: [.type(Int64.self)])
    let visit = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitRuntimeClosure<A>(inout (A) -> A, (inout (A) -> A) throws -> ()) throws -> ()",
        as: ((NativeSwiftInout<Callback>, Edit) throws -> Void).self, genericArguments: [.type(Int64.self)])
    let first = NativeSwiftInout(try Callback { $0 + 7 })
    let second = NativeSwiftInout(try Callback { $0 * 2 })
    try unsafe swap.unsafeInvoke(first, second)
    try check(try unsafe first.value.unsafeInvoke(21) == 42 && second.value.unsafeInvoke(35) == 42,
        "Inout native closures swap their authenticated function and context pairs")
    let replaceAndThrow = try Edit { incoming in
        incoming.value = try Callback { $0 + 1 }
        throw GenericBorrowConversionError.converted
    }
    do {
        try unsafe visit.unsafeInvoke(first, replaceAndThrow)
        throw ArchitectureValidationFailure(description: "Missing closure callback error")
    } catch let error as NativeSwiftError {
        try check(error.withUnderlyingError { $0 is GenericBorrowConversionError },
            "Inout closure callback failures preserve their original error")
    }
    try check(try unsafe first.value.unsafeInvoke(41) == 42 && second.value.unsafeInvoke(35) == 42,
        "Throwing callbacks write back valid closure replacements without changing another slot")

    let state = GenericBorrowState()
    typealias Capture = NativeSwiftClosure<(Callback, Int64) throws -> Int64>
    let capture = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitNestedRuntime<A>(A, ((A) -> A, A) throws -> A) throws -> A",
        as: ((Int64, Capture) throws -> Int64).self, genericArguments: [.type(Int64.self)])
    _ = try unsafe capture.unsafeInvoke(42, Capture { callback, value in state.closure = callback; return value })
    guard let expired = state.closure else { throw ArchitectureValidationFailure(description: "Missing scoped closure") }
    do { _ = try expired.copy(); throw ArchitectureValidationFailure(description: "Scoped closure did not expire") }
    catch NativeSwiftBorrowError.expiredBorrow { checks.append("The writeback failure control uses an expired native closure") }
    let visitPair = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.visitRuntimeClosurePair<A>(inout (A) -> A, inout (A) -> A, (inout (A) -> A, inout (A) -> A) throws -> Swift.Int64) throws -> Swift.Int64",
        as: ((NativeSwiftInout<Callback>, NativeSwiftInout<Callback>, EditPair) throws -> Int64).self,
        genericArguments: [.type(Int64.self)])
    let deaths = GenericBorrowCounter()
    for (index, bodyFails) in [false, true].enumerated() {
        let invalid = try EditPair { first, second in
            let lifetime = GenericBorrowCapture(deaths)
            first.value = try Callback { value in withExtendedLifetime(lifetime) { value + 100 } }
            second.value = expired
            if bodyFails { throw GenericBorrowConversionError.converted }
            return 99
        }
        do {
            _ = try unsafe visitPair.unsafeInvoke(first, second, invalid)
            throw ArchitectureValidationFailure(description: "Invalid closure replacement was accepted")
        } catch let error as NativeSwiftError {
            let preservesErrors = error.withUnderlyingError { underlying in
                let writeback: any Error
                if bodyFails {
                    guard let combined = underlying as? NativeSwiftWritebackError,
                          combined.invocationError is GenericBorrowConversionError else { return false }
                    writeback = combined.writebackError
                } else { writeback = underlying }
                if case ABIResolutionError.unsupportedDeclaration = writeback { return true }
                return false
            }
            try check(preservesErrors, bodyFails
                ? "Failed closure writeback reports both callback and conversion errors"
                : "Failed closure writeback reports its conversion error after a successful callback")
        }
        try check(try unsafe first.value.unsafeInvoke(41) == 42 && second.value.unsafeInvoke(35) == 42
            && deaths.count == index + 1, bodyFails
                ? "A throwing callback with failed writeback preserves both slots and releases the rejected replacement"
                : "Failed writeback preserves both native slots and releases the rejected replacement")
    }
    return checks
}
