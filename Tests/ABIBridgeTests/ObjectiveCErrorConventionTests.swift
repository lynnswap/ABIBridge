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
        let bound = try runtime.object(fixture).resolveMethodAndWait(
            selector: "check:error:",
            as: ((Bool) throws -> Void).self
        )
        try unsafe bound.unsafeInvoke(true)
        expectFixtureError(code: 7) { try unsafe bound.unsafeInvoke(false) }

        let message = try runtime.resolveObjCMethodAndWait(
            on: ABIErrorConventionFixture.self,
            selector: "check:error:",
            as: ((Bool) throws -> Void).self
        )
        try unsafe message.unsafeInvoke(on: fixture, true)
        expectFixtureError(code: 7) { try unsafe message.unsafeInvoke(on: fixture, false) }

        let implementation = try runtime.resolveObjCImplementationAndWait(
            on: ABIErrorConventionFixture.self,
            selector: "check:error:",
            as: ((Bool) throws -> Void).self
        )
        try unsafe implementation.unsafeInvoke(on: fixture, true)
        expectFixtureError(code: 7) { try unsafe implementation.unsafeInvoke(on: fixture, false) }
    }

    @Test func objectMethodsThrowWhenTheyReturnNil() async throws {
        let fixture = try ABIErrorConventionFixture(value: 1)
        let describe = try await ABIRuntime.shared.object(fixture).resolveMethod(
            selector: "describe:error:",
            as: ((Int) throws -> String).self
        )
        #expect(try unsafe describe.unsafeInvoke(5) == "5")
        expectFixtureError(code: -2) { _ = try unsafe describe.unsafeInvoke(-2) }

        let make = try await ABIRuntime.shared.resolveObjCMethod(
            on: ABIErrorConventionFixture.self,
            selector: "fixtureWithValue:error:",
            as: ((Int) throws -> ABIErrorConventionFixture).self,
            classMethod: true
        )
        #expect(try unsafe make.unsafeInvoke(on: ABIErrorConventionFixture.self, 3).value == 3)
        expectFixtureError(code: -1) {
            _ = try unsafe make.unsafeInvoke(on: ABIErrorConventionFixture.self, -1)
        }
    }

    @Test func failuresWithoutAnErrorAreReported() throws {
        let fail = try ABIRuntime.shared.object(ABIErrorConventionFixture(value: 0))
            .resolveMethodAndWait(selector: "failSilently:", as: (() throws -> Void).self)
        #expect(throws: NativeObjCUnreportedFailure.self) { try unsafe fail.unsafeInvoke() }
    }

    @Test func errorConventionsRequireAnErrorParameterAndFailureResult() throws {
        let object = ABIRuntime.shared.object(try ABIErrorConventionFixture(value: 0))
        // A scalar result has no failure value.
        #expect(throws: ABIResolutionError.self) {
            try object.resolveMethodAndWait(selector: "count:", as: (() throws -> Int).self)
        }
        // The last parameter is not an NSError **.
        #expect(throws: ABIResolutionError.self) {
            try object.resolveMethodAndWait(selector: "raise:", as: (() throws -> Int).self)
        }
        // An Optional result cannot distinguish failure from a nil value.
        #expect(throws: ABIResolutionError.self) {
            try object.resolveMethodAndWait(
                selector: "describe:error:",
                as: ((Int) throws -> String?).self
            )
        }
    }

    @Test func callersCanSupplyTheirOwnAutoreleasingErrorSlot() throws {
        let check = try ABIRuntime.shared.object(ABIErrorConventionFixture(value: 9))
            .resolveMethodAndWait(
                selector: "check:error:",
                as: ((Bool, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool).self
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
        let bound = try runtime.object(fixture).resolveMethodAndWait(
            selector: "raise:",
            as: ((String) -> Int).self
        )
        expectException { try unsafe bound.unsafeInvoke("boom") }
        // A captured implementation is called through the C call interface.
        let implementation = try runtime.resolveObjCImplementationAndWait(
            on: ABIErrorConventionFixture.self,
            selector: "raise:",
            as: ((String) -> Int).self
        )
        expectException { try unsafe implementation.unsafeInvoke(on: fixture, "boom") }
    }
}
