import ABIBridge
import Foundation
import ObjectiveCFixtures
import Testing

struct ObjectiveCErrorConventionTests {
    private func expectFixtureError(code: Int, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected the method's NSError")
        } catch let error as NSError {
            #expect(error.domain == ABIErrorConventionFixtureDomain)
            #expect(error.code == code)
        }
    }

    @Test func booleanMethodsThrowTheirReportedError() throws {
        let fixture = try ABIErrorConventionFixture(value: 7)
        let runtime = ABIRuntime.shared
        let bound = try runtime.object(fixture).resolveAndWait(
            .message(
                "check:error:",
                as: ((Bool) throws -> Void).self
            )
        )
        try unsafe bound.unsafeInvoke(true)
        expectFixtureError(code: 7) { try unsafe bound.unsafeInvoke(false) }

        let message = try runtime.resolveAndWait(
            .message(
                "check:error:",
                as: ((Bool) throws -> Void).self
            ),
            on: ABIErrorConventionFixture.self
        )
        try unsafe message.unsafeInvoke(on: fixture, true)
        expectFixtureError(code: 7) { try unsafe message.unsafeInvoke(on: fixture, false) }

        let implementation = try runtime.resolveAndWait(
            .implementation(
                "check:error:",
                as: ((Bool) throws -> Void).self
            ),
            on: ABIErrorConventionFixture.self
        )
        try unsafe implementation.unsafeInvoke(on: fixture, true)
        expectFixtureError(code: 7) { try unsafe implementation.unsafeInvoke(on: fixture, false) }
    }

    @Test func selectorsDescribeThrowingMessages() async throws {
        let fixture = try ABIErrorConventionFixture(value: 4)
        let runtime = ABIRuntime.shared
        let selector = #selector(ABIErrorConventionFixture.check(_:))
        let bound = try await runtime.object(fixture).resolve(
            .message(selector, as: ((Bool) throws -> Void).self)
        )
        try unsafe bound.unsafeInvoke(true)
        expectFixtureError(code: 4) { try unsafe bound.unsafeInvoke(false) }

        let message = try runtime.resolveAndWait(
            .message(selector, as: ((Bool) throws -> Void).self),
            on: ABIErrorConventionFixture.self
        )
        expectFixtureError(code: 4) { try unsafe message.unsafeInvoke(on: fixture, false) }

        let implementation = try await runtime.resolve(
            .implementation(selector, as: ((Bool) throws -> Void).self),
            on: ABIErrorConventionFixture.self
        )
        try unsafe implementation.unsafeInvoke(on: fixture, true)
        expectFixtureError(code: 4) { try unsafe implementation.unsafeInvoke(on: fixture, false) }
    }

    @Test func objectMethodsThrowWhenTheyReturnNil() async throws {
        let fixture = try ABIErrorConventionFixture(value: 1)
        let describe = try await ABIRuntime.shared.object(fixture).resolve(
            .message(
                "describe:error:",
                as: ((Int) throws -> String).self
            )
        )
        #expect(try unsafe describe.unsafeInvoke(5) == "5")
        expectFixtureError(code: -2) { _ = try unsafe describe.unsafeInvoke(-2) }

        let make = try await ABIRuntime.shared.resolve(
            .message(
                "fixtureWithValue:error:",
                as: ((Int) throws -> ABIErrorConventionFixture).self
            ),
            on: ABIErrorConventionFixture.self,
            classMethod: true
        )
        #expect(try unsafe make.unsafeInvoke(on: ABIErrorConventionFixture.self, 3).value == 3)
        expectFixtureError(code: -1) {
            _ = try unsafe make.unsafeInvoke(on: ABIErrorConventionFixture.self, -1)
        }
    }

    @Test func failuresWithoutAnErrorAreReported() throws {
        let fail = try ABIRuntime.shared.object(ABIErrorConventionFixture(value: 0))
            .resolveAndWait(.message("failSilently:", as: (() throws -> Void).self))
        #expect(throws: NativeObjCUnreportedFailure.self) { try unsafe fail.unsafeInvoke() }
    }

    @Test func errorConventionsRequireAnErrorParameterAndFailureResult() throws {
        let object = ABIRuntime.shared.object(try ABIErrorConventionFixture(value: 0))
        // A scalar result has no failure value.
        #expect(throws: ABIResolutionError.self) {
            try object.resolveAndWait(.message("count:", as: (() throws -> Int).self))
        }
        // The last parameter is not an NSError **.
        #expect(throws: ABIResolutionError.self) {
            try object.resolveAndWait(.message("raise:", as: (() throws -> Int).self))
        }
        // An Optional result cannot distinguish failure from a nil value.
        #expect(throws: ABIResolutionError.self) {
            try object.resolveAndWait(
                .message(
                    "describe:error:",
                    as: ((Int) throws -> String?).self
                )
            )
        }
    }

    @Test func callersCanSupplyTheirOwnAutoreleasingErrorSlot() throws {
        let check = try ABIRuntime.shared.object(ABIErrorConventionFixture(value: 9))
            .resolveAndWait(
                .message(
                    "check:error:",
                    as: ((Bool, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool).self
                )
            )
        // Autoreleasing storage does not own its value; reading it retains.
        let slot = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<UnsafeRawPointer?>.size,
            alignment: MemoryLayout<UnsafeRawPointer?>.alignment
        )
        slot.storeBytes(of: nil, as: UnsafeRawPointer?.self)
        defer { slot.deallocate() }
        let error = try autoreleasepool { () throws -> NSError? in
            let pointer = AutoreleasingUnsafeMutablePointer<NSError?>(
                slot.assumingMemoryBound(to: NSError?.self)
            )
            #expect(try unsafe check.unsafeInvoke(false, pointer) == false)
            return pointer.pointee
        }
        #expect(error?.code == 9)
    }

    @Test func otherAutoreleasedOutputsOutliveTheCall() throws {
        let fill = try ABIRuntime.shared.object(ABIErrorConventionFixture(value: 0))
            .resolveAndWait(
                .message(
                    "fill:error:",
                    as: ((AutoreleasingUnsafeMutablePointer<AnyObject?>?) throws -> Void).self
                )
            )
        let slot = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<UnsafeRawPointer?>.size,
            alignment: MemoryLayout<UnsafeRawPointer?>.alignment
        )
        slot.storeBytes(of: nil, as: UnsafeRawPointer?.self)
        defer { slot.deallocate() }
        let before = ABIErrorConventionFixture.liveFilledObjects
        try autoreleasepool {
            let output = AutoreleasingUnsafeMutablePointer<AnyObject?>(
                slot.assumingMemoryBound(to: AnyObject?.self)
            )
            try unsafe fill.unsafeInvoke(output)
            // The caller's pool, not the call, owns the autoreleased output.
            #expect(ABIErrorConventionFixture.liveFilledObjects == before + 1)
            #expect(output.pointee != nil)
        }
        #expect(ABIErrorConventionFixture.liveFilledObjects == before)
    }

    @Test func exceptionsAreThrownInsteadOfUnwinding() throws {
        let fixture = try ABIErrorConventionFixture(value: 0)
        let runtime = ABIRuntime.shared
        func expectException(_ body: () throws -> Int) {
            do {
                _ = try body()
                Issue.record("Expected an Objective-C exception")
            } catch let exception as NativeObjCException {
                #expect(exception.name == NSExceptionName.invalidArgumentException.rawValue)
                #expect(exception.reason == "boom")
                #expect(!exception.callStackSymbols.isEmpty)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        let bound = try runtime.object(fixture).resolveAndWait(
            .message(
                "raise:",
                as: ((String) -> Int).self
            )
        )
        expectException { try unsafe bound.unsafeInvoke("boom") }
        // A captured implementation is called through the C call interface.
        let implementation = try runtime.resolveAndWait(
            .implementation(
                "raise:",
                as: ((String) -> Int).self
            ),
            on: ABIErrorConventionFixture.self
        )
        expectException { try unsafe implementation.unsafeInvoke(on: fixture, "boom") }
    }
}
