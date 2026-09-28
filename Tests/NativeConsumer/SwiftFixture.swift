@inline(never) public func answer() -> Int64 { 42 }
@inline(never) public func decorate(_ value: String) -> String { value + "!" }

@inline(never) public func makeAdder(_ bias: Int64) -> (Int64) -> Int64 { { $0 + bias } }
@inline(never) public func applyClosure(_ callback: (Int64) -> Int64, _ value: Int64) -> Int64 {
    callback(value)
}

@inline(never) public func applyArray(_ callback: ([String]) -> [String], _ value: [String]) -> [String] {
    callback(value)
}
@inline(never) public func makeOptionalString(_ suffix: String) -> (String?) -> String? {
    { $0.map { $0 + suffix } }
}

@frozen public struct Three {
    public var a, b, c: Int64
}
@inline(never) public func transform(_ value: Three) -> Three {
    .init(a: value.a + 1, b: value.b + 2, c: value.c + 3)
}

public final class Renderer {
    public var text: String
    public init(text: String) { self.text = text }
    @inline(never) public func score(_ value: Int) -> Int { text.count + value }
    public static var standard: String { "standard" }
}

@frozen public struct Point {
    public var x, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    @inline(never) public func sum(_ extra: Double) -> Double { x + y + extra }
}
