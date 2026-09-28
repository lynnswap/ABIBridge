import ABIBridge
import CoreGraphics
import Foundation
import ObjectiveCFixtures
import Testing

private struct CallerInsets {
    var top, left, bottom, right: Double
}

private struct CallerPadded { var value: Double; var tag: Int8 }

@Suite(.serialized)
struct ObjectiveCAggregateTests {
    @Test func nativeEncodingsAcceptCallerSelectedCompatibleStructures() throws {
        let fixture = ABIAggregateFixture()
        let call = try ABIRuntime.shared.object(fixture).method(
            selector: "transformInsets:", as: ((CallerInsets) -> CallerInsets).self
        )
        let result = try unsafe call.unsafeInvoke(CallerInsets(top: 10, left: 20, bottom: 30, right: 40))
        #expect(result.top == 11 && result.left == 22 && result.bottom == 33 && result.right == 44)
        let native = try ABIRuntime.shared.object(fixture).method(
            selector: "transformInsets:", as: ((ABIInsetsFixture) -> ABIInsetsFixture).self
        )
        let value = try unsafe native.unsafeInvoke(ABIInsetsFixture(top: 1, left: 2, bottom: 3, right: 4))
        #expect(value.top == 2 && value.left == 4 && value.bottom == 6 && value.right == 8)
    }

    @Test func nestedStructuresAndArrayFieldsUseOneSharedLayout() throws {
        let fixture = ABIAggregateFixture()
        let input = ABINestedAggregate(insets: .init(top: 1, left: 2, bottom: 3, right: 4),
                                       values: (5, 6, 7), tag: 8)
        let call = try ABIRuntime.shared.object(fixture).method(
            selector: "transformNested:", as: ((ABINestedAggregate) -> ABINestedAggregate).self
        )
        let result = try unsafe call.unsafeInvoke(input)
        let expected = fixture.transformNested(input)
        #expect(result.insets.top == expected.insets.top && result.insets.right == expected.insets.right)
        #expect(result.values.0 == 15 && result.values.1 == 26 && result.values.2 == 37 && result.tag == 9)
    }

    @Test func capturedImplementationUsesNativeAggregateRegisterClassification() throws {
        let fixture = ABIAggregateFixture()
        let captured = try ABIRuntime.shared.objcImplementation(
            on: ABIAggregateFixture.self, selector: "transformInsets:", as: ((CallerInsets) -> CallerInsets).self
        )
        let result = try unsafe captured.unsafeInvoke(on: fixture, CallerInsets(top: 1, left: 2, bottom: 3, right: 4))
        #expect(result.top == 2 && result.left == 4 && result.bottom == 6 && result.right == 8)
        let nested = try ABIRuntime.shared.objcImplementation(
            on: ABIAggregateFixture.self, selector: "transformNested:", as: ((ABINestedAggregate) -> ABINestedAggregate).self
        )
        let input = ABINestedAggregate(insets: .init(top: 1, left: 2, bottom: 3, right: 4), values: (5, 6, 7), tag: 8)
        let actual = try unsafe nested.unsafeInvoke(on: fixture, input)
        #expect(actual.values.2 == 37 && actual.tag == 9)
    }

    @Test func sdkStructuresNeedNoLibrarySideTypeRegistration() throws {
        let fixture = ABIAggregateFixture()
        let call = try ABIRuntime.shared.object(fixture).method(
            selector: "transformAffine:", as: ((CGAffineTransform) -> CGAffineTransform).self
        )
        let value = CGAffineTransform(a: 1, b: 2, c: 3, d: 4, tx: 5, ty: 6)
        #expect(try unsafe call.unsafeInvoke(value) == fixture.transformAffine(value))
        let captured = try ABIRuntime.shared.objcImplementation(
            on: ABIAggregateFixture.self, selector: "transformAffine:", as: ((CGAffineTransform) -> CGAffineTransform).self
        )
        #expect(try unsafe captured.unsafeInvoke(on: fixture, value) == fixture.transformAffine(value))
    }

    @Test func managedHooksMarshalNestedArgumentsAndResults() throws {
        let hook = try unsafe ABIRuntime.shared.hookMethod(
            on: ABIAggregateFixture.self, selector: "transformNested:",
            as: ((ABINestedAggregate) -> ABINestedAggregate).self, onFailure: { Issue.record($0) }
        ) { call, value in
            var result = try call.proceed(value)
            result.tag += 100
            return result
        }
        defer { hook.invalidate() }
        let input = ABINestedAggregate(insets: .init(top: 1, left: 2, bottom: 3, right: 4), values: (5, 6, 7), tag: 8)
        let result = ABIAggregateFixture().transformNested(input)
        #expect(result.values.2 == 37 && result.insets.right == 8 && result.tag == 109)
    }

    @Test func nativeTailPaddingDoesNotRequireALargerSwiftValueSize() throws {
        #expect(MemoryLayout<CallerPadded>.size < MemoryLayout<ABIPaddedAggregate>.size)
        let call = try ABIRuntime.shared.object(ABIAggregateFixture()).method(
            selector: "transformPadded:", as: ((CallerPadded) -> CallerPadded).self
        )
        let result = try unsafe call.unsafeInvoke(CallerPadded(value: 1, tag: 2))
        #expect(result.value == 2.5 && result.tag == 4)
        let captured = try ABIRuntime.shared.objcImplementation(on: ABIAggregateFixture.self,
            selector: "transformPadded:", as: ((CallerPadded) -> CallerPadded).self)
        let actual = try unsafe captured.unsafeInvoke(on: ABIAggregateFixture(), CallerPadded(value: 1, tag: 2))
        #expect(actual.value == 2.5 && actual.tag == 4)
    }

    @Test func undersizedTypedStorageIsRejectedBeforeDispatch() throws {
        #expect(throws: ABIResolutionError.self) {
            _ = try ABIRuntime.shared.object(ABIAggregateFixture()).method(
                selector: "transformInsets:", as: ((Double) -> Double).self
            )
        }
    }
}
