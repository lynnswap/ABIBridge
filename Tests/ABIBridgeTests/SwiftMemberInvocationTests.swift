@testable import ABIBridge
import Testing

public final class SwiftMemberRenderer {
    public var text: String
    public init(text: String) { self.text = text }
    @inline(never) public func render(_ value: Int) -> Int { value + text.count }
    public static var standard: String { "standard" }
}

@frozen public struct SwiftMemberPoint: BitwiseCopyable {
    public var value: Int64
    public init(value: Int64) { self.value = value }
    @inline(never) public func read(_ value: Int64) -> Int64 { self.value + value }
    @inline(never) public mutating func change(_ value: Int64) { self.value = value }
}

@frozen public enum SwiftMemberMode: BitwiseCopyable {
    case first, second
    @inline(never) public func read(_ value: Int) -> Int { self == .first ? value : value + 1 }
}

public struct SwiftMemberGeneric<Value> {
    public let value: Value
}

struct SwiftMemberInvocationTests {
    @Test func nominalMetadataIsCachedAndSurvivesCacheRemoval() async throws {
        let runtime = ABIRuntime()
        let known: [Any.Type] = [SwiftMemberRenderer.self, SwiftMemberPoint.self, SwiftMemberMode.self]
        for expected in known {
            let qualified = String(reflecting: expected)
            let first = try await runtime.swiftType(named: qualified)
            let second = try await runtime.swiftType(named: qualified, in: first.image)
            #expect(first === second)
            #expect(first.name == qualified)
            #expect(await first.metadata == expected)
            await runtime.removeCachedResults()
            let next = try await runtime.swiftType(named: qualified, in: first.image)
            #expect(next !== first && next.image == first.image)
        }
    }

    @Test func genericMetadataIsRejectedBeforeCallingItsAccessor() async throws {
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftType(named: "ABIBridgeTests.SwiftMemberGeneric")
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftType(named: "ABIBridgeTests.MissingSwiftType")
        }
    }
}
