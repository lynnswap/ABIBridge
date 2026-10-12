import ABIBridge
import ABIBridgeTestSupport
import CoreGraphics
import Foundation
import ObjectiveCFixtures
import Testing

@_cdecl("ABICWeightedTwentyArguments")
public func cWeightedTwentyArguments(
    _ a0: Int32,
    _ a1: Int32,
    _ a2: Int32,
    _ a3: Int32,
    _ a4: Int32,
    _ a5: Int32,
    _ a6: Int32,
    _ a7: Int32,
    _ a8: Int32,
    _ a9: Int32,
    _ a10: Int32,
    _ a11: Int32,
    _ a12: Int32,
    _ a13: Int32,
    _ a14: Int32,
    _ a15: Int32,
    _ a16: Int32,
    _ a17: Int32,
    _ a18: Int32,
    _ a19: Int32
) -> Int32 {
    let values = [
        a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19,
    ]
    return values.enumerated().reduce(Int32(0)) { $0 + $1.element * Int32($1.offset + 1) }
}

struct CFunctionInvocationTests {
    #if os(macOS)
    @MainActor @Test(arguments: [false, true], [false, true])
    func asynchronousFactoriesAcquireColdImagesAwayFromMainActor(
        cxx: Bool,
        dynamic: Bool
    ) async throws {
        let fixture = try FixtureLibrary(
            load: false,
            cxxSource: """
                #include <pthread.h>
                static int initializedOnMainThread = -1;
                __attribute__((constructor)) static void initialize() {
                    initializedOnMainThread = pthread_main_np();
                }
                extern "C" int ABIFactoryAdd(int first, int second) {
                    return first + second + initializedOnMainThread;
                }
                namespace ABIFactory {
                int add(int first, int second) {
                    return first + second + initializedOnMainThread;
                }
                }
                """
        )
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(fixture.libraryURL)
        let name = cxx ? "ABIFactory::add(int, int)" : "ABIFactoryAdd"
        if dynamic {
            let signature = NativeSignature(parameters: [.int32, .int32], returns: .int32)
            let function: DynamicNativeFunction
            if cxx {
                function = try await runtime.resolveCXXFunction(
                    named: name,
                    signature: signature,
                    in: scope
                )
            } else {
                function = try await runtime.resolveCFunction(
                    named: name,
                    signature: signature,
                    in: scope
                )
            }
            let arguments = [
                try NativeValue(copying: Int32(19), as: .int32),
                try NativeValue(copying: Int32(23), as: .int32),
            ]
            #expect(try unsafe function.unsafeInvoke(with: arguments).read(as: Int32.self) == 42)
            let retained: DynamicNativeFunction
            if cxx {
                retained = try await runtime.resolveCXXFunction(
                    named: name,
                    signature: signature,
                    in: function.symbol.image
                )
            } else {
                retained = try await runtime.resolveCFunction(
                    named: name,
                    signature: signature,
                    in: function.symbol.image
                )
            }
            #expect(try unsafe retained.unsafeInvoke(with: arguments).read(as: Int32.self) == 42)
        } else {
            let function: NativeFunction<Int32, Int32, Int32>
            if cxx {
                function = try await runtime.resolveCXXFunction(
                    named: name,
                    as: ((Int32, Int32) -> Int32).self,
                    in: scope
                )
            } else {
                function = try await runtime.resolveCFunction(
                    named: name,
                    as: ((Int32, Int32) -> Int32).self,
                    in: scope
                )
            }
            #expect(try unsafe function.unsafeInvoke(19, 23) == 42)
            let retained: NativeFunction<Int32, Int32, Int32>
            if cxx {
                retained = try await runtime.resolveCXXFunction(
                    named: name,
                    as: ((Int32, Int32) -> Int32).self,
                    in: function.symbol.image
                )
            } else {
                retained = try await runtime.resolveCFunction(
                    named: name,
                    as: ((Int32, Int32) -> Int32).self,
                    in: function.symbol.image
                )
            }
            #expect(try unsafe retained.unsafeInvoke(19, 23) == 42)
        }
        MainActor.assertIsolated()
    }
    #endif

    @Test func twentyFixedArgumentsPreserveValuesAndOrder() async throws {
        let call = try ABIRuntime().resolveCFunctionAndWait(
            named: "ABICWeightedTwentyArguments",
            as: ((
                Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
                Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32
            ) -> Int32).self
        )
        #expect(
            try unsafe call.unsafeInvoke(
                1,
                2,
                3,
                4,
                5,
                6,
                7,
                8,
                9,
                10,
                11,
                12,
                13,
                14,
                15,
                16,
                17,
                18,
                19,
                20
            ) == 2870
        )
    }

    @Test func twentyVariadicFloatsPreserveDefaultPromotions() async throws {
        let signature = NativeSignature(
            parameters: [.int32],
            variadicParameters: Array(repeating: .float, count: 20),
            returns: .double
        )
        let call = try ABIRuntime().resolveCFunctionAndWait(
            named: "ABICVariadicSum",
            signature: signature
        )
        let values =
            [try NativeValue(copying: Int32(20), as: .int32)]
            + (try (1...20).map { try NativeValue(copying: Float($0), as: .float) })
        #expect(try unsafe call.unsafeInvoke(with: values).read(as: Double.self) == 210)
    }

    @Test func wideAggregateResultsPreserveEveryField() async throws {
        let result = try NativeType.structure(
            named: "ABICWideResult",
            fields: Array(repeating: .uint64, count: 12)
        )
        let call = try ABIRuntime().resolveCFunctionAndWait(
            named: "ABICMakeWideResult",
            signature: .init(parameters: [.uint64], returns: result)
        )
        let value = try unsafe call.unsafeInvoke(with: [try .init(copying: UInt64(40), as: .uint64)]
        )
        for index in 0..<12 {
            #expect(
                try unsafe value.read(as: UInt64.self, at: index * MemoryLayout<UInt64>.stride)
                    == 40 + UInt64(index * index)
            )
        }
    }

    @Test func variadicPromotionsMatchNativeCalls() async throws {
        let call = try ABIRuntime().resolveCFunctionAndWait(
            named: "ABICVariadicMix",
            as: ((Float, Int32, Int8, UInt16, Bool, Float, UnsafeRawPointer?, CGPoint) -> Double)
                .self,
            variadicFrom: 2
        )
        let point = CGPoint(x: 2, y: 3)
        var token = Int32(0)
        try withUnsafePointer(to: &token) { pointer in
            let expected = ABICVariadicMixOracle(4, 6, -8, 65500, true, 1.5, pointer, point)
            let actual = try unsafe call.unsafeInvoke(4, 6, -8, 65500, true, 1.5, pointer, point)
            #expect(actual == expected)
        }
    }

    @Test func variadicEmptyAndStackTailsKeepTheirCallingConvention() async throws {
        let runtime = ABIRuntime()
        let empty = try runtime.resolveCFunctionAndWait(
            named: "ABICVariadicSum",
            as: ((Int32) -> Double).self,
            variadicFrom: 1
        )
        #expect(try unsafe empty.unsafeInvoke(0) == 0)
        let stack = try runtime.resolveCFunctionAndWait(
            named: "ABICVariadicSum",
            as: ((
                Int32, Float, Double, Float, Double, Float, Double, Float, Double, Double, Double,
                Float, Double
            ) -> Double).self,
            variadicFrom: 1
        )
        #expect(
            try unsafe stack.unsafeInvoke(12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
                == ABICVariadicStackOracle()
        )
    }

    @Test func runtimeVariadicLayoutsPromoteInputsAndRetainTheirTypes() async throws {
        let signature = NativeSignature(
            parameters: [.int32],
            variadicParameters: [.float, .double],
            returns: .double
        )
        let call = try ABIRuntime().resolveCFunctionAndWait(
            named: "ABICVariadicSum",
            signature: signature
        )
        #expect(signature.fixedParameterCount == 1 && signature.parameters.count == 3)
        let values = [
            try NativeValue(copying: Int32(2), as: .int32),
            try NativeValue(copying: Float(1.5), as: .float),
            try NativeValue(copying: Double(2.5), as: .double),
        ]
        #expect(try unsafe call.unsafeInvoke(with: values).read(as: Double.self) == 4)
        let empty = try ABIRuntime().resolveCFunctionAndWait(
            named: "ABICVariadicSum",
            signature: .init(parameters: [.int32], variadicParameters: [], returns: .double)
        )
        #expect(
            try unsafe empty.unsafeInvoke(with: [try .init(copying: Int32(0), as: .int32)]).read(
                as: Double.self
            ) == 0
        )
    }

    @Test func invalidVariadicBoundariesFailPreparation() async throws {
        for boundary in [-1, 0, 2] {
            #expect(throws: (any Error).self) {
                _ = try ABIRuntime().resolveCFunctionAndWait(
                    named: "ABICVariadicSum",
                    as: ((Int32) -> Double).self,
                    variadicFrom: boundary
                )
            }
        }
    }

    @Test func zeroNarrowAndBooleanResults() async throws {
        let runtime = ABIRuntime()
        let answer = try runtime.resolveCFunctionAndWait(
            named: "ABICAnswer",
            as: (() -> Int32).self
        )
        #expect(try unsafe answer.unsafeInvoke() == ABICAnswer())
        let negative = try runtime.resolveCFunctionAndWait(
            named: "ABICNegative",
            as: (() -> Int8).self
        )
        #expect(try unsafe negative.unsafeInvoke() == ABICNegative())
        let negate = try runtime.resolveCFunctionAndWait(
            named: "ABICNegate",
            as: ((Bool) -> Bool).self
        )
        #expect(try unsafe negate.unsafeInvoke(false) == ABICNegate(false))
        #expect(try unsafe negate.unsafeInvoke(true) == ABICNegate(true))
    }

    @Test func twelveMixedArguments() async throws {
        let function = try ABIRuntime.shared.resolveCFunctionAndWait(
            named: "ABICMixed",
            as: ((
                Int8, UInt16, Int32, UInt64, Float, Double, Bool, UnsafeRawPointer?,
                Int64, Double, UInt, Int32
            ) -> Double).self
        )
        var token: Int32 = 0
        try withUnsafePointer(to: &token) { pointer in
            let expected = ABICMixed(-1, 2, 3, 4, 5.5, 6.25, true, pointer, 8, 9.75, 10, 11)
            #expect(expected == 60.5)
            let actual = try unsafe function.unsafeInvoke(
                -1,
                2,
                3,
                4,
                5.5,
                6.25,
                true,
                UnsafeRawPointer(pointer),
                8,
                9.75,
                10,
                11
            )
            #expect(actual == expected)
        }
    }

    @Test func importedCValueLayouts() async throws {
        let runtime = ABIRuntime()
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        let rectangle = try runtime.resolveCFunctionAndWait(
            named: "ABICRect",
            as: ((CGRect) -> CGRect).self
        )
        #expect(try unsafe rectangle.unsafeInvoke(rect) == ABICRect(rect))
        let point = try runtime.resolveCFunctionAndWait(
            named: "ABICPoint",
            as: ((CGPoint) -> CGPoint).self
        )
        #expect(try unsafe point.unsafeInvoke(rect.origin) == ABICPoint(rect.origin))
        let size = try runtime.resolveCFunctionAndWait(
            named: "ABICSize",
            as: ((CGSize) -> CGSize).self
        )
        #expect(try unsafe size.unsafeInvoke(rect.size) == ABICSize(rect.size))
        let range = try runtime.resolveCFunctionAndWait(
            named: "ABICRange",
            as: ((NSRange) -> NSRange).self
        )
        let interval = NSRange(location: 2, length: 3)
        #expect(try unsafe range.unsafeInvoke(interval) == ABICRange(interval))
    }

    @Test func optionalPointersAndVoidResults() async throws {
        let runtime = ABIRuntime()
        let echo = try runtime.resolveCFunctionAndWait(
            named: "ABICPointer",
            as: ((UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<Int32>?).self
        )
        let store = try runtime.resolveCFunctionAndWait(
            named: "ABICStore",
            as: ((UnsafeMutablePointer<Int32>) -> Void).self
        )
        var value: Int32 = 0
        try withUnsafeMutablePointer(to: &value) { pointer in
            #expect(ABICPointer(pointer) == UnsafeMutableRawPointer(pointer))
            #expect(try unsafe echo.unsafeInvoke(pointer) == pointer)
            try unsafe store.unsafeInvoke(pointer)
        }
        #expect(value == 42)
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)
        let nonoptional = try runtime.resolveCFunctionAndWait(
            named: "ABICPointer",
            as: ((UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer).self
        )
        #expect(throws: ABIInvocationError.self) { try unsafe nonoptional.unsafeInvoke(nil) }
    }

    @Test func unmanagedReferencesPreserveExplicitCoreFoundationOwnership() async throws {
        let runtime = ABIRuntime()
        let echo = try runtime.resolveCFunctionAndWait(
            named: "ABICEchoCFValue",
            as: ((Unmanaged<NSObject>?) -> Unmanaged<NSObject>?).self
        )
        let retain = try runtime.resolveCFunctionAndWait(
            named: "ABICRetainCFValue",
            as: ((Unmanaged<NSObject>) -> Unmanaged<NSObject>).self
        )
        let consume = try runtime.resolveCFunctionAndWait(
            named: "ABICConsumeCFValue",
            as: ((Unmanaged<NSObject>) -> Void).self
        )
        let fixture = ABIOwnershipFixture()
        weak var observed: NSObject?
        try autoreleasepool {
            let value = fixture.copyObject()
            observed = value
            #expect(
                try unsafe echo.unsafeInvoke(.passUnretained(value))?.takeUnretainedValue()
                    === value
            )
            #expect(try unsafe echo.unsafeInvoke(nil) == nil)
            let retained = try unsafe retain.unsafeInvoke(.passUnretained(value))
                .takeRetainedValue()
            #expect(retained === value)
            try unsafe consume.unsafeInvoke(.passRetained(value))
            #expect(observed === value && fixture.liveResults == 1)
        }
        #expect(observed == nil && fixture.liveResults == 0)
    }

    @Test func preparedHandleCanCrossActorsAndBeReused() async throws {
        let function = try ABIRuntime.shared.resolveCFunctionAndWait(
            named: "ABICIncrement",
            as: ((Int32) -> Int32).self
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
        #expect(throws: ABIResolutionError.self) {
            _ = try runtime.resolveCFunctionAndWait(named: "ABICAnswer", as: (() -> String).self)
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try runtime.resolveCFunctionAndWait(named: "ABICAnswer", as: (() -> Int32?).self)
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try runtime.resolveCFunctionAndWait(
                named: "ABICAnswer",
                as: ((NSObject) -> Int32).self
            )
        }
        #expect(
            throws: ABIResolutionError.declarationNotFound(
                .init(name: "ABIAbsentCFunction", language: .c)
            )
        ) {
            _ = try runtime.resolveCFunctionAndWait(
                named: "ABIAbsentCFunction",
                as: (() -> Void).self
            )
        }
    }
}
