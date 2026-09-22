@inline(never) public func answer() -> Int64 { 42 }
@inline(never) public func decorate(_ value: String) -> String { value + "!" }

@frozen public struct Three {
    public var a, b, c: Int64
}
@inline(never) public func transform(_ value: Three) -> Three {
    .init(a: value.a + 1, b: value.b + 2, c: value.c + 3)
}
