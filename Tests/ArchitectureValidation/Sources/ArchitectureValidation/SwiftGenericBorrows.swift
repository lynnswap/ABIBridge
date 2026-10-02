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
    let text = try await type.borrowedGetter(named: "text", as: String.self)
    let changed = try await type.borrowedGetter(named: "changed", as: AnyObject?.self)
    let length = try await type.borrowedMethod(named: "length()", as: (() -> Int).self)
    let cancel = try await type.borrowedMethod(named: "cancel()", as: (() -> Void).self)
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
    return checks
}
