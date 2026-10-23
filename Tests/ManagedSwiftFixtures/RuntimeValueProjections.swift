public enum RuntimeEmptyCaseMode: Int64 {
    case `default` = 7
    case `static` = 42
}

public enum RuntimeEmptyCaseSingleton { case only }

public enum RuntimeProjectionChoice {
    case empty
    case text(String)
    case tuple((Int64, Int64))
    case values(Int64, Int64)
    case labeled(value: (Int64, String))
    case large(RuntimeProjectionLarge)
    indirect case indirect(RuntimeProjectionChoice)
    case repeated(number: Int64)
    case repeated(text: String)
}

public struct RuntimeProjectionLarge {
    public let token: ErrorLifetimeToken
    public let text: String
    public let first, second, third, fourth: Int64
    public init(_ token: ErrorLifetimeToken) {
        self.token = token
        text = String(repeating: "owned payload ", count: 80)
        first = 10; second = 20; third = 30; fourth = 40
    }
}

@inline(never) public func makeRuntimeProjectionChoice(
    _ kind: Int64,
    _ token: ErrorLifetimeToken
) -> some Any {
    switch kind {
    case 0: RuntimeProjectionChoice.empty
    case 1: RuntimeProjectionChoice.text("payload")
    case 2: RuntimeProjectionChoice.tuple((40, 2))
    case 3: RuntimeProjectionChoice.values(40, 2)
    case 4: RuntimeProjectionChoice.labeled(value: (42, "nested"))
    case 5: RuntimeProjectionChoice.large(RuntimeProjectionLarge(token))
    case 6: RuntimeProjectionChoice.indirect(.large(RuntimeProjectionLarge(token)))
    case 7: RuntimeProjectionChoice.repeated(number: 42)
    default: RuntimeProjectionChoice.repeated(text: "overloaded")
    }
}

public enum RuntimeProjectionGeneric<Value> { case value(Value) }
@inline(never) public func makeRuntimeProjectionGeneric<Value>(_ value: Value) -> some Any {
    RuntimeProjectionGeneric.value(value)
}

public protocol RuntimeProjectionClassFailure: Error, AnyObject {}
extension ReferenceFailure: RuntimeProjectionClassFailure {}
@inline(never) public func echoRuntimeProjectionClassFailure(
    _ value: any RuntimeProjectionClassFailure
) -> any RuntimeProjectionClassFailure {
    value
}

public enum RuntimeProjectionUnsupportedErrorPayload {
    case direct(any Error & AnyObject)
    case tuple((Int64, any Error & AnyObject))
    case optional((any Error & AnyObject)?)
    case closure(() -> any Error & AnyObject)
}
@inline(never) public func makeRuntimeProjectionUnsupportedErrorPayload(
    _ kind: Int64,
    _ token: ErrorLifetimeToken
) -> some Any {
    let failure: any Error & AnyObject = ReferenceFailure(token, 42)
    return switch kind {
    case 0: RuntimeProjectionUnsupportedErrorPayload.direct(failure)
    case 1: RuntimeProjectionUnsupportedErrorPayload.tuple((7, failure))
    case 3: RuntimeProjectionUnsupportedErrorPayload.closure({ failure })
    default: RuntimeProjectionUnsupportedErrorPayload.optional(failure)
    }
}

public enum RuntimeProjectionMoveOnly: ~Copyable {
    case empty
    case number(Int64)
    case nothing(Void)
    case ticket(RuntimeTicket)
}

public struct RuntimeProjectionUnit: GenericAssociatedBase { public typealias Item = Void }
public enum RuntimeProjectionAssociated<Source: GenericAssociatedBase>: ~Copyable {
    case value(Source.Item)
    case ticket(RuntimeTicket)
}
@inline(never) public func makeRuntimeProjectionUnit() -> some Any { () }
@inline(never) public func makeRuntimeProjectionMoveOnly(
    _ token: ErrorLifetimeToken
) -> some ~Copyable {
    RuntimeProjectionMoveOnly.ticket(RuntimeTicket(token: token, number: 42))
}

public struct RuntimeProjectionBody {
    public let token: ErrorLifetimeToken
    public let number: Int64
    public init(_ token: ErrorLifetimeToken, _ number: Int64) {
        self.token = token; self.number = number
    }
}

public enum RuntimeProjectionPreview {
    case singlePreview(makeBody: @MainActor () -> RuntimeProjectionBody)
}
public protocol RuntimeProjectionSource { var body: RuntimeProjectionPreview { get } }
public struct RuntimeProjectionConcreteSource: RuntimeProjectionSource {
    public let body: RuntimeProjectionPreview
    public init(_ body: RuntimeProjectionPreview) { self.body = body }
}
public enum RuntimeProjectionRoot { case preview(source: any RuntimeProjectionSource) }
@inline(never) public func makeRuntimeProjectionRoot(_ token: ErrorLifetimeToken) -> some Any {
    let makeBody: @MainActor () -> RuntimeProjectionBody = {
        MainActor.assertIsolated()
        return RuntimeProjectionBody(token, 42)
    }
    return RuntimeProjectionRoot.preview(
        source: RuntimeProjectionConcreteSource(.singlePreview(makeBody: makeBody))
    )
}

public enum RuntimeProjectionGenericPreview<Body> {
    case singlePreview(makeBody: @MainActor () -> Body)
}
@inline(never) public func makeRuntimeProjectionGenericPreview(
    _ token: ErrorLifetimeToken
) -> some Any {
    let makeBody: @MainActor () -> RuntimeProjectionBody = {
        MainActor.assertIsolated()
        return RuntimeProjectionBody(token, 42)
    }
    return RuntimeProjectionGenericPreview.singlePreview(makeBody: makeBody)
}

@inline(never) public func makeRuntimeProjectionAsyncClosure(
    _ token: ErrorLifetimeToken
) -> some Any {
    let body: @MainActor (Bool) async throws(ScalarFailure) -> RuntimeProjectionBody = {
        fail async throws(ScalarFailure) in
        await Task.yield()
        MainActor.assertIsolated()
        if fail { throw ScalarFailure(42) }
        return RuntimeProjectionBody(token, 42)
    }
    return body
}

@inline(never) public func makeRuntimeProjectionPlainClosure(_ bias: Int64) -> some Any {
    let body: (Int64) -> Int64 = { $0 + bias }
    return body
}

public enum RuntimeProjectionOptionalHandler {
    case handler(((Int64) -> Int64)?)
    case labeled(bias: Int64, body: ((Int64) -> Int64)?)
}
@inline(never) public func makeRuntimeProjectionOptionalHandler(
    _ bias: Int64?,
    labeled: Bool
) -> some Any {
    let body = bias.map { bias in { (value: Int64) in value + bias } }
    return labeled
        ? RuntimeProjectionOptionalHandler.labeled(bias: bias ?? 0, body: body)
        : RuntimeProjectionOptionalHandler.handler(body)
}

public typealias RuntimeProjectionPreparationSignature =
    (
        Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64,
        Int64, Int64, Int64, Int64, Int64, Int64, Int64
    ) -> Int64
public enum RuntimeProjectionPreparationContainer {
    case body(RuntimeProjectionPreparationSignature)
}

private func runtimeProjectionPreparationBody(
    _ bias: Int64
) -> RuntimeProjectionPreparationSignature {
    { a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q in
        a + b + c + d + e + f + g + h + i + j + k + l + m + n + o + p + q + bias
    }
}

@inline(never) public func makeRuntimeProjectionPreparationClosure(_ bias: Int64) -> some Any {
    RuntimeProjectionPreparationContainer.body(runtimeProjectionPreparationBody(bias))
}

@inline(never) public func makeRuntimeProjectionGenericPreparationClosure(_ bias: Int64) -> some Any
{
    RuntimeProjectionGeneric.value(runtimeProjectionPreparationBody(bias))
}

@inline(never) public func applyRuntimeProjectionPreparationClosure(
    _ body: @escaping RuntimeProjectionPreparationSignature
) -> Int64 {
    body(
        Int64(35),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0)
    )
}

@inline(never) public func makeRuntimeProjectionAsyncPlainClosure(_ bias: Int64) -> some Any {
    let body: nonisolated(nonsending) (Int64) async -> Int64 = { value in
        await Task.yield()
        return value + bias
    }
    return body
}

@inline(never) public func makeRuntimeProjectionOptional(_ present: Bool) -> some Any {
    present ? Optional.some(Int64(42)) : nil
}
