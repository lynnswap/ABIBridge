import ABIBridge
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

private final class OptionalClosureOwner {}

/// A conformance stating that `OptionalScreenNumber?` passes by address,
/// where Swift passes it in a register.
extension Optional: ABIBridgeSwiftValue where Wrapped == OptionalScreenNumber {
    public static var swiftABIType: NativeType {
        try! .opaque(named: "Optional<OptionalScreenNumber>")
    }
}

struct SwiftOptionalValueTests {
    @Test func optionalValuesPassAsTheirEnumStorage() async throws {
        let runtime = ABIRuntime.shared
        let doubled = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.doubledOptional(_:)",
            as: ((Double?) -> Double?).self
        )
        #expect(try unsafe doubled.unsafeInvoke(1.5) == 3)
        #expect(try unsafe doubled.unsafeInvoke(nil) == nil)
        let inverted = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.invertedOptional(_:)",
            as: ((Bool?) -> Bool?).self
        )
        #expect(try unsafe inverted.unsafeInvoke(true) == false)
        #expect(try unsafe inverted.unsafeInvoke(nil) == nil)
        let nested = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.incrementedNestedOptional(_:)",
            as: ((Int64??) -> Int64??).self
        )
        for value: Int64?? in [.some(.some(41)), .some(.none), .none] {
            #expect(try unsafe nested.unsafeInvoke(value) == incrementedNestedOptional(value))
        }
        let pair = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.swappedOptionalPair(_:)",
            as: (((Int64, Double)?) -> (Double, Int64)?).self
        )
        let swapped = try unsafe pair.unsafeInvoke((7, 0.5))
        #expect(swapped?.0 == 0.5 && swapped?.1 == 7)
        #expect(try unsafe pair.unsafeInvoke(nil) == nil)
    }

    /// Swift passes these Optionals as their enum storage in integer
    /// registers: `UInt32?` in one, `Int64?` and `Double?` as a payload and a
    /// tag byte, `Bool?` in one byte, and a pointer with nil as null.
    @Test func optionalScalarsAndPointersPassByValue() async throws {
        let runtime = ABIRuntime.shared
        let increment = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.incrementedOptionalUInt32(_:)",
            as: ((UInt32?) -> UInt32?).self
        )
        #expect(try unsafe increment.unsafeInvoke(41) == 42)
        #expect(try unsafe increment.unsafeInvoke(.max) == 0)
        #expect(try unsafe increment.unsafeInvoke(nil) == nil)
        let negate = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.negatedOptionalInt64(Swift.Optional<Swift.Int64>)"
                + " -> Swift.Optional<Swift.Int64>",
            as: ((Int64?) -> Int64?).self
        )
        #expect(try unsafe negate.unsafeInvoke(42) == -42)
        #expect(try unsafe negate.unsafeInvoke(nil) == nil)
        let advance = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.advancedOptionalPointer(_:)",
            as: ((UnsafePointer<Int64>?) -> UnsafePointer<Int64>?).self
        )
        let values: [Int64] = [1, 2]
        let next = try values.withUnsafeBufferPointer { buffer in
            try unsafe advance.unsafeInvoke(buffer.baseAddress)?.pointee
        }
        #expect(next == 2)
        #expect(try unsafe advance.unsafeInvoke(nil) == nil)
        let describe = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeOptionalScalars(_:_:_:_:_:)",
            as: ((UInt32?, Int64?, Double?, Bool?, UnsafeRawPointer?) -> String).self
        )
        #expect(try unsafe describe.unsafeInvoke(nil, nil, nil, nil, nil) == "nil,nil,nil,nil,nil")
        let described = try withUnsafePointer(to: Int64(9)) {
            try unsafe describe.unsafeInvoke(7, -1, 2.5, true, UnsafeRawPointer($0))
        }
        #expect(described == "7,-1,2.5,true,9")
    }

    @Test func callbacksExchangeOptionalScalarsAndPointers() async throws {
        typealias Describe = NativeSwiftClosure<
            (UInt32?, Int64?, Double?, Bool?, UnsafeRawPointer?) -> String
        >
        let visit = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitOptionalScalars(_:)",
            as: ((Describe) -> String).self
        )
        let describe = try Describe { id, count, scale, flag, pointer in
            let values = [
                id.map { "\($0)" }, count.map { "\($0)" }, scale.map { "\($0)" },
                flag.map { "\($0)" }, pointer.map { "\($0.load(as: Int64.self))" },
            ]
            return values.map { $0 ?? "nil" }.joined(separator: ",")
        }
        let visited = try unsafe visit.unsafeInvoke(describe)
        #expect(visited == "nil,nil,nil,nil,nil|4000000000,-5,0.5,false,7")
        let make = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalScalarDescriber()",
            as: (() -> Describe).self
        )
        let native = try unsafe make.unsafeInvoke()
        #expect(try unsafe native.unsafeInvoke(nil, nil, nil, nil, nil) == "nil,nil,nil,nil,nil")
        let described = try withUnsafePointer(to: Int64(3)) {
            try unsafe native.unsafeInvoke(1, 2, 0.25, true, UnsafeRawPointer($0))
        }
        #expect(described == "1,2,0.25,true,3")
    }

    /// The shape of SimulatorKit's `register(screenID:queue:handler:)`, where
    /// nil selects every screen.
    @Test func methodsTakeAnOptionalScalarBeforeOtherArguments() async throws {
        typealias Handler = NativeSwiftClosure<(UInt32?) -> Void>
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "ManagedSwiftFixtures.OptionalScreenAdapter",
            as: OptionalScreenAdapter.self
        )
        let register = try await type.resolveMethod(
            named: "register(screenID:queue:handler:)",
            as: ((UInt32?, DispatchQueue, Handler) -> OptionalScreenAdapter.Registration).self
        )
        let adapter = OptionalScreenAdapter(screens: [1, 2])
        let queue = DispatchQueue(label: "OptionalScreenAdapter")
        let screens = Mutex<[UInt32?]>([])
        let handler = try Handler { screen in screens.withLock { $0.append(screen) } }
        let all = try unsafe register.unsafeInvoke(on: adapter, nil, queue, handler)
        #expect(all.screenID == nil)
        let second = try unsafe register.unsafeInvoke(on: adapter, 2, queue, handler)
        #expect(second.screenID == 2)
        #expect(screens.withLock { $0 } == [1, 2, 2])
    }

    /// Swift passes an Optional as its enum storage whatever ABI describes it,
    /// so an explicit ABI must pass the same way.
    @Test func explicitOptionalABIsMustPassAsTheOptional() async throws {
        let runtime = ABIRuntime.shared
        let optional = try await runtime.resolveSwiftType(
            named: "Swift.Optional",
            genericArguments: [.type(UInt32.self)]
        )
        let name = "ManagedSwiftFixtures.incrementedOptionalUInt32(_:)"
        let increment = try await runtime.resolveSwiftFunction(
            named: name,
            as: ((UInt32?) -> UInt32?).self,
            valueABIs: [
                optional: try .structure(named: "Optional<UInt32>", fields: [.uint32, .uint8])
            ]
        )
        #expect(try unsafe increment.unsafeInvoke(41) == 42)
        #expect(try unsafe increment.unsafeInvoke(nil) == nil)
        // By address or in a floating-point register, the callee would read
        // another value from x0.
        for abi in [
            try NativeType.opaque(named: "Optional<UInt32>"),
            try .structure(named: "Optional<UInt32>", fields: [.float, .uint8]),
        ] {
            await #expect {
                _ = try await runtime.resolveSwiftFunction(
                    named: name,
                    as: ((UInt32?) -> UInt32?).self,
                    valueABIs: [optional: abi]
                )
            } throws: { Self.rejectsExplicitABI($0, statedBy: "The valueABIs entry") }
        }
        // The payload's entry decides the Optional's own storage.
        var abis = try await Self.recordABIs()
        let frozenOptional = try await runtime.resolveSwiftType(
            named: "Swift.Optional",
            genericArguments: [.type(OptionalFrozenRecord.self)]
        )
        abis[frozenOptional] = try .opaque(named: "Optional<OptionalFrozenRecord>")
        await #expect {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.describeOptionalFrozenRecord(_:)",
                as: ((OptionalFrozenRecord?) -> String).self,
                valueABIs: abis
            )
        } throws: { Self.rejectsExplicitABI($0, statedBy: "The valueABIs entry") }
        // A conformance is checked the same way.
        await #expect {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.nextOptionalScreenNumber(_:)",
                as: ((OptionalScreenNumber?) -> OptionalScreenNumber?).self
            )
        } throws: { Self.rejectsExplicitABI($0, statedBy: "The ABIBridgeSwiftValue conformance") }
    }

    /// Without an established payload convention, an Optional's explicit ABI
    /// states its convention unchecked, also when an entry describes part of
    /// the payload.
    @Test func explicitABIsStateOptionalsWithUndecidedPayloads() async throws {
        let runtime = ABIRuntime.shared
        typealias Payload = (UInt32, OptionalScreenBox<Int64>)
        let optional = try await runtime.resolveSwiftType(
            named: "Swift.Optional",
            genericArguments: [.type(Payload.self)]
        )
        let uint32 = try await runtime.resolveSwiftType(named: "Swift.UInt32")
        let abi = try NativeType.structure(
            named: "Optional<Payload>",
            fields: [.uint64, .int64, .uint8]
        )
        // The UInt32 entry makes ABIBridge read the tuple's other element.
        for entries: [NativeSwiftType: NativeType] in [[:], [uint32: .uint32]] {
            let describe = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.describeOptionalScreenBox(_:)",
                as: ((Payload?) -> String).self,
                valueABIs: entries.merging([optional: abi]) { $1 }
            )
            #expect(try unsafe describe.unsafeInvoke((7, OptionalScreenBox(5))) == "7:5")
            #expect(try unsafe describe.unsafeInvoke(nil) == "nil")
        }
    }

    /// receiverABI for an Optional self must pass as the declaration passes
    /// self, which can differ from the Optional's own storage.
    @Test func optionalReceiverABIsFollowTheDeclaredSelf() async throws {
        let type = try await ABIRuntime.shared.resolveSwiftType(
            named: "Swift.Optional",
            as: UInt32?.self,
            genericArguments: [.type(UInt32.self)]
        )
        let opaque = try NativeType.opaque(named: "Optional<UInt32>")
        // A generic extension's method takes self by address.
        for receiverABI in [nil, opaque] {
            let size = try await type.resolveMethod(
                named: "optionalPayloadSize()",
                as: (() -> Int64).self,
                receiverABI: receiverABI
            )
            #expect(try unsafe size.unsafeInvoke(on: UInt32?(7)) == 4)
            #expect(try unsafe size.unsafeInvoke(on: UInt32?.none) == -1)
        }
        // A concrete self passes as the Optional's storage.
        let screenID = try await type.resolveMethod(
            named: "screenIDOrMinusOne()",
            as: (() -> Int64).self
        )
        #expect(try unsafe screenID.unsafeInvoke(on: UInt32?(7)) == 7)
        #expect(try unsafe screenID.unsafeInvoke(on: UInt32?.none) == -1)
        await #expect {
            _ = try await type.resolveMethod(
                named: "screenIDOrMinusOne()",
                as: (() -> Int64).self,
                receiverABI: opaque
            )
        } throws: { Self.rejectsExplicitABI($0, statedBy: "receiverABI") }
        // A mutating method or setter takes self by address.
        let advance = try await type.resolveMethod(
            named: "advanceScreenID()",
            as: (() -> Void).self,
            receiverABI: opaque,
            mutating: true
        )
        let setScreenID = try await type.resolveSetter(
            named: "screenIDValue",
            as: Int64.self,
            receiverABI: opaque
        )
        var screen: UInt32? = 7
        try unsafe advance.unsafeInvoke(on: &screen)
        #expect(screen == 8)
        try unsafe setScreenID.unsafeInvoke(on: &screen, -1)
        #expect(screen == nil)
        try unsafe setScreenID.unsafeInvoke(on: &screen, 3)
        #expect(screen == 3)
    }

    private static func rejectsExplicitABI(_ error: any Error, statedBy source: String) -> Bool {
        guard case ABIResolutionError.unsupportedDeclaration(let message) = error else {
            return false
        }
        return message.contains(source + " for Swift.Optional<")
    }

    /// Runtime-only records and the ABIs their declarations use. Library
    /// evolution hides whether these String-holding records are frozen, and
    /// Optional payloads need that answer, so they keep explicit ABIs.
    private static func recordABIs() async throws -> [NativeSwiftType: NativeType] {
        let runtime = ABIRuntime.shared
        let record = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.OptionalRuntimeRecord")
        let frozen = try await runtime.resolveSwiftType(named: "ManagedSwiftFixtures.OptionalFrozenRecord")
        return [
            record: try .opaque(named: record.name),
            frozen: try .structure(named: "OptionalFrozenRecord", fields: [.uint64, .uint64, .int64]),
        ]
    }

    @Test func optionalRuntimeValuesPassAsOptionalHandles() async throws {
        let runtime = ABIRuntime.shared
        let abis = try await Self.recordABIs()
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalRuntimeRecord(_:)",
            as: ((Int64) -> NativeSwiftValue?).self,
            valueABIs: abis
        )
        #expect(try unsafe make.unsafeInvoke(-1) == nil)
        let record = try #require(try unsafe make.unsafeInvoke(3))
        #expect(try record.withCopy { ($0 as? OptionalRuntimeRecord)?.count } == 3)
        let describe = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeOptionalRuntimeRecord(_:)",
            as: ((NativeSwiftValue?) -> String).self,
            valueABIs: abis
        )
        #expect(try unsafe describe.unsafeInvoke(nil) == "nil")
        #expect(try unsafe describe.unsafeInvoke(record) == "record#3")
        let describeBorrowed = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeOptionalRuntimeRecord(_:)",
            as: ((NativeSwiftBorrowedValue?) -> String).self,
            valueABIs: abis
        )
        #expect(try record.withBorrowedValue { try unsafe describeBorrowed.unsafeInvoke($0) } == "record#3")
        #expect(try unsafe describeBorrowed.unsafeInvoke(nil) == "nil")
        // A consuming parameter takes the handle's value.
        let bump = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.bumpOptionalRuntimeRecord(_:)",
            as: ((NativeSwiftConsuming<NativeSwiftValue?>) -> NativeSwiftValue?).self,
            valueABIs: abis
        )
        #expect(try unsafe bump.unsafeInvoke(NativeSwiftConsuming(nil)) == nil)
        #expect(!record.isConsumed)
        let bumped = try #require(try unsafe bump.unsafeInvoke(NativeSwiftConsuming(record)))
        #expect(record.isConsumed)
        #expect(try unsafe describe.unsafeInvoke(bumped) == "record#4")

        // A frozen payload makes the Optional a direct value.
        let makeFrozen = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalFrozenRecord(_:)",
            as: ((Int64) -> NativeSwiftValue?).self,
            valueABIs: abis
        )
        let describeFrozen = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeOptionalFrozenRecord(_:)",
            as: ((NativeSwiftValue?) -> String).self,
            valueABIs: abis
        )
        #expect(try unsafe makeFrozen.unsafeInvoke(-1) == nil)
        let frozen = try #require(try unsafe makeFrozen.unsafeInvoke(5))
        #expect(try unsafe describeFrozen.unsafeInvoke(frozen) == "frozen#5")
        #expect(try unsafe describeFrozen.unsafeInvoke(nil) == "nil")

        // The value must have the wrapped type, and the declaration an Optional,
        // including an opaque result's underlying type.
        #expect(throws: ABIInvocationError.self) { try unsafe describe.unsafeInvoke(frozen) }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.compatibilityOpaqueCount()",
                as: (() -> NativeSwiftValue?).self
            )
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.makeOptionalRuntimeRecord(Swift.Int64) -> Swift.Optional<ManagedSwiftFixtures.OptionalRuntimeRecord>",
                as: ((NativeSwiftValue?) -> NativeSwiftValue?).self,
                valueABIs: abis
            )
        }
    }

    /// A host Optional takes its payload's valueABIs entry, as a runtime
    /// Optional does, also as a tuple element.
    @Test func hostOptionalsUseTheirPayloadValueABIs() async throws {
        let runtime = ABIRuntime.shared
        let abis = try await Self.recordABIs()
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalFrozenRecord(_:)",
            as: ((Int64) -> OptionalFrozenRecord?).self,
            valueABIs: abis
        )
        let describe = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeOptionalFrozenRecord(_:)",
            as: ((OptionalFrozenRecord?) -> String).self,
            valueABIs: abis
        )
        #expect(try unsafe make.unsafeInvoke(-1) == nil)
        let frozen = try #require(try unsafe make.unsafeInvoke(5))
        #expect(frozen.name == "frozen" && frozen.count == 5)
        #expect(try unsafe describe.unsafeInvoke(frozen) == "frozen#5")
        #expect(try unsafe describe.unsafeInvoke(nil) == "nil")

        // The opaque ABI of the resilient record passes its Optional by address.
        let makeRecord = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalRuntimeRecord(_:)",
            as: ((Int64) -> OptionalRuntimeRecord?).self,
            valueABIs: abis
        )
        let describeRecord = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeOptionalRuntimeRecord(_:)",
            as: ((OptionalRuntimeRecord?) -> String).self,
            valueABIs: abis
        )
        #expect(try unsafe makeRecord.unsafeInvoke(-1) == nil)
        #expect(try unsafe describeRecord.unsafeInvoke(makeRecord.unsafeInvoke(3)) == "record#3")
        #expect(try unsafe describeRecord.unsafeInvoke(nil) == "nil")

        let makePair = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalFrozenRecordPair(_:)",
            as: ((Int64) -> (OptionalFrozenRecord?, Int64)).self,
            valueABIs: abis
        )
        let describePair = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeOptionalFrozenRecordPair(_:)",
            as: (((OptionalFrozenRecord?, Int64)) -> String).self,
            valueABIs: abis
        )
        let pair = try unsafe makePair.unsafeInvoke(6)
        #expect(pair.0?.count == 6 && pair.1 == 6)
        #expect(try unsafe describePair.unsafeInvoke(pair) == "frozen#6@6")
        #expect(try unsafe describePair.unsafeInvoke((nil, 2)) == "nil@2")

        // A tuple payload's element takes its entry too.
        let makeTuple = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalRuntimeRecordTuple(_:)",
            as: ((Int64) -> (OptionalRuntimeRecord, Int64)?).self,
            valueABIs: abis
        )
        let describeTuple = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeOptionalRuntimeRecordTuple(_:)",
            as: (((OptionalRuntimeRecord, Int64)?) -> String).self,
            valueABIs: abis
        )
        #expect(try unsafe makeTuple.unsafeInvoke(-1) == nil)
        let tuple = try #require(try unsafe makeTuple.unsafeInvoke(4))
        #expect(tuple.0.name == "record" && tuple.0.count == 4 && tuple.1 == 5)
        #expect(try unsafe describeTuple.unsafeInvoke(tuple) == "record#4@5")
        #expect(try unsafe describeTuple.unsafeInvoke(nil) == "nil")
    }

    @Test func callbacksExchangeOptionalRuntimeValues() async throws {
        let abis = try await Self.recordABIs()
        let visit = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitOptionalRuntimeRecords(_:)",
            as: ((NativeSwiftClosure<(NativeSwiftValue?) throws -> NativeSwiftValue?>) throws -> String).self,
            valueABIs: abis
        )
        let counts = Mutex<[Int64?]>([])
        // Each input is an independent value the callback can return.
        let identity = try NativeSwiftClosure<(NativeSwiftValue?) throws -> NativeSwiftValue?> { value in
            let count = try value?.withCopy { ($0 as? OptionalRuntimeRecord)?.count }
            counts.withLock { $0.append(count) }
            return value
        }
        #expect(try unsafe visit.unsafeInvoke(identity) == "nil,visit#1")
        #expect(counts.withLock { $0 } == [nil, 1])
        let make = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalRuntimeRecord(_:)",
            as: ((Int64) -> NativeSwiftValue?).self,
            valueABIs: abis
        )
        let swapped = try NativeSwiftClosure<(NativeSwiftValue?) throws -> NativeSwiftValue?> { value in
            value == nil ? try unsafe make.unsafeInvoke(9) : nil
        }
        #expect(try unsafe visit.unsafeInvoke(swapped) == "record#9,nil")

        // Ownership wrappers and borrowed inputs receive the payload or nil too.
        let wrapped = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitOptionalRuntimeRecords(_:)",
            as: ((NativeSwiftClosure<(NativeSwiftBorrowing<NativeSwiftValue?>) throws -> NativeSwiftValue?>) throws
                -> String).self,
            valueABIs: abis
        )
        let unwrapped = try NativeSwiftClosure<(NativeSwiftBorrowing<NativeSwiftValue?>) throws -> NativeSwiftValue?> {
            $0.value
        }
        #expect(try unsafe wrapped.unsafeInvoke(unwrapped) == "nil,visit#1")
        let borrowing = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitOptionalRuntimeRecords(_:)",
            as: ((NativeSwiftClosure<(NativeSwiftBorrowedValue?) throws -> NativeSwiftValue?>) throws -> String).self,
            valueABIs: abis
        )
        let copied = try NativeSwiftClosure<(NativeSwiftBorrowedValue?) throws -> NativeSwiftValue?> { try $0?.copy() }
        #expect(try unsafe borrowing.unsafeInvoke(copied) == "nil,visit#1")
    }

    @Test func aGenericParameterCanBindTheOptionalHandleItself() async throws {
        let echo = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.echoGeneric(_:)",
            as: ((NativeSwiftValue?) -> NativeSwiftValue?).self,
            genericArguments: [.type(NativeSwiftValue?.self)]
        )
        let make = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalRuntimeRecord(_:)",
            as: ((Int64) -> NativeSwiftValue?).self,
            valueABIs: try await Self.recordABIs()
        )
        let record = try #require(try unsafe make.unsafeInvoke(2))
        #expect(try unsafe echo.unsafeInvoke(record) === record)
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)
    }

    @Test func optionalClosuresUseANullFunctionForNil() async throws {
        let runtime = ABIRuntime.shared
        let apply = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.applyOptionalClosure(_:_:)",
            as: ((NativeSwiftClosure<(Int64) -> Int64>?, Int64) -> Int64).self
        )
        let tripled = try NativeSwiftClosure<(Int64) -> Int64> { $0 * 3 }
        #expect(try unsafe apply.unsafeInvoke(tripled, 5) == 15)
        #expect(try unsafe apply.unsafeInvoke(nil, 5) == -1)
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalClosure(_:)",
            as: ((Bool) -> NativeSwiftClosure<(Int64) -> Int64>?).self
        )
        #expect(try unsafe make.unsafeInvoke(false) == nil)
        let increment = try #require(try unsafe make.unsafeInvoke(true))
        #expect(try unsafe increment.unsafeInvoke(41) == 42)
        // Native code passes nil and a closure to the host callback.
        let pass = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.passOptionalClosures(_:)",
            as: ((NativeSwiftClosure<(NativeSwiftClosure<(Int64) -> Int64>?) -> Int64>) -> Int64).self
        )
        let callback = try NativeSwiftClosure<(NativeSwiftClosure<(Int64) -> Int64>?) -> Int64> { body in
            guard let body else { return 7 }
            return (try? unsafe body.unsafeInvoke(4)) ?? -2
        }
        #expect(try unsafe pass.unsafeInvoke(callback) == 740)
        // A returned closure returns an Optional closure.
        let factory = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeOptionalClosureFactory()",
            as: (() -> NativeSwiftClosure<() -> NativeSwiftClosure<() -> Int64>?>).self
        )
        let produce = try unsafe factory.unsafeInvoke()
        let seven = try #require(try unsafe produce.unsafeInvoke())
        #expect(try unsafe seven.unsafeInvoke() == 7)
    }

    @Test func reabstractedClosuresPassANilOptionalClosureThrough() async throws {
        typealias Checker = NativeSwiftClosure<(Int64, NativeSwiftClosure<(Int64) -> Int64>?) -> Int64>
        let make = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeGenericOptionalChecker(_:)",
            as: ((Int64.Type) -> Checker).self,
            genericArguments: [.type(Int64.self)]
        )
        let check = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.checkNilOptionalClosure(_:)",
            as: ((Checker) -> Int64).self
        )
        // The generic closure is adapted for the concrete consumer.
        #expect(try unsafe check.unsafeInvoke(make.unsafeInvoke(Int64.self)) == -1)
    }

    @Test func nilClosureStorageReleasesAClosureStoredThroughInout() async throws {
        let replace = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.replaceOptionalClosure(_:_:)",
            as: ((NativeSwiftInout<NativeSwiftClosure<(Int64) -> Int64>?>, AnyObject) -> Void).self
        )
        weak var released: OptionalClosureOwner?
        do {
            let owner = OptionalClosureOwner()
            released = owner
            let buffer = NativeSwiftInout<NativeSwiftClosure<(Int64) -> Int64>?>(nil)
            try unsafe replace.unsafeInvoke(buffer, owner)
            #expect(try unsafe buffer.value?.unsafeInvoke(1) == 2)
        }
        #expect(released == nil)
    }

    @Test func nilClosureWritebackKeepsTheUnspecifiedContext() async throws {
        typealias Increment = NativeSwiftClosure<(Int64) -> Int64>
        let pass = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.passStaleNilClosure(_:_:)",
            as: ((NativeSwiftClosure<(NativeSwiftInout<Increment?>) throws -> Void>, AnyObject) throws -> Bool).self
        )
        let owner = NSObject()
        let retainCount = CFGetRetainCount(owner)
        let unchanged = try NativeSwiftClosure<(NativeSwiftInout<Increment?>) throws -> Void> { _ in }
        #expect(try unsafe pass.unsafeInvoke(unchanged, owner))
        #expect(CFGetRetainCount(owner) == retainCount)
    }

    @Test func optionalsKeepTheirOwnPassingConvention() async throws {
        let runtime = ABIRuntime.shared
        // The tuple alone needs five registers, but its Optional is three words.
        let first = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.firstOptionalFloat(_:)",
            as: (((Float, Float, Float, Float, Float)?) -> Float).self
        )
        #expect(try unsafe first.unsafeInvoke((1, 2, 3, 4, 5)) == 1)
        #expect(try unsafe first.unsafeInvoke(nil) == -1)
        // Thin metatypes and nested closure Optionals have other representations.
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.areOptionalMetatypesNil(_:)",
                as: (((Int.Type, Int.Type)?) -> Bool).self
            )
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.applyNestedOptionalClosure(_:)",
                as: ((NativeSwiftClosure<(Int64) -> Int64>??) -> Int64).self
            )
        }
        // An Optional handle cannot stand for a required closure.
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.applyEscapingClosure(_:)",
                as: ((NativeSwiftClosure<(Int64) -> Int64>?) -> Int64).self
            )
        }
        // A runtime value of an Optional closure needs a stored closure plan (#427).
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.makeOptionalClosure(_:)",
                as: ((Bool) -> NativeSwiftValue).self
            )
        }
        // Generic closure Optionals need reabstraction that keeps nil (#408).
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.applyGenericOptionalClosure(_:_:)",
                as: ((NativeSwiftClosure<(Int64) -> Int64>?, Int64) -> Int64).self,
                genericArguments: [.type(Int64.self)]
            )
        }
    }
}
