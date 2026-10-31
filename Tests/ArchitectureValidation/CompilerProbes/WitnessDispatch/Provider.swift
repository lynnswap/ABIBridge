public protocol Probe: Sendable {
    associatedtype Output
    init(seed: Int64)
    func sync(_ value: Int64) -> Int64
    var value: Int64 { get set }
    static func code(_ value: Int64) -> Int64
    func asynchronous(_ value: Int64) async -> Int64
    func echo(_ value: Output) -> Output
}

public struct Plain: Probe {
    public typealias Output = Int64
    public var value: Int64
    public init(seed: Int64) { value = seed }
    @inline(never) public func sync(_ input: Int64) -> Int64 { value + input }
    @inline(never) public static func code(_ input: Int64) -> Int64 { input + 10 }
    @inline(never) public func asynchronous(_ input: Int64) async -> Int64 { value + input + 20 }
    @inline(never) public func echo(_ input: Int64) -> Int64 { input }
}

public struct Box<Element>: Probe {
    public typealias Output = Element
    public var value: Int64
    public init(seed: Int64) { value = seed }
    @inline(never) public func sync(_ input: Int64) -> Int64 { value + input }
    @inline(never) public static func code(_ input: Int64) -> Int64 { input + 30 }
    @inline(never) public func asynchronous(_ input: Int64) async -> Int64 { value + input + 40 }
    @inline(never) public func echo(_ input: Element) -> Element { input }
}

public struct Conditional<Element>: Sendable {
    public var value: Int64
    public init(seed: Int64) { value = seed }
}
extension Conditional: Probe where Element: Equatable {
    public typealias Output = Element
    @inline(never) public func sync(_ input: Int64) -> Int64 { value + input }
    @inline(never) public static func code(_ input: Int64) -> Int64 { input + 50 }
    @inline(never) public func asynchronous(_ input: Int64) async -> Int64 { value + input + 60 }
    @inline(never) public func echo(_ input: Element) -> Element { input }
}

public final class DelegateToken {
    public init() {}
}

public protocol Delegate: AnyObject {
    func receive(_ text: String, token: DelegateToken, value: Int64)
    func consume(_ text: consuming String, token: consuming DelegateToken)
    func accept(_ other: Self)
    func fail(_ text: String) throws
    func typedFail(_ text: String) throws(DelegateFailure)
    consuming func finish(_ fail: Bool) throws
}

public enum DelegateFailure: Error { case expected, code(Int64) }

public final class DelegateObject: Delegate {
    public init() {}
    @inline(never) public func receive(_ text: String, token: DelegateToken, value: Int64) {}
    @inline(never) public func consume(_ text: consuming String, token: consuming DelegateToken) {}
    @inline(never) public func accept(_ other: DelegateObject) {}
    @inline(never) public func fail(_ text: String) throws { throw DelegateFailure.expected }
    @inline(never) public consuming func finish(_ fail: Bool) throws {
        if fail { throw DelegateFailure.expected }
    }
    @inline(never) public func typedFail(_ text: String) throws(DelegateFailure) {
        throw DelegateFailure.code(1)
    }
}
