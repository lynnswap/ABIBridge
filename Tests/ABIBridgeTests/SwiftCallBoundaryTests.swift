import ABIBridge
import ABIBridgeCore
import Darwin
import Testing

@frozen public struct SwiftABIBytes3: BitwiseCopyable {
    public var a, b, c: UInt8
}
@inline(never) public func swiftABIBytes(_ value: SwiftABIBytes3) -> SwiftABIBytes3 {
    .init(a: value.c, b: value.b, c: value.a)
}

extension SwiftABIBytes3: ABIBridgeValue {
    public static let abiType = try! NativeType.structure(named: "ThreeBytes", fields: [.uint8, .uint8, .uint8])
    public init(nativeValue: NativeValue) throws { self = try unsafe nativeValue.read(as: Self.self) }
    public static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value, as: abiType)
    }
}

@frozen public struct SwiftABIMixedFields: BitwiseCopyable {
    public var integer: Int8
    public var floating: Float
}
@inline(never) public func swiftABIMixedFields(_ value: SwiftABIMixedFields) -> SwiftABIMixedFields {
    .init(integer: value.integer - 1, floating: value.floating + 2.5)
}
extension SwiftABIMixedFields: ABIBridgeValue {
    public static let abiType = try! NativeType.structure(named: "MixedFields", fields: [.int8, .float])
    public init(nativeValue: NativeValue) throws { self = try unsafe nativeValue.read(as: Self.self) }
    public static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value, as: abiType)
    }
}

private func withGuardedThreeBytes(_ body: (UnsafeMutableRawPointer) throws -> Void) throws {
    let page = Int(getpagesize())
    let allocation = try #require(mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
    try #require(allocation != MAP_FAILED)
    defer { munmap(allocation, page * 2) }
    try #require(mprotect(allocation.advanced(by: page), page, PROT_NONE) == 0)
    try body(allocation.advanced(by: page - 3))
}

struct SwiftCallBoundaryTests {
    @Test func integerAndFloatSharingAChunkUseSeparateRegisterBanks() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ABIBridgeTests.swiftABIMixedFields(_:)",
            as: ((SwiftABIMixedFields) -> SwiftABIMixedFields).self
        )
        let input = SwiftABIMixedFields(integer: -8, floating: 3.25)
        let result = try unsafe function.unsafeInvoke(input)
        let expected = swiftABIMixedFields(input)
        #expect(result.integer == expected.integer && result.floating == expected.floating)
    }

    @Test func coalescedComponentsRespectGuardedArgumentAndResultExtents() async throws {
        let symbol = try await ABIRuntime.shared.resolve(.init(
            name: "ABIBridgeTests.swiftABIBytes(ABIBridgeTests.SwiftABIBytes3) -> ABIBridgeTests.SwiftABIBytes3",
            language: .swift
        ))
        var failure: OpaquePointer?
        defer { if let failure { ABIReleaseResolutionFailure(failure) } }
        let byte = try #require(ABICreateScalarType(Int32(ABIValueUInt8), &failure))
        defer { ABIReleaseValueType(byte) }
        let fields: [OpaquePointer?] = [byte, byte, byte]
        let triple = try fields.withUnsafeBufferPointer {
            try #require(ABICreateStructType($0.baseAddress, $0.count, &failure))
        }
        defer { ABIReleaseValueType(triple) }
        #expect(ABIValueTypeSize(triple) == 3)
        let parameters: [OpaquePointer?] = [triple]
        let interface = try parameters.withUnsafeBufferPointer {
            try #require(ABICreateSwiftCallInterface(triple, $0.baseAddress, $0.count, &failure))
        }
        defer { ABIReleaseSwiftCallInterface(interface) }
        try withGuardedThreeBytes { input in
            input.storeBytes(of: UInt8(1), toByteOffset: 0, as: UInt8.self)
            input.storeBytes(of: UInt8(2), toByteOffset: 1, as: UInt8.self)
            input.storeBytes(of: UInt8(3), toByteOffset: 2, as: UInt8.self)
            try withGuardedThreeBytes { output in
                let arguments: [UnsafeMutableRawPointer?] = [input]
                let success = unsafe symbol.withUnsafeAddress { address in
                    arguments.withUnsafeBufferPointer {
                        ABIUnsafeInvokeSwiftCallInterface(
                            interface, ABIUnsafeFunctionAtAddress(address), output, $0.baseAddress, nil, &failure
                        )
                    }
                }
                try #require(success)
                let result = output.loadUnaligned(as: SwiftABIBytes3.self)
                let expected = swiftABIBytes(.init(a: 1, b: 2, c: 3))
                #expect(result.a == expected.a && result.b == expected.b && result.c == expected.c)
            }
        }
    }

    @Test func typedWrappersSupportOddSizedTrivialValues() async throws {
        let function = try await ABIRuntime.shared.swiftFunction(
            named: "ABIBridgeTests.swiftABIBytes(ABIBridgeTests.SwiftABIBytes3) -> ABIBridgeTests.SwiftABIBytes3",
            as: ((SwiftABIBytes3) -> SwiftABIBytes3).self
        )
        let result = try unsafe function.unsafeInvoke(.init(a: 1, b: 2, c: 3))
        #expect(result.a == 3 && result.b == 2 && result.c == 1)
    }
}
