import ABIBridge
import Foundation
import ObjectiveCFixtures
import Testing

@frozen public struct CallerRecord: BitwiseCopyable, ABIBridgeValue, ABIBridgeSwiftValue {
    public var value: Double
    public var tag: Int8
    public static let abiType = try! NativeType.structure(named: "Record", fields: [.double, .int8])
    public static var swiftABIType: NativeType { abiType }
}
private struct CallerNestedRecord: BitwiseCopyable, ABIBridgeValue {
    var first: CallerRecord
    var second: Double
    static let abiType = try! NativeType.structure(named: "NestedRecord", fields: [CallerRecord.abiType, .double])
}

@frozen public enum CallerChoice: BitwiseCopyable, ABIBridgeSwiftValue {
    case number(Int64), empty
    public static let swiftABIType = try! NativeType.structure(named: "Choice",
        fields: Array(repeating: .uint, count: MemoryLayout<Int64>.size / MemoryLayout<UInt>.size) + [.uint8])
}

@frozen public enum CallerMode: Int32, BitwiseCopyable, ABIBridgeValue, ABIBridgeSwiftValue {
    case slow = 7, fast = 42
    public static let abiType = NativeType.int32
    public static let swiftABIType = NativeType.uint8
    public init(nativeValue: NativeValue) throws {
        let raw = try unsafe nativeValue.read(as: Int32.self)
        guard let value = Self(rawValue: raw) else {
            throw ABIInvocationError.incompatibleValue(expected: "CallerMode", actual: String(raw))
        }
        self = value
    }
    public static func nativeValue(from value: Self) throws -> NativeValue {
        try NativeValue(copying: value.rawValue, as: abiType)
    }
}
@inline(never) public func callerMode(_ value: CallerMode) -> CallerMode {
    value == .slow ? .fast : .slow
}

@inline(never) public func callerRecord(_ value: CallerRecord) -> CallerRecord {
    CallerRecord(value: value.value + 1.5, tag: value.tag + 2)
}
@inline(never) public func callerApply(_ body: (CallerRecord) -> CallerRecord, _ value: CallerRecord) -> CallerRecord {
    body(value)
}
@inline(never) public func callerChoice(_ value: CallerChoice) -> CallerChoice { value }
@inline(never) public func callerRecords(_ values: [CallerRecord]) -> [CallerRecord] { values.reversed() }

struct CallerDescribedValueTests {
    @Test func layoutOnlyConformanceWorksForCArgumentsAndResults() async throws {
        let function = try await ABIRuntime.shared.cFunction(
            named: "ABICTransformRecord", as: ((CallerRecord) -> CallerRecord).self)
        let input = CallerRecord(value: 2, tag: 3)
        let actual = try unsafe function.unsafeInvoke(input)
        let expected = ABICTransformRecord(ABICXXRecord(value: input.value, tag: input.tag))
        #expect(actual.value == expected.value && actual.tag == expected.tag)
        #expect(MemoryLayout<CallerRecord>.size < CallerRecord.abiType.size)
    }

    @Test func nativeStorageCanBePassedAndReadWithOnlyAMetatype() async throws {
        struct UnregisteredRecord: BitwiseCopyable { var value: Double; var tag: Int8 }
        let layout = try NativeType.structure(named: "caller-supplied", fields: [.double, .int8])
        let input = try NativeValue(copying: UnregisteredRecord(value: 2, tag: 3), as: layout)
        let call = try await ABIRuntime.shared.cFunction(
            named: "ABICTransformRecord", signature: .init(parameters: [layout], returns: layout))
        let output = try unsafe call.unsafeInvoke(with: [input])
        let actual = try unsafe output.read(as: UnregisteredRecord.self)
        #expect(actual.value == 3.5 && actual.tag == 5)
        let padding = try input.view(at: MemoryLayout<UnregisteredRecord>.size,
            as: .opaque(named: "padding", size: layout.size - MemoryLayout<UnregisteredRecord>.size))
        #expect(unsafe padding.withUnsafeBytes { $0.allSatisfy { $0 == 0 } })
    }

    @Test func nestedCallerLayoutsUseTheExistingCCodec() async throws {
        let function = try await ABIRuntime.shared.cFunction(
            named: "ABICTransformNestedRecord", as: ((CallerNestedRecord) -> CallerNestedRecord).self)
        let actual = try unsafe function.unsafeInvoke(CallerNestedRecord(first: CallerRecord(value: 2, tag: 3), second: 4))
        #expect(actual.first.value == 3.5 && actual.first.tag == 5 && actual.second == 7)
    }

    @Test func cxxFreeAndReceiverCallsShareTheSameLayoutContract() async throws {
        let runtime = ABIRuntime.shared
        let free = try await runtime.cxxFunction(
            named: "ABICXXFixture::transformRecord(ABICXXRecord)", as: ((CallerRecord) -> CallerRecord).self)
        let actual = try unsafe free.unsafeInvoke(CallerRecord(value: 2, tag: 3))
        #expect(actual.value == 3.5 && actual.tag == 5)
        let pointer = try #require(ABICXXRecordReceiver())
        let storage = unsafe NativeValue(borrowing: UnsafeMutableRawPointer(mutating: pointer),
                                          as: try .opaque(named: "RecordReceiver"))
        let receiver = runtime.cxxObject(storage, typeNamed: "ABICXXFixture::RecordReceiver")
        let method = try await receiver.method(named: "shifted(ABICXXRecord) const",
                                                as: ((CallerRecord) -> CallerRecord).self)
        let result = try unsafe method.unsafeInvoke(CallerRecord(value: 2, tag: 3))
        #expect(result.value == 12 && result.tag == 4)
    }

    @Test func swiftStructEnumArrayAndCallbackUseCallerDescriptions() async throws {
        let runtime = ABIRuntime.shared
        let function = try await runtime.swiftFunction(
            named: "ABIBridgeTests.callerRecord(_:)", as: ((CallerRecord) -> CallerRecord).self)
        let input = CallerRecord(value: 2, tag: 3)
        let result = try unsafe function.unsafeInvoke(input)
        #expect(result.value == 3.5 && result.tag == 5)
        let apply = try await runtime.swiftFunction(named: "ABIBridgeTests.callerApply(_:_:)",
            as: ((NativeSwiftClosure<(CallerRecord) -> CallerRecord>, CallerRecord) -> CallerRecord).self)
        let body = try NativeSwiftClosure { (value: CallerRecord) in callerRecord(value) }
        let callbackResult = try unsafe apply.unsafeInvoke(body, input)
        #expect(callbackResult.value == result.value && callbackResult.tag == result.tag)
        let choice = try await runtime.swiftFunction(
            named: "ABIBridgeTests.callerChoice(_:)", as: ((CallerChoice) -> CallerChoice).self)
        if case .number(let value) = try unsafe choice.unsafeInvoke(.number(42)) { #expect(value == 42) }
        else { Issue.record("Expected number payload") }
        if case .empty = try unsafe choice.unsafeInvoke(.empty) {} else { Issue.record("Expected empty case") }
        let array = try await runtime.swiftFunction(
            named: "ABIBridgeTests.callerRecords(_:)", as: (([CallerRecord]) -> [CallerRecord]).self)
        let records = try unsafe array.unsafeInvoke([input, CallerRecord(value: 4, tag: 5)])
        #expect(records.count == 2 && records[0].value == 4 && records[1].tag == 3)
    }

    @Test func rawValuesAndSwiftEnumTagsUseTheirDeclaredLanguageConventions() async throws {
        let runtime = ABIRuntime.shared
        let c = try await runtime.cFunction(named: "ABICNextRecordMode", as: ((CallerMode) -> CallerMode).self)
        let cxx = try await runtime.cxxFunction(named: "ABICXXFixture::nextMode(ABICXXFixture::RecordMode)",
                                                as: ((CallerMode) -> CallerMode).self)
        let swift = try await runtime.swiftFunction(named: "ABIBridgeTests.callerMode(_:)",
                                                    as: ((CallerMode) -> CallerMode).self)
        #expect(try unsafe c.unsafeInvoke(.slow) == .fast)
        #expect(try unsafe cxx.unsafeInvoke(.slow) == .fast)
        #expect(try unsafe swift.unsafeInvoke(.slow) == .fast)
        #expect(try unsafe c.unsafeInvoke(.fast) == .slow)
        #expect(try unsafe cxx.unsafeInvoke(.fast) == .slow)
        #expect(try unsafe swift.unsafeInvoke(.fast) == .slow)
        let invalid = try NativeValue(copying: Int32(9), as: .int32)
        #expect(throws: ABIInvocationError.self) { try invalid.cast(to: CallerMode.self) }
    }

    @Test func layoutsOutsideTheValuesExtentStillFail() throws {
        let value = CallerRecord(value: 2, tag: 3)
        #expect(throws: NativeValueError.self) { try NativeValue(copying: value, as: .int64) }
        let narrow = try NativeValue(copying: Int64(42), as: .int64)
        #expect(throws: NativeValueError.self) { try CallerRecord(nativeValue: narrow) }
        let wide = NativeValue(type: try .opaque(named: "too-wide", size: MemoryLayout<CallerRecord>.stride + 1)) {
            $0.initializeMemory(as: UInt8.self, repeating: 0)
        }
        #expect(throws: NativeValueError.self) { try CallerRecord(nativeValue: wide) }
        #expect(throws: NativeValueError.self) {
            try NativeValue(copying: value, as: .opaque(named: "oversized", size: MemoryLayout<CallerRecord>.stride + 1))
        }
    }
}
