import ABIBridge
import CoreGraphics
import Foundation
import Testing

@inline(never) public func swiftABIVoid(_ value: Void) -> Int32 { 42 }
@inline(never) public func swiftABIStore(_ pointer: UnsafeMutablePointer<Int32>) { pointer.pointee = 42 }
@inline(never) public func swiftABIAnswer() -> Int32 { 42 }
@inline(never) public func swiftABINegative(_ value: Int8) -> Int8 { value - 1 }
@inline(never) public func swiftABINegate(_ value: Bool) -> Bool { !value }
@inline(never) public func swiftABIString(_ value: String) -> String { value + "!" }
@inline(never) public func swiftABIImportedObject(_ value: NSString) -> NSString { value }
@inline(never) public func swiftABIOptionalImportedObject(_ value: NSString?) -> NSString? { value }
@inline(never) public func swiftABIRect(_ value: CGRect) -> CGRect {
    CGRect(x: value.minX + 1, y: value.minY + 2, width: value.width + 3, height: value.height + 4)
}
@inline(never) public func swiftABIMany(_ a0: Int32, _ a1: Int32, _ a2: Int32, _ a3: Int32, _ a4: Int32, _ a5: Int32, _ a6: Int32, _ a7: Int32, _ a8: Int8, _ a9: Int16, _ a10: Float, _ a11: Float, _ a12: Float, _ a13: Float, _ a14: Float, _ a15: Float, _ a16: Float, _ a17: Float, _ a18: Float, _ a19: Double) -> Double {
    var result = 0.0
    result += Double(a0)
    result += Double(a1)
    result += Double(a2)
    result += Double(a3)
    result += Double(a4)
    result += Double(a5)
    result += Double(a6)
    result += Double(a7)
    result += Double(a8)
    result += Double(a9)
    result += Double(a10)
    result += Double(a11)
    result += Double(a12)
    result += Double(a13)
    result += Double(a14)
    result += Double(a15)
    result += Double(a16)
    result += Double(a17)
    result += Double(a18)
    result += Double(a19)
    return result
}

public final class SwiftABIObject {
    let value: Int
    init(_ value: Int) { self.value = value }
}
@inline(never) public func swiftABIObject(_ value: SwiftABIObject?) -> SwiftABIObject? { value }
@inline(never) public func swiftABICreateObject(_ value: Int) -> SwiftABIObject { .init(value) }

@frozen public struct SwiftABIFour: BitwiseCopyable {
    public var a, b, c, d: Int64
}
@frozen public struct SwiftABIFive: BitwiseCopyable {
    public var a, b, c, d, e: Int64
}
@frozen public struct SwiftABISmall: BitwiseCopyable {
    public var a: Int8
    public var b: Int16
    public var c: Int32
    public var d: Double
}
@inline(never) public func swiftABIFour(_ value: SwiftABIFour) -> SwiftABIFour {
    .init(a: value.a + 1, b: value.b + 2, c: value.c + 3, d: value.d + 4)
}
@inline(never) public func swiftABIFive(_ value: SwiftABIFive) -> SwiftABIFive {
    .init(a: value.a + 1, b: value.b + 2, c: value.c + 3, d: value.d + 4, e: value.e + 5)
}
@inline(never) public func swiftABISmall(_ value: SwiftABISmall) -> SwiftABISmall {
    .init(a: value.a - 1, b: value.b + 2, c: value.c + 3, d: value.d + 4)
}

extension SwiftABIFour: ABIBridgeValue {
    public static let abiType = try! NativeType.structure(named: "Four", fields: Array(repeating: .int64, count: 4))
    public init(nativeValue: NativeValue) throws { self = try unsafe nativeValue.read(as: Self.self) }
    public static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value, as: abiType) }
}
extension SwiftABIFive: ABIBridgeValue {
    public static let abiType = try! NativeType.structure(named: "Five", fields: Array(repeating: .int64, count: 5))
    public init(nativeValue: NativeValue) throws { self = try unsafe nativeValue.read(as: Self.self) }
    public static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value, as: abiType) }
}
extension SwiftABISmall: ABIBridgeValue {
    public static let abiType = try! NativeType.structure(named: "Small", fields: [.int8, .int16, .int32, .double])
    public init(nativeValue: NativeValue) throws { self = try unsafe nativeValue.read(as: Self.self) }
    public static func nativeValue(from value: Self) throws -> NativeValue { try .init(copying: value, as: abiType) }
}

private final class ForeignSwiftFour: ABIBridgeValue {
    static let abiType = SwiftABIFour.abiType
    let storage: NativeValue
    init(nativeValue: NativeValue) { storage = nativeValue }
    static func nativeValue(from value: ForeignSwiftFour) -> NativeValue { value.storage }
}

struct SwiftFunctionInvocationTests {
    @MainActor @Test func labelOnlyNamesUseCanonicalImportedClassNames() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ABIBridgeTests.swiftABIImportedObject(_:)", as: ((NSString) -> NSString).self
        )
        let value = NSString(string: "value")
        #expect(try unsafe function.unsafeInvoke(value) === swiftABIImportedObject(value))
        let optional = try await ABIRuntime.shared.swiftFunction(
            named: "ABIBridgeTests.swiftABIOptionalImportedObject(_:)", as: ((NSString?) -> NSString?).self
        )
        #expect(try unsafe optional.unsafeInvoke(value) === swiftABIOptionalImportedObject(value))
        #expect(try unsafe optional.unsafeInvoke(nil) == nil)
    }

    @Test func voidValuesPointersAndReusableImageScopes() async throws {
        typealias EmptyArgument = ()
        let runtime = ABIRuntime()
        let symbol = try await runtime.resolve(.init(
            name: "ABIBridgeTests.swiftABIAnswer() -> Swift.Int32", language: .swift
        ))
        let empty = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABIVoid(_:)", as: ((EmptyArgument) -> Int32).self, in: symbol.image
        )
        #expect(try unsafe empty.unsafeInvoke(()) == swiftABIVoid(()))
        let store = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABIStore(_:)",
            as: ((UnsafeMutablePointer<Int32>) -> Void).self, in: .path(URL(fileURLWithPath: symbol.image.path))
        )
        var value: Int32 = 0
        try withUnsafeMutablePointer(to: &value) { try unsafe store.unsafeInvoke($0) }
        #expect(value == 42)
    }

    @Test func foreignClassWrappersUseTheirDeclaredValueLayout() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ABIBridgeTests.swiftABIFour(ABIBridgeTests.SwiftABIFour) -> ABIBridgeTests.SwiftABIFour",
            as: ((ForeignSwiftFour) -> ForeignSwiftFour).self
        )
        let input = ForeignSwiftFour(nativeValue: try .init(
            copying: SwiftABIFour(a: 1, b: 2, c: 3, d: 4), as: SwiftABIFour.abiType
        ))
        let output = try unsafe function.unsafeInvoke(input)
        let value = try unsafe output.storage.read(as: SwiftABIFour.self)
        #expect([value.a, value.b, value.c, value.d] == [2, 4, 6, 8])
    }

    @Test func immutableInterfaceCanBeUsedConcurrently() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ABIBridgeTests.swiftABIString(_:)", as: ((String) -> String).self
        )
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<16 {
                group.addTask { try unsafe function.unsafeInvoke(String(index)) }
            }
            var results: Set<String> = []
            for try await result in group { results.insert(result) }
            #expect(results == Set((0..<16).map { "\($0)!" }))
        }
    }

    @Test func scalarResultsAndArguments() async throws {
        let runtime = ABIRuntime()
        let answer = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABIAnswer() -> Swift.Int32", as: (() -> Int32).self
        )
        #expect(try unsafe answer.unsafeInvoke() == swiftABIAnswer())
        let negative = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABINegative(Swift.Int8) -> Swift.Int8", as: ((Int8) -> Int8).self
        )
        #expect(try unsafe negative.unsafeInvoke(-12) == swiftABINegative(-12))
        let negate = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABINegate(Swift.Bool) -> Swift.Bool", as: ((Bool) -> Bool).self
        )
        #expect(try unsafe negate.unsafeInvoke(false) == swiftABINegate(false))
        #expect(try unsafe negate.unsafeInvoke(true) == swiftABINegate(true))
    }

    @Test func manyIntegerAndFloatingArgumentsSpillIndependently() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ABIBridgeTests.swiftABIMany(Swift.Int32, Swift.Int32, Swift.Int32, Swift.Int32, Swift.Int32, Swift.Int32, Swift.Int32, Swift.Int32, Swift.Int8, Swift.Int16, Swift.Float, Swift.Float, Swift.Float, Swift.Float, Swift.Float, Swift.Float, Swift.Float, Swift.Float, Swift.Float, Swift.Double) -> Swift.Double",
            as: ((Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int8, Int16, Float, Float, Float, Float, Float, Float, Float, Float, Float, Double) -> Double).self
        )
        #expect(try unsafe function.unsafeInvoke(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20) == swiftABIMany(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20))
    }

    @Test func stringOwnershipAndFourFloatingResultRegisters() async throws {
        let runtime = ABIRuntime()
        let append = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABIString(Swift.String) -> Swift.String", as: ((String) -> String).self
        )
        for length in [0, 4, 80, 1024] {
            let value = String(repeating: "ab", count: length)
            #expect(try unsafe append.unsafeInvoke(value) == swiftABIString(value))
        }
        let rect = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABIRect(__C.CGRect) -> __C.CGRect", as: ((CGRect) -> CGRect).self
        )
        let value = CGRect(x: 1, y: 2, width: 3, height: 4)
        #expect(try unsafe rect.unsafeInvoke(value) == swiftABIRect(value))
    }

    @MainActor @Test func objectArgumentsAreBorrowedAndResultsAreOwned() async throws {
        let runtime = ABIRuntime()
        let echo = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABIObject(_:)",
            as: ((SwiftABIObject?) -> SwiftABIObject?).self
        )
        var object: SwiftABIObject? = .init(42)
        weak let observed = object
        var returned = try unsafe echo.unsafeInvoke(object)
        #expect(returned === swiftABIObject(object))
        object = nil
        #expect(observed != nil && returned?.value == 42)
        returned = nil
        #expect(observed == nil)
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)
        let create = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABICreateObject(Swift.Int) -> ABIBridgeTests.SwiftABIObject",
            as: ((Int) -> SwiftABIObject).self
        )
        var created: SwiftABIObject? = try unsafe create.unsafeInvoke(7)
        weak let createdReference = created
        #expect(created?.value == swiftABICreateObject(7).value)
        created = nil
        #expect(createdReference == nil)
    }

    @Test func directAndIndirectAggregateResultsAndIntegerCoalescing() async throws {
        let runtime = ABIRuntime()
        let four = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABIFour(ABIBridgeTests.SwiftABIFour) -> ABIBridgeTests.SwiftABIFour",
            as: ((SwiftABIFour) -> SwiftABIFour).self
        )
        let a = try unsafe four.unsafeInvoke(.init(a: 1, b: 2, c: 3, d: 4))
        let expectedA = swiftABIFour(.init(a: 1, b: 2, c: 3, d: 4))
        #expect([a.a, a.b, a.c, a.d] == [expectedA.a, expectedA.b, expectedA.c, expectedA.d])
        let five = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABIFive(ABIBridgeTests.SwiftABIFive) -> ABIBridgeTests.SwiftABIFive",
            as: ((SwiftABIFive) -> SwiftABIFive).self
        )
        let b = try unsafe five.unsafeInvoke(.init(a: 1, b: 2, c: 3, d: 4, e: 5))
        let expectedB = swiftABIFive(.init(a: 1, b: 2, c: 3, d: 4, e: 5))
        #expect([b.a, b.b, b.c, b.d, b.e] == [expectedB.a, expectedB.b, expectedB.c, expectedB.d, expectedB.e])
        let small = try await runtime.swiftFunction(
            named: "ABIBridgeTests.swiftABISmall(ABIBridgeTests.SwiftABISmall) -> ABIBridgeTests.SwiftABISmall",
            as: ((SwiftABISmall) -> SwiftABISmall).self
        )
        let c = try unsafe small.unsafeInvoke(.init(a: -5, b: 20, c: 30, d: 1.5))
        let expectedC = swiftABISmall(.init(a: -5, b: 20, c: 30, d: 1.5))
        #expect(c.a == expectedC.a && c.b == expectedC.b && c.c == expectedC.c && c.d == expectedC.d)
    }

    @Test func unsupportedRepresentationsAndMissingDeclarationsThrow() async throws {
        for name in [
            "Example.generic<A>(A) -> A",
            "Example.asyncFunction() async -> Swift.Int",
            "Example.throwing() throws -> Swift.Int",
            "Example.mutate(inout Swift.Int) -> Swift.Int",
            "Example.consume(__owned Swift.String) -> Swift.Int",
        ] {
            await #expect(throws: ABIResolutionError.self) {
                _ = try await ABIRuntime.shared.swiftFunction(named: name, as: (() -> Int).self)
            }
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftFunction(
                named: "Example.invalid(_:_:)", as: ((Int) -> Int).self
            )
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftFunction(
                named: "ABIBridgeTests.swiftABIAnswer() -> Swift.Int32", as: (() -> [String: Int]).self
            )
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await ABIRuntime.shared.swiftFunction(
                named: "ABIBridgeTests.swiftABIAbsent() -> ()", as: (() -> Void).self
            )
        }
    }
}
