import ABIBridge
import CoreGraphics
import Foundation
import ObjectiveCFixtures
import Testing

struct CFunctionInvocationTests {
    @Test func zeroNarrowAndBooleanResults() async throws {
        let runtime = ABIRuntime()
        let answer = try await runtime.cFunction(named: "ABICAnswer", as: (() -> Int32).self)
        #expect(try unsafe answer.unsafeInvoke() == ABICAnswer())
        let negative = try await runtime.cFunction(named: "ABICNegative", as: (() -> Int8).self)
        #expect(try unsafe negative.unsafeInvoke() == ABICNegative())
        let negate = try await runtime.cFunction(named: "ABICNegate", as: ((Bool) -> Bool).self)
        #expect(try unsafe negate.unsafeInvoke(false) == ABICNegate(false))
        #expect(try unsafe negate.unsafeInvoke(true) == ABICNegate(true))
    }

    @Test func twelveMixedArguments() async throws {
        let function = try await ABIRuntime.shared.cFunction(
            named: "ABICMixed",
            as: ((Int8, UInt16, Int32, UInt64, Float, Double, Bool, UnsafeRawPointer?,
                  Int64, Double, UInt, Int32) -> Double).self
        )
        var token: Int32 = 0
        try withUnsafePointer(to: &token) { pointer in
            let expected = ABICMixed(-1, 2, 3, 4, 5.5, 6.25, true, pointer, 8, 9.75, 10, 11)
            #expect(expected == 60.5)
            let actual = try unsafe function.unsafeInvoke(
                -1, 2, 3, 4, 5.5, 6.25, true, UnsafeRawPointer(pointer), 8, 9.75, 10, 11
            )
            #expect(actual == expected)
        }
    }

    @Test func importedCValueLayouts() async throws {
        let runtime = ABIRuntime()
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        let rectangle = try await runtime.cFunction(named: "ABICRect", as: ((CGRect) -> CGRect).self)
        #expect(try unsafe rectangle.unsafeInvoke(rect) == ABICRect(rect))
        let point = try await runtime.cFunction(named: "ABICPoint", as: ((CGPoint) -> CGPoint).self)
        #expect(try unsafe point.unsafeInvoke(rect.origin) == ABICPoint(rect.origin))
        let size = try await runtime.cFunction(named: "ABICSize", as: ((CGSize) -> CGSize).self)
        #expect(try unsafe size.unsafeInvoke(rect.size) == ABICSize(rect.size))
        let range = try await runtime.cFunction(named: "ABICRange", as: ((NSRange) -> NSRange).self)
        let interval = NSRange(location: 2, length: 3)
        #expect(try unsafe range.unsafeInvoke(interval) == ABICRange(interval))
    }

    @Test func optionalPointersAndVoidResults() async throws {
        let runtime = ABIRuntime()
        let echo = try await runtime.cFunction(
            named: "ABICPointer",
            as: ((UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<Int32>?).self
        )
        let store = try await runtime.cFunction(
            named: "ABICStore", as: ((UnsafeMutablePointer<Int32>) -> Void).self
        )
        var value: Int32 = 0
        try withUnsafeMutablePointer(to: &value) { pointer in
            #expect(ABICPointer(pointer) == UnsafeMutableRawPointer(pointer))
            #expect(try unsafe echo.unsafeInvoke(pointer) == pointer)
            try unsafe store.unsafeInvoke(pointer)
        }
        #expect(value == 42)
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)
        let nonoptional = try await runtime.cFunction(
            named: "ABICPointer", as: ((UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer).self
        )
        #expect(throws: ABIInvocationError.self) { try unsafe nonoptional.unsafeInvoke(nil) }
    }

    @Test func preparedHandleCanCrossActorsAndBeReused() async throws {
        let function = try await ABIRuntime.shared.cFunction(
            named: "ABICIncrement", as: ((Int32) -> Int32).self
        )
        #expect(ABICIncrement(1) == 2)
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for value in 0..<16 {
                group.addTask { try unsafe function.unsafeInvoke(Int32(value)) }
            }
            var results: Set<Int32> = []
            for try await result in group { results.insert(result) }
            #expect(results == Set(1...16))
        }
    }

    @Test func unsupportedRepresentationsAndMissingNamesThrow() async throws {
        let runtime = ABIRuntime()
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.cFunction(named: "ABICAnswer", as: (() -> String).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.cFunction(named: "ABICAnswer", as: (() -> Int32?).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.cFunction(named: "ABICAnswer", as: ((NSObject) -> Int32).self)
        }
        await #expect(throws: ABIResolutionError.declarationNotFound(.init(name: "ABIAbsentCFunction", language: .c))) {
            _ = try await runtime.cFunction(named: "ABIAbsentCFunction", as: (() -> Void).self)
        }
    }
}
