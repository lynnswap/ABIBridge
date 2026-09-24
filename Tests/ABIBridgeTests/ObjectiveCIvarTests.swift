import ABIBridge
import Foundation
import ObjectiveC
import ObjectiveCFixtures
import Testing

struct ObjectiveCIvarTests {
    @MainActor @Test func inheritedAndBridgedValuesUseRuntimeNames() throws {
        let fixture = ABIIvarChild()
        let object = NSObject()
        fixture.inheritedObject = object
        fixture.childObject = ["first", "second"] as NSArray
        let handle = ABIRuntime.shared.object(fixture)
        #expect(try handle.value(forIvar: "_inheritedObject", as: NSObject.self) === object)
        #expect(try handle.value(forIvar: "_childObject", as: [String].self) == ["first", "second"])
        fixture.childObject = NSNumber(value: 42)
        #expect(try handle.value(forIvar: "_childObject", as: Int.self) == 42)
        #expect(throws: ABIResolutionError.ivarNotFound(name: "childObject", className: NSStringFromClass(ABIIvarChild.self))) {
            try handle.value(forIvar: "childObject", as: NSObject?.self)
        }
    }

    @Test func missingNilAndIncompatibleValuesRemainDistinct() throws {
        let handle = ABIRuntime.shared.object(ABIIvarFixture())
        #expect(try handle.value(forIvar: "_inheritedObject", as: NSObject?.self) == nil)
        #expect(throws: ABIInvocationError.unexpectedNilResult(expected: String(reflecting: NSObject.self))) {
            try handle.value(forIvar: "_inheritedObject", as: NSObject.self)
        }
        #expect(throws: ABIResolutionError.ivarNotFound(name: "_missing", className: NSStringFromClass(ABIIvarFixture.self))) {
            try handle.value(forIvar: "_missing", as: NSObject?.self)
        }
        #expect(throws: ABIResolutionError.self) {
            try handle.value(forIvar: "_inheritedObject\0suffix", as: NSObject?.self)
        }
        let fixture = ABIIvarFixture()
        fixture.inheritedObject = NSObject()
        #expect(throws: ABIInvocationError.self) {
            try ABIRuntime.shared.object(fixture).value(forIvar: "_inheritedObject", as: String.self)
        }
    }

    @Test func nonObjectStorageIsRejected() throws {
        let fixture = ABIIvarFixture()
        fixture.scalar = 42
        fixture.pointer = UnsafeMutableRawPointer(bitPattern: 0x1234)!
        fixture.range = NSRange(location: 1, length: 3)
        let handle = ABIRuntime.shared.object(fixture)
        for name in ["_scalar", "_pointer", "_range"] {
            #expect(throws: ABIResolutionError.self) {
                try handle.value(forIvar: name, as: NSObject?.self)
            }
        }
        #expect(throws: ABIResolutionError.self) { try handle.value(forIvar: "_scalar", as: Int.self) }
        #expect(throws: ABIResolutionError.self) { try handle.value(forIvar: "_pointer", as: UnsafeRawPointer.self) }
    }

    @Test func returnedObjectOutlivesReceiverWithoutRetainingIt() throws {
        weak var receiver: ABIIvarFixture?
        weak var original: NSObject?
        var result: NSObject? = try autoreleasepool {
            let fixture = ABIIvarFixture()
            receiver = fixture
            let value = NSObject()
            original = value
            fixture.inheritedObject = value
            return try ABIRuntime.shared.object(fixture).value(forIvar: "_inheritedObject", as: NSObject.self)
        }
        #expect(receiver == nil)
        #expect(original != nil && result === original)
        result = nil
        #expect(original == nil)
    }

    @Test func weakAndUnretainedIvarsRespectTheirLifetimes() throws {
        let fixture = ABIIvarFixture()
        let handle = ABIRuntime.shared.object(fixture)
        weak var observed: NSObject?
        var result: NSObject? = try autoreleasepool {
            let object = NSObject()
            observed = object
            fixture.weakObject = object
            let value = try handle.value(forIvar: "_weakObject", as: NSObject.self)
            #expect(value === object)
            return value
        }
        #expect(observed != nil && result === observed)
        result = nil
        #expect(observed == nil)
        #expect(try handle.value(forIvar: "_weakObject", as: NSObject?.self) == nil)
        let borrowed = NSObject()
        fixture.unretainedObject = borrowed
        try withExtendedLifetime(borrowed) {
            let value = try handle.value(forIvar: "_unretainedObject", as: NSObject.self)
            #expect(value === borrowed)
            fixture.unretainedObject = nil
        }
        #expect(try handle.value(forIvar: "_unretainedObject", as: NSObject?.self) == nil)
    }

    @Test func classAndBlockValuesUseTheirDeclaredRepresentations() throws {
        let fixture = ABIIvarFixture()
        let handle = ABIRuntime.shared.object(fixture)
        #expect(try handle.value(forIvar: "_classObject", as: AnyClass?.self) == nil)
        fixture.classObject = NSString.self
        #expect(try handle.value(forIvar: "_classObject", as: AnyClass.self) === NSString.self)
        #expect(throws: ABIInvocationError.self) {
            try handle.value(forIvar: "_classObject", as: NSObject.self)
        }
        typealias Block = @convention(block) (Int32) -> Int32
        var amount: Int32 = 7
        fixture.block = { [amount] in $0 + amount }
        amount = 100
        let block = try handle.value(forIvar: "_block", as: Block.self)
        fixture.block = nil
        #expect(block(3) == 10)
        #expect(try handle.value(forIvar: "_block", as: Block?.self) == nil)
        #expect(throws: ABIResolutionError.self) {
            try handle.value(forIvar: "_block", as: ((Int32) -> Int32).self)
        }
    }

    @Test func isaUsesTheDecodedRuntimeClass() throws {
        let receivers: [AnyObject] = [NSObject(), ABIIvarChild(), NSNumber(value: 42), NSString(string: "short")]
        for receiver in receivers {
            let actual: AnyClass = try #require(object_getClass(receiver))
            let handle = ABIRuntime.shared.object(receiver)
            let found = try handle.value(forIvar: "isa", as: AnyClass.self)
            #expect(found === actual)
            let optional = try handle.value(forIvar: "isa", as: AnyClass?.self)
            #expect(optional === actual)
        }
    }

    @Test func failedConversionReleasesItsTemporaryReference() throws {
        weak var observed: NSObject?
        autoreleasepool {
            let fixture = ABIIvarFixture()
            let object = NSObject()
            observed = object
            fixture.inheritedObject = object
            #expect(throws: ABIInvocationError.self) {
                try ABIRuntime.shared.object(fixture).value(forIvar: "_inheritedObject", as: String.self)
            }
        }
        #expect(observed == nil)
    }
}
