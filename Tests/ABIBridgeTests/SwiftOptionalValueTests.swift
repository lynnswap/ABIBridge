import ABIBridge
import ManagedSwiftFixtures
import Testing

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
    }
}
