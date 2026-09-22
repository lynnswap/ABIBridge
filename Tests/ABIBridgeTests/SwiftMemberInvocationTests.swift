import ABIBridge
import Testing

public class SwiftMemberRenderer {
    public var text: String
    public var object: SwiftMemberRenderer?
    public nonisolated(unsafe) static var count: Int = 0
    public init(text: String) { self.text = text }
    public convenience init(child: SwiftMemberRenderer) {
        self.init(text: child.text)
        self.object = child
    }
    public convenience init?(nonemptyText: String) {
        guard !nonemptyText.isEmpty else { return nil }
        self.init(text: nonemptyText)
    }
    @inline(never) public func render(_ value: Int) -> Int { value + text.count }
    public static var standard: String { "standard" }
    @inline(never) public static func decorate(_ text: String) -> String { text + "!" }
}

public final class SwiftMemberDerived: SwiftMemberRenderer {}

@frozen public struct SwiftMemberPoint: BitwiseCopyable {
    public var value: Int64
    public init(value: Int64) { self.value = value }
    @inline(never) public func read(_ value: Int64) -> Int64 { self.value + value }
    @inline(never) public mutating func change(_ value: Int64) { self.value = value }
    @inline(never) public mutating func changeReturningNil(_ value: Int64) -> UnsafeRawPointer? {
        self.value = value
        return nil
    }
}

@frozen public enum SwiftMemberMode: BitwiseCopyable {
    case first, second
    @inline(never) public func read(_ value: Int) -> Int { self == .first ? value : value + 1 }
}

extension SwiftMemberPoint: ABIBridgeValue {
    public static let abiType = NativeType.int64
    public init(nativeValue: NativeValue) throws { self = try unsafe nativeValue.read(as: Self.self) }
    public static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value, as: abiType) }
}
extension SwiftMemberMode: ABIBridgeValue {
    public static let abiType = NativeType.uint8
    public init(nativeValue: NativeValue) throws { self = try unsafe nativeValue.read(as: Self.self) }
    public static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value, as: abiType) }
}

@frozen public struct SwiftMemberLarge: BitwiseCopyable, ABIBridgeValue {
    public var a, b, c, d, e: Int64
    public init(a: Int64, b: Int64, c: Int64, d: Int64, e: Int64) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e
    }
    public static let abiType = try! NativeType.structure(named: "Large", fields: Array(repeating: .int64, count: 5))
    public init(nativeValue: NativeValue) throws { self = try unsafe nativeValue.read(as: Self.self) }
    public static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value, as: abiType) }
    @inline(never) public func sum(_ extra: Int64) -> Int64 { a + b + c + d + e + extra }
}

private enum SwiftWritebackRejection: Error { case rejected }
private struct RejectingSwiftPoint: ABIBridgeValue {
    static let abiType = NativeType.int64
    let value: Int64
    init(_ value: Int64) { self.value = value }
    init(nativeValue: NativeValue) throws { throw SwiftWritebackRejection.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value.value, as: abiType) }
}

public struct SwiftMemberGeneric<Value> {
    public let value: Value
}

struct SwiftMemberInvocationTests {
    @Test func largeValueReceiversUseIndirectSwiftContext() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ABIBridgeTests.SwiftMemberLarge")
        let sum = try await type.method(named: "sum(_:)", as: ((Int64) -> Int64).self)
        let value = SwiftMemberLarge(a: 1, b: 2, c: 3, d: 4, e: 5)
        #expect(try unsafe sum.unsafeInvoke(on: value, 6) == value.sum(6))
    }

    @Test func resultAndWritebackFailuresRemainAvailable() async throws {
        let type = try await ABIRuntime.shared.swiftType(
            named: "ABIBridgeTests.SwiftMemberPoint", as: RejectingSwiftPoint.self
        )
        let change = try await type.method(
            named: "changeReturningNil(Swift.Int64) -> Swift.Optional<Swift.UnsafeRawPointer>",
            as: ((Int64) -> UnsafeRawPointer).self, mutating: true
        )
        var value = RejectingSwiftPoint(1)
        do {
            _ = try unsafe change.unsafeInvoke(on: &value, 42)
            Issue.record("Expected conversion and writeback failures")
        } catch let error as NativeSwiftWritebackError {
            #expect(error.invocationError is ABIInvocationError)
            #expect(error.writebackError is SwiftWritebackRejection)
        }
    }

    @MainActor @Test func inheritedImplementationsResolveThroughTheirDeclaringClass() async throws {
        let object = SwiftMemberDerived(text: "derived")
        let method = try await ABIRuntime.shared.object(object).method(
            named: "render(_:)", as: ((Int) -> Int).self
        )
        #expect(try unsafe method.unsafeInvoke(5) == object.render(5))
        let type = try await ABIRuntime.shared.swiftType(named: "ABIBridgeTests.SwiftMemberDerived")
        let getter = try await type.getter(named: "text", as: String.self)
        #expect(try unsafe getter.unsafeInvoke(on: object) == object.text)
    }

    @MainActor @Test func propertyAccessorsPreserveIncomingObjectOwnership() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
        let text = try await type.getter(named: "text", as: String.self)
        let setText = try await type.setter(named: "text", as: String.self)
        let object = SwiftMemberRenderer(text: "old")
        let bound = ABIRuntime.shared.object(object)
        let boundGet = try await bound.getter(named: "text", as: String.self)
        let boundSet = try await bound.setter(named: "text", as: String.self)
        try unsafe boundSet.unsafeInvoke("bound")
        #expect(try unsafe boundGet.unsafeInvoke() == "bound")
        try unsafe setText.unsafeInvoke(on: object, String(repeating: "abc", count: 100))
        #expect(try unsafe text.unsafeInvoke(on: object) == String(repeating: "abc", count: 100))
        let setObject = try await type.setter(named: "object", as: SwiftMemberRenderer?.self)
        var child: SwiftMemberRenderer? = .init(text: "child")
        weak let observed = child
        try unsafe setObject.unsafeInvoke(on: object, child)
        child = nil
        #expect(observed != nil && object.object?.text == "child")
        try unsafe setObject.unsafeInvoke(on: object, nil)
        #expect(observed == nil)
        let standard = try await type.staticGetter(named: "standard", as: String.self)
        #expect(try unsafe standard.unsafeInvoke() == SwiftMemberRenderer.standard)
        let count = try await type.staticGetter(named: "count", as: Int.self)
        let setCount = try await type.staticSetter(named: "count", as: Int.self)
        try unsafe setCount.unsafeInvoke(42)
        #expect(try unsafe count.unsafeInvoke() == SwiftMemberRenderer.count)
        SwiftMemberRenderer.count = 0
        let pointType = try await ABIRuntime.shared.swiftType(named: "ABIBridgeTests.SwiftMemberPoint")
        let value = try await pointType.getter(named: "value", as: Int64.self)
        let setValue = try await pointType.setter(named: "value", as: Int64.self)
        var point = SwiftMemberPoint(value: 1)
        try unsafe setValue.unsafeInvoke(on: &point, 7)
        #expect(try unsafe value.unsafeInvoke(on: point) == 7)
    }

    @MainActor @Test func initializersAndStaticMethodsSupplyMetadataAndOwnership() async throws {
        let rendererType = try await ABIRuntime.shared.swiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
        let initialize = try await rendererType.initializer(
            named: "init(text:)", as: ((String) -> SwiftMemberRenderer).self
        )
        var renderer: SwiftMemberRenderer? = try unsafe initialize.unsafeInvoke(String(repeating: "ab", count: 100))
        weak let observed = renderer
        #expect(renderer?.text == String(repeating: "ab", count: 100))
        renderer = nil
        #expect(observed == nil)
        let withChild = try await rendererType.initializer(
            named: "init(child:)", as: ((SwiftMemberRenderer) -> SwiftMemberRenderer).self
        )
        var child: SwiftMemberRenderer? = .init(text: "child")
        weak let childReference = child
        var parent: SwiftMemberRenderer? = try unsafe withChild.unsafeInvoke(child!)
        child = nil
        #expect(parent?.object === childReference && childReference != nil)
        parent = nil
        #expect(childReference == nil)
        let failable = try await rendererType.initializer(
            named: "init(nonemptyText:)", as: ((String) -> SwiftMemberRenderer?).self
        )
        #expect(try unsafe failable.unsafeInvoke("") == nil)
        #expect(try unsafe failable.unsafeInvoke("ok")?.text == "ok")
        let staticMethod = try await rendererType.staticMethod(
            named: "decorate(_:)", as: ((String) -> String).self
        )
        #expect(try unsafe staticMethod.unsafeInvoke("hello") == SwiftMemberRenderer.decorate("hello"))
        let pointType = try await ABIRuntime.shared.swiftType(named: "ABIBridgeTests.SwiftMemberPoint")
        let pointInitializer = try await pointType.initializer(
            named: "init(value:)", as: ((Int64) -> SwiftMemberPoint).self
        )
        #expect(try unsafe pointInitializer.unsafeInvoke(42).value == 42)
    }

    @MainActor @Test func boundSwiftMethodsRetainTheirReceiver() async throws {
        var object: SwiftMemberRenderer? = .init(text: "abc")
        weak let observed = object
        var method: NativeBoundSwiftMethod<Int, Int>? = try await ABIRuntime.shared.object(object!).method(
            named: "render(_:)", as: ((Int) -> Int).self
        )
        object = nil
        #expect(observed != nil)
        #expect(try unsafe method!.unsafeInvoke(5) == 8)
        method = nil
        #expect(observed == nil)
    }

    @MainActor @Test func classMembersUseTheBoundClassContext() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
        let render = try await type.method(named: "render(_:)", as: ((Int) -> Int).self)
        let object = SwiftMemberRenderer(text: "abc")
        #expect(try unsafe render.unsafeInvoke(on: object, 5) == object.render(5))
        #expect(throws: ABIInvocationError.self) { try unsafe render.unsafeInvoke(on: 1, 5) }
    }

    @Test func valueAndEnumMembersUseTheirSwiftReceiverLayouts() async throws {
        let runtime = ABIRuntime()
        let point = try await runtime.swiftType(named: "ABIBridgeTests.SwiftMemberPoint")
        let read = try await point.method(named: "read(_:)", as: ((Int64) -> Int64).self)
        var value = SwiftMemberPoint(value: 10)
        #expect(try unsafe read.unsafeInvoke(on: value, 5) == value.read(5))
        let change = try await point.method(named: "change(_:)", as: ((Int64) -> Void).self, mutating: true)
        #expect(throws: ABIResolutionError.self) { try unsafe change.unsafeInvoke(on: value, 42) }
        try unsafe change.unsafeInvoke(on: &value, 42)
        #expect(value.value == 42)
        let mode = try await runtime.swiftType(named: "ABIBridgeTests.SwiftMemberMode")
        let modeRead = try await mode.method(named: "read(_:)", as: ((Int) -> Int).self)
        #expect(try unsafe modeRead.unsafeInvoke(on: SwiftMemberMode.second, 7) == SwiftMemberMode.second.read(7))
    }

    @Test func valueMutationSurvivesAResultConversionFailure() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ABIBridgeTests.SwiftMemberPoint")
        let change = try await type.method(
            named: "changeReturningNil(Swift.Int64) -> Swift.Optional<Swift.UnsafeRawPointer>",
            as: ((Int64) -> UnsafeRawPointer).self, mutating: true
        )
        var value = SwiftMemberPoint(value: 1)
        #expect(throws: ABIInvocationError.self) { try unsafe change.unsafeInvoke(on: &value, 42) }
        #expect(value.value == 42)
    }

    @Test func nominalMetadataIsCachedAndSurvivesCacheRemoval() async throws {
        let runtime = ABIRuntime()
        let known: [Any.Type] = [SwiftMemberRenderer.self, SwiftMemberPoint.self, SwiftMemberMode.self]
        for expected in known {
            let qualified = String(reflecting: expected)
            let first = try await runtime.swiftType(named: qualified)
            let second = try await runtime.swiftType(named: qualified, in: first.image)
            #expect(first === second)
            #expect(first.name == qualified)
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
