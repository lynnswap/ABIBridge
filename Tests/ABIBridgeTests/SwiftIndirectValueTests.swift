#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ABIBridgeCore
import ManagedSwiftFixtures
import Testing

extension IndirectRecord: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { try! .opaque(named: "IndirectRecord") }
}

public protocol BoxPayloadABI: SendableMetatype { static var boxABI: NativeType { get } }
extension Int64: BoxPayloadABI { public static var boxABI: NativeType { .int64 } }
extension Double: BoxPayloadABI { public static var boxABI: NativeType { .double } }
extension String: BoxPayloadABI {
    public static var boxABI: NativeType {
        try! .structure(named: "String", fields: Array(repeating: .uint, count: MemoryLayout<String>.size / MemoryLayout<UInt>.size))
    }
}
extension ExplicitBox: ABIBridgeSwiftValue where Value: BoxPayloadABI {
    public static var swiftABIType: NativeType { Value.boxABI }
}
extension BoxNamespace.Container: ABIBridgeSwiftValue where Value: BoxPayloadABI {
    public static var swiftABIType: NativeType { Value.boxABI }
}
extension 箱: ABIBridgeSwiftValue where Value: BoxPayloadABI {
    public static var swiftABIType: NativeType { Value.boxABI }
}

struct SwiftIndirectValueTests {
    @Test func smallResilientValuesUseDeclaredIndirection() async throws {
        let echo = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.echoIndirectRecord(_:)", as: ((IndirectRecord) -> IndirectRecord).self
        )
        weak var observed: LifetimeToken?
        var destroyed = 0
        var result: IndirectRecord?
        do {
            let token = LifetimeToken { destroyed += 1 }
            observed = token
            result = try unsafe echo.unsafeInvoke(IndirectRecord(token: token, number: 42))
            #expect(result?.token === token && result?.number == 42)
        }
        withExtendedLifetime(result) { #expect(observed != nil && destroyed == 0) }
        result = nil
        #expect(observed == nil && destroyed == 1)
    }

    @Test func resilientClosuresReabstractArgumentsAndResults() async throws {
        let apply = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.applyIndirectRecord(_:_:)",
            as: ((NativeSwiftClosure<IndirectRecord, IndirectRecord>, IndirectRecord) -> IndirectRecord).self
        )
        let callback = try NativeSwiftClosure { (value: IndirectRecord) in value.advanced(7) }
        let token = LifetimeToken()
        let input = IndirectRecord(token: token, number: 35)
        let actual = try unsafe apply.unsafeInvoke(callback, input)
        #expect(actual.token === token && actual.number == 42)
        let make = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeIndirectRecordClosure(_:)",
            as: ((Int64) -> NativeSwiftClosure<IndirectRecord, IndirectRecord>).self
        )
        let returned = try unsafe make.unsafeInvoke(7)
        let result = try unsafe returned.unsafeInvoke(input)
        #expect(result.token === token && result.number == 42)
    }

    @Test func resilientInitializersAndMethodsUseMetadataAndValueStorage() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.IndirectRecord",
                                                         as: IndirectRecord.self)
        let initialize = try await type.initializer(named: "init(token:number:)",
                                                    as: ((LifetimeToken, Int64) -> IndirectRecord).self)
        let advance = try await type.method(named: "advanced(_:)", as: ((Int64) -> IndirectRecord).self)
        let number = try await type.getter(named: "number", as: Int64.self)
        let token = LifetimeToken()
        let original = try unsafe initialize.unsafeInvoke(token, 35)
        let result = try unsafe advance.unsafeInvoke(on: original, 7)
        #expect(result.token === token)
        #expect(try unsafe number.unsafeInvoke(on: result) == 42)
        #expect(original.number == 35)
    }

    @Test func genericNominalCallbacksUseDifferentPhysicalLayouts() async throws {
        let runtime = ABIRuntime.shared
        let integer = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.applyExplicitBox(_:_:)",
            as: ((NativeSwiftClosure<ExplicitBox<Int64>, ExplicitBox<Int64>>, ExplicitBox<Int64>) -> ExplicitBox<Int64>).self
        )
        let integerBody = try NativeSwiftClosure { (value: ExplicitBox<Int64>) in ExplicitBox(value.value + 7) }
        #expect(try unsafe integer.unsafeInvoke(integerBody, ExplicitBox(35)).value == 42)
        let floating = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.applyDoubleBox(_:_:)",
            as: ((NativeSwiftClosure<ExplicitBox<Double>, ExplicitBox<Double>>, ExplicitBox<Double>) -> ExplicitBox<Double>).self
        )
        let floatingBody = try NativeSwiftClosure { (value: ExplicitBox<Double>) in ExplicitBox(value.value + 0.5) }
        #expect(try unsafe floating.unsafeInvoke(floatingBody, ExplicitBox(1.5)).value == 2)
        let string = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.applyStringBox(_:_:)",
            as: ((NativeSwiftClosure<ExplicitBox<String>, ExplicitBox<String>>, ExplicitBox<String>) -> ExplicitBox<String>).self
        )
        let stringBody = try NativeSwiftClosure { (value: ExplicitBox<String>) in ExplicitBox(value.value + "!") }
        let text = String(repeating: "managed", count: 100)
        #expect(try unsafe string.unsafeInvoke(stringBody, ExplicitBox(text)).value == text + "!")
    }

    @Test func genericReturnedClosuresKeepTheirNominalIdentity() async throws {
        let make = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeExplicitBoxClosure(_:)",
            as: ((Int64) -> NativeSwiftClosure<ExplicitBox<Int64>, ExplicitBox<Int64>>).self
        )
        let returned = try unsafe make.unsafeInvoke(7)
        #expect(try unsafe returned.unsafeInvoke(ExplicitBox(35)).value == 42)
    }

    @Test func nestedAndUnicodeNominalNamesNeedNoCallerMangling() async throws {
        let runtime = ABIRuntime.shared
        let nested = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.applyNestedBox(_:_:)",
            as: ((NativeSwiftClosure<BoxNamespace.Container<Int64>, BoxNamespace.Container<Int64>>,
                  BoxNamespace.Container<Int64>) -> BoxNamespace.Container<Int64>).self
        )
        let nestedBody = try NativeSwiftClosure { (value: BoxNamespace.Container<Int64>) in
            BoxNamespace.Container(value.value + 7)
        }
        #expect(try unsafe nested.unsafeInvoke(nestedBody, BoxNamespace.Container(35)).value == 42)
        let unicode = try await runtime.swiftFunction(
            named: "ManagedSwiftFixtures.applyUnicodeBox(_:_:)",
            as: ((NativeSwiftClosure<箱<Int64>, 箱<Int64>>, 箱<Int64>) -> 箱<Int64>).self
        )
        let unicodeBody = try NativeSwiftClosure { (value: 箱<Int64>) in 箱(value.value + 7) }
        #expect(try unsafe unicode.unsafeInvoke(unicodeBody, 箱(35)).value == 42)
    }

#if DEBUG
    @Test func explicitlyIndirectStorageCannotEnterTheCABI() throws {
        let indirect = try CValueType(indirectSwiftSize: MemoryLayout<IndirectRecord>.size,
                                      alignment: MemoryLayout<IndirectRecord>.alignment)
        #expect(ABISwiftValueIsIndirect(indirect.handle))
        var error: OpaquePointer?
        let cCall = ABICreateCCallInterface(indirect.handle, nil, 0, &error)
        #expect(cCall == nil)
        if let cCall { ABIReleaseCallInterface(cCall) }
        #expect(error != nil)
        if let error { ABIReleaseResolutionFailure(error) }
    }

    @Test func genericDiscriminatorsIgnoreSubstitutions() throws {
        #expect(try swiftClosureAuthType(ExplicitBox<Int64>.self) == swiftClosureAuthType(ExplicitBox<Double>.self))
        #expect(try swiftClosureAuthType(ExplicitBox<Int64>.self) == swiftClosureAuthType(ExplicitBox<String>.self))
        #expect(try swiftClosureAuthType(IndirectRecord.self) == "-indirect")
    }
#endif
}
