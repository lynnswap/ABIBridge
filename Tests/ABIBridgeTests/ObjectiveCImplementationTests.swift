import ABIBridge
import CoreGraphics
import Foundation
import ObjectiveC
import ObjectiveCFixtures
import Testing

private class ImplementationReceiver: NSObject {
    let base: Int
    init(_ base: Int) { self.base = base }
    @objc dynamic func add(_ value: Int) -> Int { base + value }
    @objc func size(_ value: CGSize) -> CGSize { CGSize(width: value.width + CGFloat(base), height: value.height) }
    @objc class func capturedClassName() -> NSString { NSStringFromClass(self) as NSString }
}
private final class ImplementationChild: ImplementationReceiver {
    override func add(_ value: Int) -> Int { 1000 + value }
}
private final class ImplementationCodeOwner {}

@Suite(.serialized)
struct ObjectiveCImplementationTests {
    @Test func originalImplementationSurvivesReplacementAndAcceptsDifferentReceivers() throws {
        let runtime = ABIRuntime.shared
        let first = ImplementationReceiver(10)
        let second = ImplementationReceiver(20)
        let selector = NSSelectorFromString("add:")
        let original = try runtime.objcImplementation(
            on: ImplementationReceiver.self, selector: "add:", as: ((Int) -> Int).self
        )
        let dynamic = try runtime.object(first).method(selector: "add:", as: ((Int) -> Int).self)
        let method = try #require(class_getInstanceMethod(ImplementationReceiver.self, selector))
        let replacement: @convention(block) (AnyObject, Int) -> Int = { receiver, value in
            // The fixture's known signature cannot fail conversion.
            (try! unsafe original.unsafeInvoke(on: receiver, value)) * 2
        }
        let imp = imp_implementationWithBlock(replacement)
        let old = method_setImplementation(method, imp)
        defer {
            method_setImplementation(method, old)
            imp_removeBlock(imp)
        }
        #expect(try unsafe original.unsafeInvoke(on: first, 1) == 11)
        #expect(try unsafe original.unsafeInvoke(on: second, 1) == 21)
        #expect(try unsafe dynamic.unsafeInvoke(1) == 22)
        let child = ImplementationChild(30)
        #expect(try unsafe original.unsafeInvoke(on: child, 1) == 31)
        let childMessage = try runtime.object(child).method(selector: "add:", as: ((Int) -> Int).self)
        #expect(try unsafe childMessage.unsafeInvoke(1) == 1001)
    }

    @MainActor @Test func inheritedImplementationsAndStructures() throws {
        let size = try ABIRuntime.shared.objcImplementation(
            on: ImplementationChild.self, selector: "size:", as: ((CGSize) -> CGSize).self
        )
        let receiver = ImplementationChild(7)
        #expect(try unsafe size.unsafeInvoke(on: receiver, CGSize(width: 3, height: 5)) == CGSize(width: 10, height: 5))
        #expect(throws: NSError.self) { try unsafe size.unsafeInvoke(on: NSObject(), .zero) }
        #expect(throws: NSError.self) { try unsafe size.unsafeInvoke(on: ImplementationChild.self as AnyObject, .zero) }
    }

    @Test func classMethodsRequireCompatibleClassObjects() throws {
        let method = try ABIRuntime.shared.objcImplementation(
            on: ImplementationReceiver.self, selector: "capturedClassName",
            as: (() -> String).self, classMethod: true
        )
        #expect(try unsafe method.unsafeInvoke(on: ImplementationReceiver.self as AnyObject) == NSStringFromClass(ImplementationReceiver.self))
        #expect(try unsafe method.unsafeInvoke(on: ImplementationChild.self as AnyObject) == NSStringFromClass(ImplementationChild.self))
        #expect(throws: NSError.self) { try unsafe method.unsafeInvoke(on: ImplementationReceiver(0)) }
        #expect(throws: NSError.self) { try unsafe method.unsafeInvoke(on: NSObject.self as AnyObject) }
    }

    @Test func noReceiverIsRetainedAndExplicitCodeOwnerIsRetained() throws {
        var owner: ImplementationCodeOwner? = ImplementationCodeOwner()
        weak var observedOwner = owner
        var implementation: NativeObjCImplementation<Int, Int>? = try ABIRuntime.shared.objcImplementation(
            on: ImplementationReceiver.self, selector: "add:", as: ((Int) -> Int).self, retaining: owner
        )
        owner = nil
        #expect(observedOwner != nil)
        weak var observedReceiver: ImplementationReceiver?
        try autoreleasepool {
            let receiver = ImplementationReceiver(40)
            observedReceiver = receiver
            let value = try unsafe implementation!.unsafeInvoke(on: receiver, 2)
            #expect(value == 42)
        }
        #expect(observedReceiver == nil)
        implementation = nil
        #expect(observedOwner == nil)
    }

    @Test func capturedResultsRespectOwnershipAndInitialization() throws {
        let fixture = ABIOwnershipFixture()
        for (selector, retained) in [("object", nil), ("copyObject", nil), ("retainedObject", true)] as [(String, Bool?)] {
            let method = try ABIRuntime.shared.objcImplementation(
                on: ABIOwnershipFixture.self, selector: selector, as: (() -> NSObject).self,
                options: .init(returnsRetainedObject: retained)
            )
            weak var observed: NSObject?
            try autoreleasepool {
                let value = try unsafe method.unsafeInvoke(on: fixture)
                observed = value
                #expect(fixture.liveResults == 1)
            }
            #expect(observed == nil && fixture.liveResults == 0)
        }
        for selector in ["initWithReplacement", "initReturningNil"] {
            let method = try ABIRuntime.shared.objcImplementation(
                on: ABIInitializerFixture.self, selector: selector, as: (() -> ABIInitializerFixture?).self
            )
            weak var original: ABIInitializerFixture?
            try autoreleasepool {
                let receiver = ABIInitializerFixture()
                original = receiver
                let value = try unsafe method.unsafeInvoke(on: receiver)
                if selector == "initReturningNil" { #expect(value == nil) }
                else { #expect(value != nil && value !== receiver) }
                #expect(original != nil)
            }
            #expect(original == nil)
        }
    }

    @Test func capturedBlocksAndCharacterBooleans() throws {
        typealias Block = @convention(block) (Int32) -> Int32
        let apply = try ABIRuntime.shared.objcImplementation(
            on: ABIBlockFixture.self, selector: "apply:using:", as: ((Int32, Block?) -> Int32).self
        )
        let block: Block = { $0 + 2 }
        #expect(try unsafe apply.unsafeInvoke(on: ABIBlockFixture(), 40, block) == 42)
        let negate = try ABIRuntime.shared.objcImplementation(
            on: ABIOwnershipFixture.self, selector: "negateCharacterBoolean:", as: ((Bool) -> Bool).self
        )
        #expect(try unsafe negate.unsafeInvoke(on: ABIOwnershipFixture(), false))
    }

    @Test func missingForwardingAndMismatchedSignaturesFailBeforeCalling() throws {
        #expect(throws: NSError.self) {
            _ = try ABIRuntime.shared.objcImplementation(on: ABIForwardingFixture.self, selector: "answer", as: (() -> Int).self)
        }
        #expect(throws: NSError.self) {
            _ = try ABIRuntime.shared.objcImplementation(on: ImplementationReceiver.self, selector: "absent", as: (() -> Void).self)
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try ABIRuntime.shared.objcImplementation(on: ImplementationReceiver.self, selector: "add:", as: (() -> Int).self)
        }
    }
}
