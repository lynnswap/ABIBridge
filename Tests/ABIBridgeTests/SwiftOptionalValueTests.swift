import ABIBridge
import ManagedSwiftFixtures
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
        // A runtime value wrapper's reference is not the native payload.
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.doubledOptional(Swift.Optional<Swift.Double>) -> Swift.Optional<Swift.Double>",
                as: ((NativeSwiftValue?) -> Double?).self
            )
        }
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
    }
}
