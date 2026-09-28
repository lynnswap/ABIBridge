import Synchronization

@inline(never) @concurrent public func asyncSeven(_ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ e: Int64, _ f: Int64, _ g: Int64) async -> Int64 {
    await Task.yield()
    return a + b + c + d + e + f + g
}
@inline(never) @concurrent public func asyncNine(_ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ e: Int64, _ f: Int64, _ g: Int64, _ h: Int64, _ i: Int64) async -> Int64 {
    await Task.yield()
    return a + b + c + d + e + f + g + h + i
}
@inline(never) @concurrent public func applySeven(_ body: @concurrent @Sendable (Int64, Int64, Int64, Int64, Int64, Int64, Int64) async -> Int64) async -> Int64 {
    await body(1, 2, 3, 4, 5, 6, 7)
}
@inline(never) @concurrent public func applyNine(_ body: @concurrent @Sendable (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64) async -> Int64) async -> Int64 {
    await body(1, 2, 3, 4, 5, 6, 7, 8, 9)
}

public final class ArgumentCounts: Sendable {
    private let state = Mutex((entries: 0, destructions: 0))
    public init() {}
    public var entries: Int { state.withLock { $0.entries } }
    public var destructions: Int { state.withLock { $0.destructions } }
    public func entered() { state.withLock { $0.entries += 1 } }
    public func destroyed() { state.withLock { $0.destructions += 1 } }
}
public final class ArgumentToken: Sendable {
    public let counts: ArgumentCounts
    public init(_ counts: ArgumentCounts) { self.counts = counts }
    deinit { counts.destroyed() }
}

@inline(never) public func mutateArguments(_ text: inout String, _ values: inout [String], _ count: inout Int64, _ fail: Bool) throws(ScalarFailure) {
    text += String(repeating: "!", count: 64)
    values.append(text)
    count += 1
    if fail { throw ScalarFailure(count) }
}
@inline(never) public func consumeArguments(_ owned: consuming String, _ borrowed: borrowing String, _ token: consuming ArgumentToken, _ fail: Bool) throws(ScalarFailure) -> String {
    token.counts.entered()
    if fail { throw ScalarFailure(42) }
    return owned + borrowed
}
@inline(never) public func consumeBeforeConversionFailure(_ token: consuming ArgumentToken, _ value: Int64) -> Int64 {
    token.counts.entered()
    return value
}
@inline(never) @concurrent public func asyncArguments(_ gate: AsyncGate, _ text: inout String, _ owned: consuming String, _ borrowed: borrowing String, _ fail: Bool) async throws(ScalarFailure) -> String {
    await gate.wait()
    text += owned
    if fail || Task.isCancelled { throw ScalarFailure(Task.isCancelled ? -1 : 42) }
    return text + borrowed
}

@inline(never) public func consumeLargeArgument(_ value: consuming ErrorSuccessPayload, _ counts: ArgumentCounts, _ fail: Bool) throws(ScalarFailure) -> Int64 {
    counts.entered()
    if fail { throw ScalarFailure(42) }
    return value.d
}
@inline(never) public func mutateBeforeConversionFailure(_ text: inout String, _ value: Int64) {
    text = "entered"
}

public final class ArgumentOwner: Sendable {
    public let first: String
    public let second: String
    public let token: ArgumentToken
    public init(_ first: borrowing String, _ second: consuming String, _ token: borrowing ArgumentToken) {
        self.first = copy first; self.second = second; self.token = copy token
    }
    @concurrent public init(_ first: borrowing String, _ second: consuming String, _ token: borrowing ArgumentToken, _ gate: AsyncGate, _ fail: Bool) async throws(ScalarFailure) {
        await gate.wait()
        if fail { throw ScalarFailure(42) }
        self.first = copy first; self.second = second; self.token = copy token
    }
}
@frozen public struct ArgumentCounter: Sendable {
    public var count: Int64
    public init(_ count: Int64) { self.count = count }
    public mutating func update(_ text: inout String, _ suffix: consuming String, _ fail: Bool) throws(ScalarFailure) {
        count += 1; text += suffix
        if fail { throw ScalarFailure(count) }
    }
}
