@inline(never) public func answer() -> Int64 { 42 }
@inline(never) public func decorate(_ value: String) -> String { value + "!" }

private final class PrivateRenderer {
    let value: Int
    init(_ value: Int) { self.value = value }
    @inline(never) func score(_ extra: Int) -> Int { value + extra }
}

@inline(never) public func makePrivateRenderer(_ value: Int) -> AnyObject { PrivateRenderer(value) }

private final class GenericRenderer<Value> {
    let value: Value
    let measure: (Value) -> Int
    init(_ value: Value, measure: @escaping (Value) -> Int) { self.value = value; self.measure = measure }
    @inline(never) func score(_ extra: Int) -> Int { measure(value) + extra }
    var currentScore: Int { @inline(never) get { measure(value) } }
}

@inline(never) public func makeGenericRenderer(_ value: Int) -> AnyObject {
    let renderer = GenericRenderer(value, measure: { $0 })
    precondition(renderer.score(0) == renderer.currentScore)
    return renderer
}

public final class GenericExtensionRenderer<Value> {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

@inline(never) public func makeConstrainedRenderer(_ value: Int) -> AnyObject {
    GenericExtensionRenderer(value)
}

@inline(never) public func makeAdder(_ bias: Int64) -> (Int64) -> Int64 { { $0 + bias } }
@inline(never) public func visitOwnedClosure(
    _ closure: @escaping (Int64) -> Int64,
    _ body: (@escaping (Int64) -> Int64) throws -> Int64
) rethrows -> Int64 {
    let result = try body(closure)
    return result + closure(1)
}

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
import Foundation

@inline(never) public func hookEcho<Value>(_ value: Value) -> Value { value }
@inline(never) public func hookThrowing(_ value: Int64) throws(NSError) -> Int64 {
    if value < 0 { throw NSError(domain: "native-hook-consumer", code: Int(value)) }
    return value + 1
}

@inline(never) public nonisolated(nonsending) func hookAsyncEcho<Value>(_ value: Value) async -> Value {
    await Task.yield()
    return value
}
@inline(never) public nonisolated(nonsending) func hookAsyncThrowing(_ value: Int64) async throws(NSError) -> String {
    await Task.yield()
    if value < 0 { throw NSError(domain: "native-async-hook-consumer", code: Int(value)) }
    return String(repeating: "value:\(value)", count: 100)
}
open class AsyncHookRenderer {
    public init() {}
    @inline(never) open nonisolated(nonsending) func render(_ value: String) async -> String {
        await Task.yield()
        return value + "-native"
    }
}
@inline(never) public func makeAsyncHookRenderer() -> AsyncHookRenderer { AsyncHookRenderer() }
