import Synchronization

public final class ArgumentCounts: Sendable {
    private let state = Mutex(0)
    public init() {}
    public var destructions: Int { state.withLock { $0 } }
    public func destroyed() { state.withLock { $0 += 1 } }
}
@inline(never) public func mutateArguments(_ text: inout String, _ values: inout [String], _ count: inout Int64, _ fail: Bool) throws(SmallError) {
    text += String(repeating: "!", count: 64)
    values.append(text)
    count += 1
    if fail { throw SmallError(count) }
}
@inline(never) public func consumeArgument(_ value: consuming LargeError, _ borrowed: borrowing String, _ fail: Bool) throws(SmallError) -> String {
    if fail { throw SmallError(value.d) }
    return borrowed + String(value.d)
}
@inline(never) @concurrent public func asyncArguments(_ gate: AsyncValueGate, _ text: inout String, _ owned: consuming String, _ borrowed: borrowing String) async throws(SmallError) -> String {
    await gate.wait()
    text += owned
    if Task.isCancelled { throw SmallError(-1) }
    return text + borrowed
}
public final class ArgumentOwner: Sendable {
    public let first: String
    public let second: String
    public let token: ErrorToken
    public init(_ first: borrowing String, _ second: consuming String, _ token: borrowing ErrorToken) {
        self.first = copy first; self.second = second; self.token = copy token
    }
    @concurrent public init(_ first: borrowing String, _ second: consuming String, _ token: borrowing ErrorToken, _ gate: AsyncValueGate, _ fail: Bool) async throws(SmallError) {
        await gate.wait()
        if fail { throw SmallError(42) }
        self.first = copy first; self.second = second; self.token = copy token
    }
}
