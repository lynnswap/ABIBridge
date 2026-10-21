import ABIBridge
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

private final class OptionalClosureOwner {}

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
