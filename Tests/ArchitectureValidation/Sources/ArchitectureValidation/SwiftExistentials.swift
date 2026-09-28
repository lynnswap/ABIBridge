import ABIBridge
import SwiftValueFixtures

@MainActor func validateSwiftExistentials() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let echo = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoAny(_:)", as: ((Any) -> Any).self)
    try check(try unsafe echo.unsafeInvoke(Int64(42)) as? Int64 == 42, "Any passes an inline payload indirectly")
    let counts = ArgumentCounts()
    weak var observed: ErrorToken?
    var saved: Any?
    do {
        let token = ErrorToken { counts.destroyed() }
        observed = token
        saved = try unsafe echo.unsafeInvoke(BoxedExistentialValue(token, 42))
    }
    try check(observed != nil && (saved as? BoxedExistentialValue)?.number == 42, "Any owns an out-of-line reference-bearing payload")
    var copy = saved
    saved = nil
    try check(observed != nil && (copy as? BoxedExistentialValue)?.number == 42, "Copying an existential retains its payload")
    copy = nil
    try check(observed == nil && counts.destructions == 1, "Final existential destruction releases the payload exactly once")

    let composed = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoComposition(_:)",
        as: ((any ExistentialValue & ExistentialLabel) -> any ExistentialValue & ExistentialLabel).self)
    let value = try unsafe composed.unsafeInvoke(InlineExistentialValue(42))
    try check(value.number == 42 && value.label == "inline:42", "Protocol composition preserves both witness tables")

    let object = ExistentialObject(ErrorToken(), 42)
    let direct = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoClassExistential(_:)",
        as: ((any ExistentialObjectValue) -> any ExistentialObjectValue).self)
    let large = try await runtime.swiftFunction(named: "SwiftValueFixtures.echoManyClassExistential(_:)",
        as: ((ManyObjectProtocols) -> ManyObjectProtocols).self)
    try check(try unsafe direct.unsafeInvoke(object) === object, "Class-constrained existential passes object and witness pointers")
    try check(try unsafe large.unsafeInvoke(object) === object, "Large class composition uses physical indirect storage")

    typealias OpaqueCallback = NativeSwiftClosure<any ExistentialValue, any ExistentialValue>
    let apply = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyExistentialClosure(_:_:)",
        as: ((OpaqueCallback, any ExistentialValue) -> any ExistentialValue).self)
    let generated = try OpaqueCallback { InlineExistentialValue($0.number + 1) }
    try check(try unsafe apply.unsafeInvoke(generated, BoxedExistentialValue(ErrorToken(), 41)).number == 42, "Opaque existential callback authenticates its formally indirect signature")
    let factory = try await runtime.swiftFunction(named: "SwiftValueFixtures.makeExistentialClosure(_:)",
        as: ((any ExistentialValue) -> OpaqueCallback).self)
    let returned = try unsafe factory.unsafeInvoke(BoxedExistentialValue(ErrorToken(), 42))
    try check(try unsafe returned.unsafeInvoke(InlineExistentialValue(0)).number == 42, "Returned existential closure keeps its capture and authenticates its entry")

    typealias ClassCallback = NativeSwiftClosure<ManyObjectProtocols, ManyObjectProtocols>
    let classApply = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyManyClassExistentialClosure(_:_:)",
        as: ((ClassCallback, ManyObjectProtocols) -> ManyObjectProtocols).self)
    try check(try unsafe classApply.unsafeInvoke(.init { $0 }, object) === object, "Class composition authentication stays class-based despite physical indirection")

    typealias OptionalClass = NativeSwiftClosure<(any ExistentialObjectValue)?, (any ExistentialObjectValue)?>
    let optional = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyOptionalClassClosure(_:_:)",
        as: ((OptionalClass, (any ExistentialObjectValue)?) -> (any ExistentialObjectValue)?).self)
    try check(try unsafe optional.unsafeInvoke(.init { $0 }, object) === object, "Optional class existential callback uses its optional authentication identity")
    try check(try unsafe optional.unsafeInvoke(.init { $0 }, nil) == nil, "Optional class existential preserves nil")

    typealias ErrorCallback = NativeSwiftClosure<(any Error)?, (any Error)?>
    let failure = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyOptionalErrorClosure(_:_:)",
        as: ((ErrorCallback, (any Error)?) -> (any Error)?).self)
    let error = try unsafe failure.unsafeInvoke(.init { $0 }, SmallError(42))
    try check((error as? SmallError)?.code == 42, "Optional error existential preserves its boxed representation and authentication")

    typealias AsyncCallback = NativeSwiftConcurrentClosure<any ExistentialValue, Never, any ExistentialValue>
    let asyncApply = try await runtime.swiftFunction(named: "SwiftValueFixtures.applyAsyncExistentialClosure(_:_:)",
        as: (@concurrent (AsyncCallback, any ExistentialValue) async -> any ExistentialValue).self)
    let body: @Sendable (any ExistentialValue) async -> any ExistentialValue = { value in
        await Task.yield()
        return InlineExistentialValue(value.number + 1)
    }
    try check(try unsafe await asyncApply.unsafeInvoke(AsyncCallback(body), InlineExistentialValue(41)).number == 42, "Async callback returns an owned existential after suspension")
    return checks
}
