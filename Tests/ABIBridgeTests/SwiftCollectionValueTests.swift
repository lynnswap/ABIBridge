import ABIBridge
import Foundation
import ManagedSwiftFixtures
import Testing

private final class CollectionCapture: Sendable {
    let values: [String]
    init(_ values: [String]) { self.values = values }
}

private enum CollectionConversionError: Error { case rejected }
private struct RejectingCollectionArgument: ABIBridgeValue {
    static let abiType = NativeType.int64
    init() {}
    init(nativeValue: NativeValue) throws { throw CollectionConversionError.rejected }
    static func nativeValue(from value: Self) throws -> NativeValue { throw CollectionConversionError.rejected }
}

struct SwiftCollectionValueTests {
    @Test func variadicFunctionsBorrowOneArrayArgument() async throws {
        let runtime = ABIRuntime()
        let path = try #require(Bundle(for: LifetimeToken.self).executableURL)
        let name =
            "ManagedSwiftFixtures.variadicStrings(Swift.String, Swift.String...) -> [Swift.String]"
        let call = try await runtime.resolve(
            .function(
                name,
                as: ((String, [String]) -> [String]).self,
                declaredAs: "(Swift.String, Swift.String...) -> [Swift.String]"
            ),
            in: .path(path)
        )
        let long = String(repeating: "owned", count: 100)
        let input = [long, "tail"]
        var output = try unsafe call.unsafeInvoke("first", input)
        #expect(output == variadicStrings("first", long, "tail"))
        output[1] = "changed"
        #expect(input == [long, "tail"])

        let own = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                as: (([String]) -> NativeSwiftValue).self,
                genericArguments: [.type([String].self)]
            ),
            in: .path(path)
        )
        let nativeInput = try unsafe own.unsafeInvoke(input)
        let runtimeCall = try await runtime.resolve(
            .function(
                name,
                as: ((String, NativeSwiftValue) -> NativeSwiftValue).self
            ),
            in: .path(path)
        )
        let nativeOutput = try unsafe runtimeCall.unsafeInvoke("first", nativeInput)
        #expect(try nativeOutput.take(as: [String].self) == variadicStrings("first", long, "tail"))
        #expect(!nativeInput.isConsumed)
        #expect(try nativeInput.take(as: [String].self) == input)
    }

    @Test func nativeArrayCallsPreserveCopyOnWrite() async throws {
        let append = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.appendStrings(_:_:)",
                as: (([String], String) -> [String]).self
            )
        )
        let long = String(repeating: "owned", count: 100)
        for input in [[], [""], [long, "second"]] {
            var result = try unsafe append.unsafeInvoke(input, long)
            #expect(result == appendStrings(input, long))
            result[0] = "changed"
            #expect(input.first != "changed")
        }
    }

    @Test func optionalValuesDistinguishNilAndEmpty() async throws {
        let strings = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.optionalStrings(_:)",
                as: (([String]?) -> [String]?).self
            )
        )
        for input: [String]? in [nil, [], [""], [String(repeating: "long", count: 100)]] {
            #expect(try unsafe strings.unsafeInvoke(input) == optionalStrings(input))
        }
        let decorate = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.decorateOptionalString(_:)",
                as: ((String?) -> String?).self
            )
        )
        for input: String? in [nil, "", "short", String(repeating: "long", count: 100)] {
            #expect(try unsafe decorate.unsafeInvoke(input) == decorateOptionalString(input))
        }
    }

    @Test func arrayElementsUseTheirOwnValueWitnesses() async throws {
        let copy = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.copyManagedRecords(_:)",
                as: (([ManagedRecord]) -> [ManagedRecord]).self
            )
        )
        weak var observed: LifetimeToken?
        var destroyed = 0
        var result: [ManagedRecord]?
        do {
            let token = LifetimeToken { destroyed += 1 }
            observed = token
            let input = [ManagedRecord(token: token, number: 42)]
            result = try unsafe copy.unsafeInvoke(input)
        }
        withExtendedLifetime(result) {
            #expect(observed != nil)
            #expect(result?.first?.number == 42)
            #expect(destroyed == 0)
        }
        result = nil
        #expect(observed == nil)
        #expect(destroyed == 1)
    }

    @Test func nativeClosuresReceiveAndReturnCollections() async throws {
        let apply = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.applyArrayClosure(_:_:)",
                as: ((NativeSwiftClosure<([String]) -> [String]>, [String]) -> [String]).self
            )
        )
        let transform = try NativeSwiftClosure { (value: [String]) in value + ["callback"] }
        #expect(try unsafe apply.unsafeInvoke(transform, ["input"]) == ["input", "callback"])
        let applyDictionary = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.applyDictionaryClosure(_:_:)",
                as: ((NativeSwiftClosure<([String: Int64]) -> Set<Int64>>, [String: Int64]) -> Set<
                    Int64
                >).self
            )
        )
        let values = try NativeSwiftClosure { (value: [String: Int64]) in Set(value.values).union([9]) }
        #expect(try unsafe applyDictionary.unsafeInvoke(values, ["a": 1, "b": 2]) == [1, 2, 9])
        let make = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.makeArrayClosure(_:)",
                as: ((String) -> NativeSwiftClosure<([String]) -> [String]>).self
            )
        )
        let suffix = String(repeating: "suffix", count: 100)
        let returned = try unsafe make.unsafeInvoke(suffix)
        #expect(try unsafe returned.unsafeInvoke([]) == [suffix])
        #expect(try unsafe returned.unsafeInvoke(["first"]) == ["first", suffix])
    }

    @Test func optionalClosuresPreservePayloadsAndNil() async throws {
        let strings = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.applyOptionalArrayClosure(_:_:)",
                as: ((NativeSwiftClosure<([String]?) -> [String]?>, [String]?) -> [String]?).self
            )
        )
        let optionalArray = try NativeSwiftClosure { (value: [String]?) in value.map { $0 + ["callback"] } }
        for value: [String]? in [nil, [], ["first"]] {
            #expect(try unsafe strings.unsafeInvoke(optionalArray, value) == value.map { $0 + ["callback"] })
        }
        let apply = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.applyOptionalStringClosure(_:_:)",
                as: ((NativeSwiftClosure<(String?) -> String?>, String?) -> String?).self
            )
        )
        let suffix = String(repeating: "!", count: 100)
        let callback = try NativeSwiftClosure { (value: String?) in value.map { $0 + suffix } }
        let make = try await ABIRuntime.shared.resolve(
            .function(
                "ManagedSwiftFixtures.makeOptionalStringClosure(_:)",
                as: ((String) -> NativeSwiftClosure<(String?) -> String?>).self
            )
        )
        let returned = try unsafe make.unsafeInvoke(suffix)
        for value: String? in [nil, "", "input", String(repeating: "input", count: 100)] {
            let expected = value.map { $0 + suffix }
            #expect(try unsafe apply.unsafeInvoke(callback, value) == expected)
            #expect(try unsafe returned.unsafeInvoke(value) == expected)
        }
    }

    @Test func memberOwnershipMatchesOrdinaryCalls() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ManagedSwiftFixtures.CollectionStore",
                                                         as: CollectionStore.self)
        let create = try await type.resolve(
            .initializer(
                "init(_:_:)",
                as: (([String], String?) -> CollectionStore).self
            )
        )
        let get = try await type.resolve(.getter("values", as: (() -> [String]).self))
        let set = try await type.resolve(.setter("values", as: (([String]) -> Void).self))
        let title = try await type.resolve(.setter("title", as: ((String?) -> Void).self))
        let append = try await type.resolve(.method("append(_:)", as: ((String) -> [String]).self))
        let long = String(repeating: "member", count: 100)
        let input = [long]
        let receiver = try unsafe create.unsafeInvoke(input, nil)
        #expect(try unsafe get.unsafeInvoke(on: receiver) == input)
        #expect(try unsafe append.unsafeInvoke(on: receiver, "next") == [long, "next"])
        #expect(input == [long])
        try unsafe set.unsafeInvoke(on: receiver, ["replacement"])
        #expect(receiver.values == ["replacement"])
        try unsafe title.unsafeInvoke(on: receiver, long)
        #expect(receiver.title == long)
        try unsafe title.unsafeInvoke(on: receiver, nil)
        #expect(receiver.title == nil)
    }

    @Test func escapingCollectionCallbackKeepsItsCapture() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ManagedSwiftFixtures.CollectionStore",
                                                         as: CollectionStore.self)
        let retain = try await type.resolve(
            .method(
                "retainCallback(_:)",
                as: ((NativeSwiftClosure<([String]) -> [String]>) -> Void).self
            )
        )
        let receiver = CollectionStore([], nil)
        weak var observed: CollectionCapture?
        let value = String(repeating: "captured", count: 100)
        do {
            let capture = CollectionCapture([value])
            observed = capture
            let callback = try NativeSwiftClosure { (input: [String]) in input + capture.values }
            try unsafe retain.unsafeInvoke(on: receiver, callback)
        }
        #expect(observed != nil)
        #expect(receiver.invoke(["input"]) == ["input", value])
        receiver.clear()
        #expect(observed == nil)
    }

    @Test func laterConversionFailureReleasesArrayElements() async throws {
        let runtime = ABIRuntime.shared
        let prototype = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.recordsWithSuffix(_:_:)",
                as: (([ManagedRecord], Int64) -> [ManagedRecord]).self
            )
        )
        let failing = try await runtime.resolve(
            .function(
                prototype.symbol.declaration.name,
                as: (([ManagedRecord], RejectingCollectionArgument) -> [ManagedRecord]).self
            )
        )
        weak var observed: LifetimeToken?
        var destroyed = 0
        do {
            let token = LifetimeToken { destroyed += 1 }
            observed = token
            let input = [ManagedRecord(token: token, number: 42)]
            #expect(throws: CollectionConversionError.self) {
                try unsafe failing.unsafeInvoke(input, RejectingCollectionArgument())
            }
        }
        #expect(observed == nil)
        #expect(destroyed == 1)
    }

    @Test func collectionElementsNeedNoDirectCallRepresentation() throws {
        let nested = try NativeSwiftClosure<([[String?]]) -> [[String?]]> { $0 }
        let input: [[String?]] = [[nil, "value"], []]
        #expect(try unsafe nested.unsafeInvoke(input) == input)
        let records = try NativeSwiftClosure<([ManagedRecord]) -> [ManagedRecord]> { $0 }
        let token = LifetimeToken()
        let result = try unsafe records.unsafeInvoke([ManagedRecord(token: token, number: 7)])
        #expect(result.first?.token === token)
        #expect(result.first?.number == 7)
    }
}
