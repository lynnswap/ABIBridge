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

/// Two indirect elements and a direct part too large for registers.
private typealias RecordsAndWords = (
    IndirectRecord, Int64, IndirectRecord, Int64, Int64, Int64, Int64
)

/// Calls `body` with two records holding fresh tokens, and checks that every
/// element of its result arrives and that the tokens are released afterward.
private func expectRecordsAndWords(
    numbers: (Int64, Int64),
    words: [Int64],
    _ body: (IndirectRecord, IndirectRecord) async throws -> RecordsAndWords
) async throws {
    weak var observedFirst: LifetimeToken?
    weak var observedSecond: LifetimeToken?
    do {
        let first = LifetimeToken(), second = LifetimeToken()
        observedFirst = first
        observedSecond = second
        let result = try await body(
            IndirectRecord(token: first, number: 1),
            IndirectRecord(token: second, number: 2)
        )
        #expect(result.0.token === first && result.2.token === second)
        #expect(result.0.number == numbers.0 && result.2.number == numbers.1)
        #expect([result.1, result.3, result.4, result.5, result.6] == words)
    }
    #expect(observedFirst == nil && observedSecond == nil)
}

struct SwiftIndirectValueTests {
    @Test func smallResilientValuesUseDeclaredIndirection() async throws {
        let echo = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.echoIndirectRecord(_:)",
                as: ((IndirectRecord) -> IndirectRecord).self
            )
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
        let apply = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.applyIndirectRecord(_:_:)",
                as: ((NativeSwiftClosure<(IndirectRecord) -> IndirectRecord>, IndirectRecord)
                    -> IndirectRecord).self
            )
        )
        let callback = try NativeSwiftClosure { (value: IndirectRecord) in value.advanced(7) }
        let token = LifetimeToken()
        let input = IndirectRecord(token: token, number: 35)
        let actual = try unsafe apply.unsafeInvoke(callback, input)
        #expect(actual.token === token && actual.number == 42)
        let make = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.makeIndirectRecordClosure(_:)",
                as: ((Int64) -> NativeSwiftClosure<(IndirectRecord) -> IndirectRecord>).self
            )
        )
        let returned = try unsafe make.unsafeInvoke(7)
        let result = try unsafe returned.unsafeInvoke(input)
        #expect(result.token === token && result.number == 42)
    }

    @Test func resilientInitializersAndMethodsUseMetadataAndValueStorage() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ManagedSwiftFixtures.IndirectRecord",
                                                         as: IndirectRecord.self)
        let initialize = try await type.resolve(
            .initializer(
                "init(token:number:)",
                as: ((LifetimeToken, Int64) -> IndirectRecord).self
            )
        )
        let advance = try await type.resolve(
            .method("advanced(_:)", as: ((Int64) -> IndirectRecord).self)
        )
        let number = try await type.resolve(.getter("number", as: (() -> Int64).self))
        let token = LifetimeToken()
        let original = try unsafe initialize.unsafeInvoke(token, 35)
        let result = try unsafe advance.unsafeInvoke(on: original, 7)
        #expect(result.token === token)
        #expect(try unsafe number.unsafeInvoke(on: result) == 42)
        #expect(original.number == 35)
    }

    @Test func genericNominalCallbacksUseDifferentPhysicalLayouts() async throws {
        let runtime = ABIRuntime.shared
        let integer = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.applyExplicitBox(_:_:)",
                as: ((
                    NativeSwiftClosure<(ExplicitBox<Int64>) -> ExplicitBox<Int64>>,
                    ExplicitBox<Int64>
                ) -> ExplicitBox<Int64>).self
            )
        )
        let integerBody = try NativeSwiftClosure { (value: ExplicitBox<Int64>) in ExplicitBox(value.value + 7) }
        #expect(try unsafe integer.unsafeInvoke(integerBody, ExplicitBox(35)).value == 42)
        let floating = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.applyDoubleBox(_:_:)",
                as: ((
                    NativeSwiftClosure<(ExplicitBox<Double>) -> ExplicitBox<Double>>,
                    ExplicitBox<Double>
                ) -> ExplicitBox<Double>).self
            )
        )
        let floatingBody = try NativeSwiftClosure { (value: ExplicitBox<Double>) in ExplicitBox(value.value + 0.5) }
        #expect(try unsafe floating.unsafeInvoke(floatingBody, ExplicitBox(1.5)).value == 2)
        let string = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.applyStringBox(_:_:)",
                as: ((
                    NativeSwiftClosure<(ExplicitBox<String>) -> ExplicitBox<String>>,
                    ExplicitBox<String>
                ) -> ExplicitBox<String>).self
            )
        )
        let stringBody = try NativeSwiftClosure { (value: ExplicitBox<String>) in ExplicitBox(value.value + "!") }
        let text = String(repeating: "managed", count: 100)
        #expect(try unsafe string.unsafeInvoke(stringBody, ExplicitBox(text)).value == text + "!")
    }

    @Test func genericReturnedClosuresKeepTheirNominalIdentity() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.makeExplicitBoxClosure(_:)",
                as: ((Int64) -> NativeSwiftClosure<(ExplicitBox<Int64>) -> ExplicitBox<Int64>>).self
            )
        )
        let returned = try unsafe make.unsafeInvoke(7)
        #expect(try unsafe returned.unsafeInvoke(ExplicitBox(35)).value == 42)
    }

    @Test func nestedAndUnicodeNominalNamesNeedNoCallerMangling() async throws {
        let runtime = ABIRuntime.shared
        let nested = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.applyNestedBox(_:_:)",
                as: ((
                    NativeSwiftClosure<
                        (BoxNamespace.Container<Int64>) -> BoxNamespace.Container<Int64>
                    >,
                    BoxNamespace.Container<Int64>
                ) -> BoxNamespace.Container<Int64>).self
            )
        )
        let nestedBody = try NativeSwiftClosure { (value: BoxNamespace.Container<Int64>) in
            BoxNamespace.Container(value.value + 7)
        }
        #expect(try unsafe nested.unsafeInvoke(nestedBody, BoxNamespace.Container(35)).value == 42)
        let unicode = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.applyUnicodeBox(_:_:)",
                as: ((NativeSwiftClosure<(箱<Int64>) -> 箱<Int64>>, 箱<Int64>) -> 箱<Int64>).self
            )
        )
        let unicodeBody = try NativeSwiftClosure { (value: 箱<Int64>) in 箱(value.value + 7) }
        #expect(try unsafe unicode.unsafeInvoke(unicodeBody, 箱(35)).value == 42)
    }

    // With several indirect elements, the compiler passes the direct part's
    // address as the first ordinary argument rather than in the
    // indirect-result register.
    @Test func severalIndirectTupleElementsPassTheDirectPartFirst() async throws {
        typealias Body = NativeSwiftClosure<(IndirectRecord, IndirectRecord) -> RecordsAndWords>
        let runtime = ABIRuntime.shared
        let call = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.indirectRecordsAndWords(_:_:)",
                as: ((IndirectRecord, IndirectRecord) -> RecordsAndWords).self
            )
        )
        try await expectRecordsAndWords(numbers: (2, 4), words: [10, 20, 30, 40, 50]) {
            try unsafe call.unsafeInvoke($0, $1)
        }
        let make = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.makeIndirectRecordsAndWordsClosure(_:)",
                as: ((Int64) -> Body).self
            )
        )
        let closure = try unsafe make.unsafeInvoke(5)
        try await expectRecordsAndWords(numbers: (6, 12), words: [5, 6, 7, 8, 9]) {
            try unsafe closure.unsafeInvoke($0, $1)
        }
        let apply = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.applyIndirectRecordsAndWords(_:_:_:)",
                as: ((Body, IndirectRecord, IndirectRecord) -> RecordsAndWords).self
            )
        )
        let body = try Body { first, second in
            (first.advanced(3), 11, second.advanced(4), 21, 31, 41, 51)
        }
        try await expectRecordsAndWords(numbers: (104, 106), words: [12, 22, 32, 42, 52]) {
            try unsafe apply.unsafeInvoke(body, $0, $1)
        }
    }

    // Async entries never use the indirect-result register.
    @Test func asyncResultsWithSeveralIndirectTupleElementsPassTheDirectPartFirst() async throws {
        typealias Body = NativeSwiftClosure<
            @Sendable @concurrent (IndirectRecord, IndirectRecord) async -> RecordsAndWords
        >
        let runtime = ABIRuntime.shared
        let call = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.asyncIndirectRecordsAndWords(_:_:)",
                as: (@concurrent (IndirectRecord, IndirectRecord) async -> RecordsAndWords).self
            )
        )
        try await expectRecordsAndWords(numbers: (2, 4), words: [10, 20, 30, 40, 50]) {
            try unsafe await call.unsafeInvoke($0, $1)
        }
        let apply = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.applyAsyncIndirectRecordsAndWords(_:_:_:)",
                as: (@concurrent (Body, IndirectRecord, IndirectRecord) async -> RecordsAndWords)
                    .self
            )
        )
        let advance: @Sendable (IndirectRecord, IndirectRecord) async -> RecordsAndWords = {
            first,
            second in
            await Task.yield()
            return (first.advanced(3), 11, second.advanced(4), 21, 31, 41, 51)
        }
        let body = try Body(advance)
        try await expectRecordsAndWords(numbers: (104, 106), words: [12, 22, 32, 42, 52]) {
            try unsafe await apply.unsafeInvoke(body, $0, $1)
        }
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
        #expect(try swiftClosureAuthType(ExplicitBox<Int64>.self, position: .parameter) == swiftClosureAuthType(ExplicitBox<Double>.self, position: .parameter))
        #expect(try swiftClosureAuthType(ExplicitBox<Int64>.self, position: .parameter) == swiftClosureAuthType(ExplicitBox<String>.self, position: .parameter))
        #expect(try swiftClosureAuthType(IndirectRecord.self, position: .parameter) == "-indirect")
    }
#endif
}
