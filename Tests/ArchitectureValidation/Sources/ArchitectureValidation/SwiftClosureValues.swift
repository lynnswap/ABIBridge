import ABIBridge
import CoreGraphics
import SwiftReplacementFixtures
import Synchronization

extension ExplicitVector: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "ExplicitVector", fields: [.pointer, .double, .double])
    }
}
extension ExplicitChoice: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "ExplicitChoice", fields: Array(repeating: .uint, count: MemoryLayout<Int64>.size / MemoryLayout<UInt>.size) + [.uint8])
    }
}
extension ExplicitLarge: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "ExplicitLarge", fields: [.pointer, .int64, .int64, .int64, .int64])
    }
}

private final class ClosureProbeCounter: Sendable {
    let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private final class ClosureProbeCapture: Sendable {
    let counter: ClosureProbeCounter
    let bias: Int64 = 7
    init(_ counter: ClosureProbeCounter) { self.counter = counter }
    deinit { counter.increment() }
}

@MainActor func validateSwiftClosureValues() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let apply = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callClosureValue(_:_:)",
        as: ((NativeSwiftClosure<Int64, Int64>, Int64) -> Int64).self
    )
    let callback = try NativeSwiftClosure { (value: Int64) in value + 7 }
    try check(try unsafe apply.unsafeInvoke(callback, 35) == 42,
              "Compiled native caller invokes the generated concrete closure")
    try check(try unsafe callback.unsafeInvoke(35) == 42,
              "The retained closure invokes its entry with the hidden context")

    let echo = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.echoClosureValue(_:)",
        as: ((NativeSwiftClosure<Int64, Int64>) -> NativeSwiftClosure<Int64, Int64>).self
    )
    var roundTrip = callback
    for _ in 0..<10_000 { roundTrip = try unsafe echo.unsafeInvoke(roundTrip) }
    try check(try unsafe roundTrip.unsafeInvoke(35) == 42,
              "Repeated native handoffs reuse the owning callback entry")

    let retain = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.holdClosureValue(_:)",
        as: ((NativeSwiftClosure<Int64, Int64>) -> ClosureValueHolder).self
    )
    let destroyed = ClosureProbeCounter()
    weak var observed: ClosureProbeCapture?
    var holder: ClosureValueHolder?
    do {
        let capture = ClosureProbeCapture(destroyed)
        observed = capture
        let callback = try NativeSwiftClosure { (value: Int64) in value + capture.bias }
        holder = try unsafe retain.unsafeInvoke(callback)
    }
    try withExtendedLifetime(holder) {
        try check(observed != nil && destroyed.count == 0,
                  "Native escaping storage retains the capture and generated entry")
    }
    try check(holder!(35) == 42, "Saved native closure calls after its Swift wrapper is released")
    holder = nil
    try check(observed == nil && destroyed.count == 1, "Final native closure release destroys captures once")

    let factory = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.makeStringClosureValue(_:)",
        as: ((String) -> NativeSwiftClosure<String, String>).self
    )
    let prefix = String(repeating: "owned prefix ", count: 100)
    let returned = try unsafe factory.unsafeInvoke(prefix)
    try check(try unsafe returned.unsafeInvoke("result") == prefix + "result",
              "Returned Swift capture context preserves String ownership and authentication")

    let applyRect = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callRectClosureValue(_:_:)",
        as: ((NativeSwiftClosure<CGRect, CGRect>, CGRect) -> CGRect).self
    )
    let translate = try NativeSwiftClosure { (value: CGRect) in value.offsetBy(dx: 3, dy: 4) }
    let rectangle = CGRect(x: 1, y: 2, width: 5, height: 6)
    try check(try unsafe applyRect.unsafeInvoke(translate, rectangle) == rectangle.offsetBy(dx: 3, dy: 4),
              "Imported value identity and floating aggregate registers match the native closure")

    let applyPointer = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callPointerClosureValue(_:_:)",
        as: ((NativeSwiftClosure<Int64, UnsafePointer<Int64>?>, UnsafePointer<Int64>?) -> Int64).self
    )
    let read = try NativeSwiftClosure { (value: UnsafePointer<Int64>?) -> Int64 in value?.pointee ?? -1 }
    var number: Int64 = 42
    let result = try withUnsafePointer(to: &number) { try unsafe applyPointer.unsafeInvoke(read, $0) }
    try check(result == 42, "Typed-pointer substitution matches the native closure discriminator")
    try check(try unsafe applyPointer.unsafeInvoke(read, nil) == -1, "Optional pointer preserves its nil representation")

    let applyVoid = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callVoidClosureValue(_:)",
        as: ((NativeSwiftClosure<Void>) -> Void).self
    )
    let calls = ClosureProbeCounter()
    let empty = try NativeSwiftClosure<Void> { calls.increment() }
    try unsafe applyVoid.unsafeInvoke(empty)
    try check(calls.count == 1, "Zero-argument Void closure matches the native signature")
    let applyArray = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callArrayClosureValue(_:_:)",
        as: ((NativeSwiftClosure<[String], [String]>, [String]) -> [String]).self
    )
    let arrayCallback = try NativeSwiftClosure { (value: [String]) in value + ["callback"] }
    try check(try unsafe applyArray.unsafeInvoke(arrayCallback, ["input"]) == ["input", "callback"],
              "Array callback uses the native nominal discriminator and buffer ownership")
    let makeArray = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.makeArrayClosureValue(_:)",
        as: ((String) -> NativeSwiftClosure<[String], [String]>).self
    )
    let returnedArray = try unsafe makeArray.unsafeInvoke(prefix)
    try check(try unsafe returnedArray.unsafeInvoke([]) == [prefix],
              "Returned Array closure retains its capture and transfers its result")
    let optionalArrays = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callOptionalArrayClosureValue(_:_:)",
        as: ((NativeSwiftClosure<[String]?, [String]?>, [String]?) -> [String]?).self
    )
    let optionalArrayCallback = try NativeSwiftClosure { (value: [String]?) in value }
    let absentArray = try unsafe optionalArrays.unsafeInvoke(optionalArrayCallback, nil)
    let emptyArray = try unsafe optionalArrays.unsafeInvoke(optionalArrayCallback, [])
    try check(absentArray == nil && emptyArray == [],
              "Optional Array preserves nil and empty with authenticated callback calls")
    let optionalStrings = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callOptionalStringClosureValue(_:_:)",
        as: ((NativeSwiftClosure<String?, String?>, String?) -> String?).self
    )
    let optionalStringCallback = try NativeSwiftClosure { (value: String?) in value.map { $0 + "!" } }
    let absentString = try unsafe optionalStrings.unsafeInvoke(optionalStringCallback, nil)
    let presentString = try unsafe optionalStrings.unsafeInvoke(optionalStringCallback, prefix)
    try check(absentString == nil && presentString == prefix + "!",
              "Optional String callback preserves its spare-bit payload and ownership")
    let makeOptionalString = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.makeOptionalStringClosureValue(_:)",
        as: ((String) -> NativeSwiftClosure<String?, String?>).self
    )
    let returnedOptional = try unsafe makeOptionalString.unsafeInvoke(prefix)
    let absentResult = try unsafe returnedOptional.unsafeInvoke(nil)
    let presentResult = try unsafe returnedOptional.unsafeInvoke("input")
    try check(absentResult == nil && presentResult == "input" + prefix,
              "Returned Optional String closure matches native pointer authentication")
    let vectorCall = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callExplicitVector(_:_:)",
        as: ((NativeSwiftClosure<ExplicitVector, ExplicitVector>, ExplicitVector) -> ExplicitVector).self
    )
    let vectorBody = try NativeSwiftClosure { (value: ExplicitVector) in
        ExplicitVector(token: value.token, x: value.x + 1, y: value.y + 2)
    }
    let token = ExplicitValueToken(42)
    let vector = try unsafe vectorCall.unsafeInvoke(vectorBody, ExplicitVector(token: token, x: 1, y: 2))
    try check(vector.token === token && vector.x == 2 && vector.y == 4,
              "Explicit managed struct preserves mixed registers, ownership, and authentication")
    let choiceCall = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callExplicitChoice(_:_:)",
        as: ((NativeSwiftClosure<ExplicitChoice, ExplicitChoice>, ExplicitChoice) -> ExplicitChoice).self
    )
    let choiceBody = try NativeSwiftClosure<ExplicitChoice, ExplicitChoice> { $0 }
    let choice = try unsafe choiceCall.unsafeInvoke(choiceBody, .number(-42))
    if case .number(let actual) = choice {
        try check(actual == -42, "Explicit enum preserves its payload and tag in an authenticated callback")
    } else { throw ArchitectureValidationFailure(description: "Explicit enum lost its number tag") }
    let choiceFactory = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.makeExplicitChoice()",
        as: (() -> NativeSwiftClosure<ExplicitChoice, ExplicitChoice>).self
    )
    let returnedChoice = try unsafe choiceFactory.unsafeInvoke()
    weak var observedValue: ExplicitValueToken?
    var heldChoice: ExplicitChoice?
    do {
        let value = ExplicitValueToken(7)
        observedValue = value
        heldChoice = try unsafe returnedChoice.unsafeInvoke(.token(value))
    }
    try withExtendedLifetime(heldChoice) {
        try check(observedValue != nil, "Returned enum closure transfers its reference payload")
    }
    heldChoice = nil
    try check(observedValue == nil, "Explicit enum destruction releases its reference payload")
    let largeCall = try await runtime.swiftFunction(
        named: "SwiftReplacementFixtures.callExplicitLarge(_:_:)",
        as: ((NativeSwiftClosure<ExplicitLarge, ExplicitLarge>, ExplicitLarge) -> ExplicitLarge).self
    )
    let largeBody = try NativeSwiftClosure<ExplicitLarge, ExplicitLarge> { $0 }
    let large = try unsafe largeCall.unsafeInvoke(largeBody, ExplicitLarge(token: token, a: 1, b: 2, c: 3, d: 4))
    try check(large.token === token && large.a == 1 && large.d == 4,
              "Indirect large managed value uses the compiler's closure discriminator")
    return checks
}
