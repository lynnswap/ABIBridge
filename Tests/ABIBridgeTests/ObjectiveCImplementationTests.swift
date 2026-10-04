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
    @Test func variadicClassMessagesAndCapturedImplementationsPreserveResults() throws {
        let runtime = ABIRuntime()
        typealias Signature = (NSString, Float, Int8, NSString) -> NSString
        let receiver: AnyObject = NSString.self
        let message = try runtime.object(receiver).method(selector: "stringWithFormat:", as: Signature.self, variadicFrom: 1)
        let captured = try runtime.objcImplementation(on: NSString.self, selector: "stringWithFormat:",
            as: Signature.self, variadicFrom: 1, classMethod: true)
        let format = "%.1f/%d/%@" as NSString
        #expect(try unsafe message.unsafeInvoke(format, 1.5, -3, "value") == "1.5/-3/value")
        #expect(try unsafe captured.unsafeInvoke(on: receiver, format, 1.5, -3, "value") == "1.5/-3/value")
        let unbound = message.method
        #expect(try unsafe unbound.unsafeInvoke(on: receiver, format, 2.5, -4, "other") == "2.5/-4/other")
        let rebound = try unbound.bind(to: receiver)
        #expect(try unsafe rebound.unsafeInvoke(format, 3.5, -5, "bound") == "3.5/-5/bound")
    }

    @Test func variadicObjectTailsRetainTheirResultAndAllowNilTermination() throws {
        let runtime = ABIRuntime()
        let receiver: AnyObject = NSArray.self
        let make = try runtime.object(receiver).method(selector: "arrayWithObjects:",
            as: ((NSObject?, NSObject?, NSObject?) -> NSArray).self, variadicFrom: 1)
        let first = NSObject(), second = NSObject()
        let value = try unsafe make.unsafeInvoke(first, second, nil)
        #expect(value.count == 2)
        #expect(value[0] as AnyObject === first && value[1] as AnyObject === second)
        let emptyTail = try runtime.object(NSString.self as AnyObject).method(selector: "stringWithFormat:",
            as: ((NSString) -> NSString).self, variadicFrom: 1)
        #expect(try unsafe emptyTail.unsafeInvoke("literal") == "literal")
    }

    @Test func variadicMessagesObserveReplacementWhileCapturedImplementationsKeepTheirEntry() throws {
        let runtime = ABIRuntime()
        let receiver = ABIVariadicFixture()
        let selector = NSSelectorFromString("sum:")
        let current = try runtime.object(receiver).method(selector: selector,
            as: ((Int, Int, Int) -> Int).self, variadicFrom: 1)
        let captured = try runtime.objcImplementation(on: ABIVariadicFixture.self, selector: selector,
            as: ((Int, Int, Int) -> Int).self, variadicFrom: 1)
        let unbound = try runtime.objcMethod(on: ABIVariadicFixture.self, selector: selector,
            as: ((Int, Int, Int) -> Int).self, variadicFrom: 1)
        #expect(try unsafe current.unsafeInvoke(2, 20, 22) == ABIVariadicCompilerOracle(receiver))
        let method = try #require(class_getInstanceMethod(ABIVariadicFixture.self, selector))
        let replacement = try #require(class_getInstanceMethod(ABIVariadicFixture.self, NSSelectorFromString("replacementSum:")))
        let original = method_setImplementation(method, method_getImplementation(replacement))
        defer { method_setImplementation(method, original) }
        #expect(try unsafe current.unsafeInvoke(2, 20, 22) == ABIVariadicCompilerOracle(receiver))
        #expect(try unsafe current.method.unsafeInvoke(on: receiver, 2, 20, 22) == 1042)
        #expect(try unsafe unbound.bind(to: receiver).unsafeInvoke(2, 20, 22) == 1042)
        #expect(try unsafe captured.unsafeInvoke(on: receiver, 2, 20, 22) == 42)
    }

    @Test func variadicMessagesRejectForwardingImplementationsBeforeNativeEntry() throws {
        let runtime = ABIRuntime()
        let receiver = ABIVariadicFixture()
        let message = try runtime.object(receiver).method(selector: "sum:",
            as: ((Int, Int, Int) -> Int).self, variadicFrom: 1)
        let captured = try runtime.objcImplementation(on: ABIVariadicFixture.self, selector: "sum:",
            as: ((Int, Int, Int) -> Int).self, variadicFrom: 1)
        let method = try #require(class_getInstanceMethod(ABIVariadicFixture.self, NSSelectorFromString("sum:")))
        let original = method_setImplementation(method, ABIHookForwardingImplementation())
        defer { method_setImplementation(method, original) }
        #expect(throws: ABIResolutionError.self) { try unsafe message.unsafeInvoke(2, 20, 22) }
        #expect(throws: ABIResolutionError.self) { try unsafe message.method.unsafeInvoke(on: receiver, 2, 20, 22) }
        #expect(try unsafe captured.unsafeInvoke(on: receiver, 2, 20, 22) == 42)
    }

    @Test func variadicBoundariesMustMatchTheRuntimeFixedPrefix() throws {
        #expect(throws: ABIResolutionError.self) {
            try ABIRuntime().object(NSString.self as AnyObject).method(selector: "stringWithFormat:",
                as: ((NSString, Float) -> NSString).self, variadicFrom: 0)
        }
    }
    @Test func extractedMessagesReleaseTheirOriginalReceiverAndKeepCurrentDispatch() throws {
        let runtime = ABIRuntime.shared
        weak var observedOriginal: ImplementationReceiver?
        let message: NativeObjCMethod<Int, Int> = try autoreleasepool {
            let original = ImplementationReceiver(1)
            observedOriginal = original
            return try runtime.object(original).method(selector: "add:", as: ((Int) -> Int).self).method
        }
        #expect(observedOriginal == nil)
        var second: ImplementationReceiver? = ImplementationChild(40)
        weak let observedSecond = second
        var bound: NativeBoundObjCMethod<Int, Int>? = try message.bind(to: second!)
        #expect(try unsafe message.unsafeInvoke(on: second!, 2) == 1002)
        let extractedAgain = bound!.method
        second = nil
        #expect(try unsafe bound!.unsafeInvoke(2) == 1002)
        bound = nil
        withExtendedLifetime((message, extractedAgain)) { #expect(observedSecond == nil) }
        #expect(throws: ABIResolutionError.self) { try unsafe message.unsafeInvoke(on: NSObject(), 2) }
    }

    @Test func extractedForwardingSignaturesAreValidatedOnEachNewReceiver() throws {
        weak var observed: ABIForwardingFixture?
        let message: NativeObjCMethod<Int> = try autoreleasepool {
            let original = ABIForwardingFixture()
            observed = original
            return try ABIRuntime.shared.object(original).method(selector: "answer", as: (() -> Int).self).method
        }
        #expect(observed == nil)
        let second = ABIForwardingFixture()
        #expect(try unsafe message.unsafeInvoke(on: second) == 61)
        let bound = try message.bind(to: second)
        #expect(try unsafe bound.unsafeInvoke() == 61)
        #expect(second.forwardedCalls == 2)
        second.answerEncoding = "d@:"
        #expect(throws: ABIResolutionError.self) { try unsafe message.unsafeInvoke(on: second) }
        #expect(throws: ABIResolutionError.self) { try message.bind(to: second) }
        #expect(second.forwardedCalls == 2)
        second.answerEncoding = nil
        #expect(throws: ABIResolutionError.self) { try unsafe message.unsafeInvoke(on: second) }
        #expect(second.forwardedCalls == 2)
    }

    @Test func extractedClassMessagesKeepTheirReceiverKindAndOwnershipOverrides() throws {
        let classMessage = try ABIRuntime.shared.object(ImplementationReceiver.self as AnyObject).method(
            selector: "capturedClassName", as: (() -> String).self
        ).method
        #expect(try unsafe classMessage.unsafeInvoke(on: ImplementationChild.self as AnyObject) == NSStringFromClass(ImplementationChild.self))
        #expect(throws: ABIResolutionError.self) { try unsafe classMessage.unsafeInvoke(on: ImplementationReceiver(0)) }
        let owned = try ABIRuntime.shared.object(ABIOwnershipFixture()).method(
            selector: "retainedObject", as: (() -> NSObject).self,
            options: .init(returnsRetainedObject: true)
        ).method
        let fixture = ABIOwnershipFixture()
        weak var observedResult: NSObject?
        try autoreleasepool {
            let result = try unsafe owned.unsafeInvoke(on: fixture)
            observedResult = result
            #expect(fixture.liveResults == 1)
        }
        #expect(observedResult == nil && fixture.liveResults == 0)
    }

    @Test func unboundMessagesAndExplicitBindingHaveIndependentLifetimes() throws {
        var owner: ImplementationCodeOwner? = ImplementationCodeOwner()
        weak var observedOwner = owner
        var message: NativeObjCMethod<Int, Int>? = try ABIRuntime.shared.objcMethod(
            on: ImplementationReceiver.self, selector: "add:", as: ((Int) -> Int).self, retaining: owner
        )
        owner = nil
        weak var observedTemporary: ImplementationReceiver?
        try autoreleasepool {
            let receiver = ImplementationReceiver(40)
            observedTemporary = receiver
            let result = try unsafe message!.unsafeInvoke(on: receiver, 2)
            #expect(result == 42)
        }
        #expect(observedTemporary == nil && observedOwner != nil)

        var receiver: ImplementationReceiver? = ImplementationReceiver(40)
        weak let observedReceiver = receiver
        var bound: NativeBoundObjCMethod<Int, Int>? = try message!.bind(to: receiver!)
        receiver = nil
        message = nil
        #expect(observedReceiver != nil && observedOwner != nil)
        #expect(try unsafe bound!.unsafeInvoke(2) == 42)
        var last = bound
        bound = nil
        #expect(try unsafe last!.unsafeInvoke(2) == 42)
        last = nil
        #expect(observedReceiver == nil && observedOwner == nil)
    }

    @Test func unboundClassMethodsAndReceiverValidation() throws {
        let method = try ABIRuntime.shared.objcMethod(
            on: ImplementationReceiver.self, selector: "capturedClassName",
            as: (() -> String).self, classMethod: true
        )
        #expect(try unsafe method.unsafeInvoke(on: ImplementationChild.self as AnyObject) == NSStringFromClass(ImplementationChild.self))
        #expect(throws: ABIResolutionError.self) { try unsafe method.unsafeInvoke(on: ImplementationReceiver(0)) }
        #expect(throws: ABIResolutionError.self) { try method.bind(to: NSObject.self as AnyObject) }

        let forwarding = ABIForwardingFixture()
        #expect(throws: ABIResolutionError.self) {
            _ = try ABIRuntime.shared.objcMethod(on: ABIForwardingFixture.self, selector: "answer", as: (() -> Int).self)
        }
        let bound = try ABIRuntime.shared.object(forwarding).method(selector: "answer", as: (() -> Int).self)
        #expect(try unsafe bound.unsafeInvoke() == 61)
    }

    @Test func unboundResultsPreserveOwnershipAndConsumedReceivers() throws {
        let fixture = ABIOwnershipFixture()
        for (selector, retained) in [("object", nil), ("copyObject", nil), ("retainedObject", true)] as [(String, Bool?)] {
            let method = try ABIRuntime.shared.objcMethod(
                on: ABIOwnershipFixture.self, selector: selector, as: (() -> NSObject).self,
                options: .init(returnsRetainedObject: retained)
            )
            weak var observed: NSObject?
            try autoreleasepool {
                let result = try unsafe method.unsafeInvoke(on: fixture)
                observed = result
                #expect(fixture.liveResults == 1)
            }
            #expect(observed == nil && fixture.liveResults == 0)
        }
        for selector in ["initWithReplacement", "initReturningNil"] {
            let method = try ABIRuntime.shared.objcMethod(
                on: ABIInitializerFixture.self, selector: selector, as: (() -> ABIInitializerFixture?).self
            )
            weak var observed: ABIInitializerFixture?
            try autoreleasepool {
                let receiver = ABIInitializerFixture()
                observed = receiver
                let result = try unsafe method.unsafeInvoke(on: receiver)
                #expect(observed != nil)
                #expect(selector == "initReturningNil" ? result == nil : result !== receiver)
            }
            #expect(observed == nil)
        }
    }

    @Test func unboundDispatchRejectsChangedABIAndAcceptsEquivalentAggregateNames() throws {
        let name = "ABIUnbound_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let base = try #require(objc_allocateClassPair(NSObject.self, name, 0))
        objc_registerClassPair(base)
        let child = try #require(objc_allocateClassPair(base, name + "Child", 0))
        objc_registerClassPair(child)
        // Runtime classes and the capture-free C entry points live for this test process.
        let number: @convention(c) (AnyObject, Selector, Int) -> Int = { _, _, value in value }
        let incompatible: @convention(c) (AnyObject, Selector, Double) -> Double = { _, _, value in value }
        let size: @convention(c) (AnyObject, Selector, CGSize) -> CGSize = { _, _, value in value }
        let numberSelector = NSSelectorFromString("number:")
        let sizeSelector = NSSelectorFromString("size:")
        let integer = MemoryLayout<Int>.size == 8 ? "q" : "i"
        let scalar = MemoryLayout<CGFloat>.size == 8 ? "d" : "f"
        #expect(class_addMethod(base, numberSelector, unsafeBitCast(number, to: IMP.self), "\(integer)@:\(integer)"))
        #expect(class_addMethod(child, numberSelector, unsafeBitCast(incompatible, to: IMP.self), "d@:d"))
        #expect(class_addMethod(base, sizeSelector, unsafeBitCast(size, to: IMP.self), "{Size=\(scalar)\(scalar)}@:{Size=\(scalar)\(scalar)}"))
        #expect(class_addMethod(child, sizeSelector, unsafeBitCast(size, to: IMP.self), "{Alias=\(scalar)\(scalar)}@:{Alias=\(scalar)\(scalar)}"))
        try autoreleasepool {
            let receiver = try #require(class_createInstance(child, 0)) as AnyObject
            let numberMethod = try ABIRuntime.shared.objcMethod(on: base, selector: "number:", as: ((Int) -> Int).self)
            #expect(throws: ABIResolutionError.self) { try unsafe numberMethod.unsafeInvoke(on: receiver, 42) }
            #expect(throws: ABIResolutionError.self) { try numberMethod.bind(to: receiver) }
            let sizeMethod = try ABIRuntime.shared.objcMethod(on: base, selector: "size:", as: ((CGSize) -> CGSize).self)
            let value = CGSize(width: 3, height: 4)
            #expect(try unsafe sizeMethod.unsafeInvoke(on: receiver, value) == value)
        }
    }

    @Test func originalImplementationSurvivesReplacementAndAcceptsDifferentReceivers() throws {
        let runtime = ABIRuntime.shared
        let first = ImplementationReceiver(10)
        let second = ImplementationReceiver(20)
        let selector = NSSelectorFromString("add:")
        let original = try runtime.objcImplementation(
            on: ImplementationReceiver.self, selector: "add:", as: ((Int) -> Int).self
        )
        let dynamic = try runtime.object(first).method(selector: "add:", as: ((Int) -> Int).self)
        let extracted = dynamic.method
        let unbound = try runtime.objcMethod(on: ImplementationReceiver.self, selector: "add:", as: ((Int) -> Int).self)
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
        #expect(try unsafe extracted.unsafeInvoke(on: second, 1) == 42)
        #expect(try unsafe unbound.unsafeInvoke(on: first, 1) == 22)
        let child = ImplementationChild(30)
        #expect(try unsafe original.unsafeInvoke(on: child, 1) == 31)
        let childMessage = try runtime.object(child).method(selector: "add:", as: ((Int) -> Int).self)
        #expect(try unsafe childMessage.unsafeInvoke(1) == 1001)
        #expect(try unsafe unbound.unsafeInvoke(on: child, 1) == 1001)
    }

    @MainActor @Test func inheritedImplementationsAndStructures() throws {
        let size = try ABIRuntime.shared.objcImplementation(
            on: ImplementationChild.self, selector: "size:", as: ((CGSize) -> CGSize).self
        )
        let receiver = ImplementationChild(7)
        #expect(try unsafe size.unsafeInvoke(on: receiver, CGSize(width: 3, height: 5)) == CGSize(width: 10, height: 5))
        #expect(throws: ABIResolutionError.self) { try unsafe size.unsafeInvoke(on: NSObject(), .zero) }
        #expect(throws: ABIResolutionError.self) { try unsafe size.unsafeInvoke(on: ImplementationChild.self as AnyObject, .zero) }
    }

    @Test func classMethodsRequireCompatibleClassObjects() throws {
        let method = try ABIRuntime.shared.objcImplementation(
            on: ImplementationReceiver.self, selector: "capturedClassName",
            as: (() -> String).self, classMethod: true
        )
        #expect(try unsafe method.unsafeInvoke(on: ImplementationReceiver.self as AnyObject) == NSStringFromClass(ImplementationReceiver.self))
        #expect(try unsafe method.unsafeInvoke(on: ImplementationChild.self as AnyObject) == NSStringFromClass(ImplementationChild.self))
        #expect(throws: ABIResolutionError.self) { try unsafe method.unsafeInvoke(on: ImplementationReceiver(0)) }
        #expect(throws: ABIResolutionError.self) { try unsafe method.unsafeInvoke(on: NSObject.self as AnyObject) }
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
        #expect(throws: ABIResolutionError.self) {
            _ = try ABIRuntime.shared.objcImplementation(on: ABIForwardingFixture.self, selector: "answer", as: (() -> Int).self)
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try ABIRuntime.shared.objcImplementation(on: ImplementationReceiver.self, selector: "absent", as: (() -> Void).self)
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try ABIRuntime.shared.objcImplementation(on: ImplementationReceiver.self, selector: "add:", as: (() -> Int).self)
        }
    }
}
