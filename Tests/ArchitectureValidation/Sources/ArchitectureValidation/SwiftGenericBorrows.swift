import ABIBridge
import Foundation
import Synchronization

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

    let type = try await runtime.swiftType(named: "SwiftValueFixtures.BorrowedRuntimeRecord")
    let text = try await type.getter(named: "text", as: (() -> String).self, receiverABI: .opaque(named: type.name))
    let changed = try await type.getter(named: "changed", as: (() -> AnyObject?).self, receiverABI: .opaque(named: type.name))
    let length = try await type.method(named: "length()", as: (() -> Int).self, receiverABI: .opaque(named: type.name))
    let cancel = try await type.method(named: "cancel()", as: (() -> Void).self, receiverABI: .opaque(named: type.name))
    let observe = try await runtime.swiftFunction(
        named: "SwiftValueFixtures.observeGeneric<A>(() -> A, Swift.String, Swift.AnyObject, Swift.UnsafeMutablePointer<Swift.Int32>, (SwiftValueFixtures.BorrowedRuntimeRecord) -> ()) -> A",
        as: ((NativeSwiftClosure<() -> Bool>, String, AnyObject, UnsafeMutablePointer<Int32>, NativeSwiftBorrowingClosure<Void>) -> Bool).self,
        genericArguments: [.type(Bool.self)])
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
        let callback = try NativeSwiftBorrowingClosure(borrowing: type) { value in
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
    return checks
}
