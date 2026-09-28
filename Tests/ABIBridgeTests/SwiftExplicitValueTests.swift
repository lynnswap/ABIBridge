import ABIBridge
import ManagedSwiftFixtures
import Testing

extension ManagedVector: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "ManagedVector", fields: [.pointer, .double, .double])
    }
}
extension ManagedChoice: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "ManagedChoice", fields: Array(repeating: .uint, count: MemoryLayout<Int64>.size / MemoryLayout<UInt>.size) + [.uint8])
    }
}
extension LargeManagedValue: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType {
        try! .structure(named: "LargeManagedValue", fields: [.pointer, .int64, .int64, .int64, .int64])
    }
}

private struct UndersizedSwiftValue: ABIBridgeSwiftValue {
    let first, second: Int64
    static var swiftABIType: NativeType { .int64 }
}

struct SwiftExplicitValueTests {
    @Test func directManagedStructUsesMixedRegistersAndOwnedResults() async throws {
        let transform = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.transformManagedVector(_:)",
            as: ((ManagedVector) -> ManagedVector).self
        )
        weak var observed: LifetimeToken?
        var destroyed = 0
        var result: ManagedVector?
        do {
            let token = LifetimeToken { destroyed += 1 }
            observed = token
            let input = ManagedVector(token: token, x: 1.5, y: 2.5)
            result = try unsafe transform.unsafeInvoke(input)
            #expect(result?.token === token)
            #expect(result?.x == 2.5 && result?.y == 4.5)
        }
        withExtendedLifetime(result) {
            #expect(observed != nil)
            #expect(destroyed == 0)
        }
        result = nil
        #expect(observed == nil)
        #expect(destroyed == 1)
    }

    @Test func enumPayloadsKeepTagsAndReferences() async throws {
        let echo = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.echoManagedChoice(_:)", as: ((ManagedChoice) -> ManagedChoice).self
        )
        let number = try unsafe echo.unsafeInvoke(.number(-42))
        if case .number(let value) = number { #expect(value == -42) } else { Issue.record("Lost number tag") }
        let empty = try unsafe echo.unsafeInvoke(.empty)
        if case .empty = empty {} else { Issue.record("Lost empty tag") }
        weak var observed: LifetimeToken?
        var result: ManagedChoice?
        do {
            let token = LifetimeToken()
            observed = token
            result = try unsafe echo.unsafeInvoke(.token(token))
            if case .token(let actual) = result { #expect(actual === token) } else { Issue.record("Lost reference tag") }
        }
        withExtendedLifetime(result) { #expect(observed != nil) }
        result = nil
        #expect(observed == nil)
    }

    @Test func largeManagedValueUsesIndirectPhysicalStorage() async throws {
        let echo = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.echoLargeManagedValue(_:)",
            as: ((LargeManagedValue) -> LargeManagedValue).self
        )
        let token = LifetimeToken()
        let input = LargeManagedValue(token: token, a: 1, b: 2, c: 3, d: 4)
        let result = try unsafe echo.unsafeInvoke(input)
        #expect(result.token === token)
        #expect(result.a == 1 && result.b == 2 && result.c == 3 && result.d == 4)
        let apply = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.applyLargeManagedValue(_:_:)",
            as: ((NativeSwiftClosure<LargeManagedValue, LargeManagedValue>, LargeManagedValue) -> LargeManagedValue).self
        )
        let callback = try NativeSwiftClosure<LargeManagedValue, LargeManagedValue> { $0 }
        let returned = try unsafe apply.unsafeInvoke(callback, input)
        #expect(returned.token === token && returned.d == 4)
    }

    @Test func managedCallbacksUseTypedCopyingAndResultTransfer() async throws {
        let apply = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.applyManagedVector(_:_:)",
            as: ((NativeSwiftClosure<ManagedVector, ManagedVector>, ManagedVector) -> ManagedVector).self
        )
        let callback = try NativeSwiftClosure { (value: ManagedVector) in
            ManagedVector(token: value.token, x: value.x + 10, y: value.y + 20)
        }
        let token = LifetimeToken()
        let input = ManagedVector(token: token, x: 1, y: 2)
        let result = try unsafe apply.unsafeInvoke(callback, input)
        #expect(result.token === token && result.x == 11 && result.y == 22)
        let make = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeManagedVectorClosure(_:)",
            as: ((Double) -> NativeSwiftClosure<ManagedVector, ManagedVector>).self
        )
        let returned = try unsafe make.unsafeInvoke(5)
        let nativeResult = try unsafe returned.unsafeInvoke(input)
        #expect(nativeResult.token === token && nativeResult.x == 6 && nativeResult.y == 7)
    }

    @Test func enumCallbacksAndReturnedClosuresPreserveCases() async throws {
        let apply = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.applyManagedChoice(_:_:)",
            as: ((NativeSwiftClosure<ManagedChoice, ManagedChoice>, ManagedChoice) -> ManagedChoice).self
        )
        let callback = try NativeSwiftClosure<ManagedChoice, ManagedChoice> { $0 }
        let make = try await ABIRuntime.shared.swiftFunction(
            named: "ManagedSwiftFixtures.makeManagedChoiceClosure()",
            as: (() -> NativeSwiftClosure<ManagedChoice, ManagedChoice>).self
        )
        let returned = try unsafe make.unsafeInvoke()
        weak var observed: LifetimeToken?
        var result: ManagedChoice?
        do {
            let token = LifetimeToken()
            observed = token
            result = try unsafe returned.unsafeInvoke(apply.unsafeInvoke(callback, .token(token)))
            if case .token(let actual) = result { #expect(actual === token) } else { Issue.record("Lost reference tag") }
        }
        withExtendedLifetime(result) { #expect(observed != nil) }
        result = nil
        #expect(observed == nil)
        if case .empty = try unsafe returned.unsafeInvoke(.empty) {} else { Issue.record("Lost empty tag") }
        if case .number(let value) = try unsafe apply.unsafeInvoke(callback, .number(42)) {
            #expect(value == 42)
        } else { Issue.record("Lost number tag") }
    }

    @Test func memberInitializationAndSetterTransferOwnedEnumPayloads() async throws {
        let type = try await ABIRuntime.shared.swiftType(named: "ManagedSwiftFixtures.ExplicitValueStore",
                                                         as: ExplicitValueStore.self)
        let create = try await type.initializer(named: "init(_:)", as: ((ManagedChoice) -> ExplicitValueStore).self)
        let get = try await type.getter(named: "value", as: ManagedChoice.self)
        let set = try await type.setter(named: "value", as: ManagedChoice.self)
        var receiver: ExplicitValueStore?
        weak var observed: LifetimeToken?
        do {
            let token = LifetimeToken()
            observed = token
            receiver = try unsafe create.unsafeInvoke(.token(token))
        }
        let object = try #require(receiver)
        if case .token = try unsafe get.unsafeInvoke(on: object) {} else { Issue.record("Lost stored token") }
        #expect(observed != nil)
        try unsafe set.unsafeInvoke(on: object, .empty)
        #expect(observed == nil)
        receiver = nil
    }

    @Test func invalidStorageExtentFailsBeforePublishingACallback() {
        #expect(throws: ABIResolutionError.self) {
            _ = try NativeSwiftClosure<UndersizedSwiftValue, UndersizedSwiftValue> { $0 }
        }
    }
}
