import ABIBridge
import CoreGraphics
import Foundation
import ObjectiveC
import ObjectiveCFixtures
import Testing

private class Renderer: NSObject {
    var recorded: (NSObject?, Bool)?
    @objc func answer() -> Int { 42 }
    @objc func refreshAnimated(_ animated: Bool) -> Bool { !animated }
    @objc func setImage(_ image: NSObject?, animated: Bool) { recorded = (image, animated) }
    @objc func echo(_ object: NSObject?) -> NSObject? { object }
    @objc func range(_ range: NSRange) -> NSRange { range }
    @objc func rectangle(_ rect: CGRect) -> CGRect { rect }
    @objc func point(_ point: CGPoint) -> CGPoint { point }
    @objc func size(_ size: CGSize) -> CGSize { size }
    @objc func pointer(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? { pointer }
    @objc func mixed(_ a: Int8, _ b: UInt16, _ c: Int32, _ d: UInt64,
                     _ e: Float, _ f: Double, _ g: Bool, _ h: NSObject?,
                     _ i: Int, _ j: Double) -> Double {
        Double(a) + Double(b) + Double(c) + Double(d) + Double(e) + f
            + (g ? 1 : 0) + (h == nil ? 0 : 1) + Double(i) + j
    }
}

struct ObjectiveCInvocationTests {
    @MainActor @Test func callerIsolationAndOptionalArguments() async throws {
        let renderer = Renderer()
        let object = ABIRuntime.shared.object(renderer)
        let setImage = try await object.method(
            selector: "setImage:animated:", as: ((NSObject?, Bool) -> Void).self
        )
        let image = NSObject()
        try unsafe setImage.unsafeInvoke(image, true)
        #expect(renderer.recorded?.0 === image)
        #expect(renderer.recorded?.1 == true)
        try unsafe setImage.unsafeInvoke(nil, false)
        #expect(renderer.recorded?.0 == nil)
        #expect(renderer.recorded?.1 == false)
        let refresh = try await object.method(selector: "refreshAnimated:", as: ((Bool) -> Bool).self)
        #expect(try unsafe refresh.unsafeInvoke(false))
    }

    @Test func zeroAndManyArguments() async throws {
        let object = ABIRuntime.shared.object(Renderer())
        let answer = try await object.method(selector: "answer", as: (() -> Int).self)
        #expect(try unsafe answer.unsafeInvoke() == 42)
        let mixed = try await object.method(
            selector: "mixed::::::::::",
            as: ((Int8, UInt16, Int32, UInt64, Float, Double, Bool, NSObject?, Int, Double) -> Double).self
        )
        #expect(try unsafe mixed.unsafeInvoke(-1, 2, 3, 4, 5.5, 6.25, true, NSObject(), 8, 9.75) == 39.5)
    }

    @Test func geometryAndRangeValues() async throws {
        let object = ABIRuntime.shared.object(Renderer())
        let rect = try await object.method(selector: "rectangle:", as: ((CGRect) -> CGRect).self)
        let value = CGRect(x: 1, y: 2, width: 3, height: 4)
        #expect(try unsafe rect.unsafeInvoke(value) == value)
        let point = try await object.method(selector: "point:", as: ((CGPoint) -> CGPoint).self)
        #expect(try unsafe point.unsafeInvoke(value.origin) == value.origin)
        let size = try await object.method(selector: "size:", as: ((CGSize) -> CGSize).self)
        #expect(try unsafe size.unsafeInvoke(value.size) == value.size)
        let range = try await object.method(selector: "range:", as: ((NSRange) -> NSRange).self)
        #expect(try unsafe range.unsafeInvoke(NSRange(location: 2, length: 7)) == NSRange(location: 2, length: 7))
    }

    @Test func objectResultsAndConversions() async throws {
        let object = ABIRuntime.shared.object(Renderer())
        let echo = try await object.method(selector: "echo:", as: ((NSObject?) -> NSObject?).self)
        let value = NSObject()
        #expect(try unsafe echo.unsafeInvoke(value) === value)
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)
        let bridge = try await object.method(selector: "echo:", as: ((String?) -> String?).self)
        #expect(try unsafe bridge.unsafeInvoke("value") == "value")
        #expect(try unsafe bridge.unsafeInvoke(nil) == nil)
        let nonoptional = try await object.method(selector: "echo:", as: ((NSObject?) -> NSObject).self)
        #expect(throws: ABIInvocationError.self) { try unsafe nonoptional.unsafeInvoke(nil) }
        let mismatch = try await object.method(selector: "echo:", as: ((NSObject) -> NSString).self)
        #expect(throws: ABIInvocationError.self) { try unsafe mismatch.unsafeInvoke(value) }
    }

    @Test func pointersAndNil() async throws {
        let object = ABIRuntime.shared.object(Renderer())
        let echo = try await object.method(
            selector: "pointer:", as: ((UnsafeMutablePointer<Int>?) -> UnsafeMutablePointer<Int>?).self
        )
        let memory = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { memory.deallocate() }
        #expect(try unsafe echo.unsafeInvoke(memory) == memory)
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)
    }

    @Test func boundMethodRetainsReceiver() async throws {
        var receiver: Renderer? = Renderer()
        weak var weakReceiver = receiver
        var method: NativeMethod<Int>? = try await ABIRuntime.shared.object(receiver!).method(
            selector: "answer", as: (() -> Int).self
        )
        receiver = nil
        #expect(weakReceiver != nil)
        #expect(try unsafe method?.unsafeInvoke() == 42)
        method = nil
        #expect(weakReceiver == nil)
    }

    @Test func invalidSignaturesThrowBeforeInvocation() async throws {
        let object = ABIRuntime.shared.object(Renderer())
        await #expect(throws: (any Error).self) {
            _ = try await object.method(selector: "absent", as: (() -> Void).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await object.method(selector: "answer", as: ((Int) -> Int).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await object.method(selector: "answer", as: (() -> Double).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await object.method(selector: "answer", as: (() -> UInt).self)
        }
    }

    @Test func objectOwnershipConventionsAndOverrides() async throws {
        let fixture = ABIOwnershipFixture()
        let object = ABIRuntime.shared.object(fixture)
        for (selector, override) in [
            ("object", nil), ("copyObject", nil),
            ("retainedObject", true), ("newBorrowedObject", false),
        ] as [(String, Bool?)] {
            let method = try await object.method(
                selector: selector, as: (() -> NSObject).self,
                options: .init(returnsRetainedObject: override)
            )
            weak var weakResult: NSObject?
            try autoreleasepool {
                let result = try unsafe method.unsafeInvoke()
                weakResult = result
                #expect(fixture.liveResults == 1)
            }
            #expect(weakResult == nil)
            #expect(fixture.liveResults == 0)
        }
    }

    @Test func initializersKeepOriginalReceiverAlive() async throws {
        for selector in ["initWithReplacement", "initReturningNil"] {
            var receiver: ABIInitializerFixture? = ABIInitializerFixture()
            weak var original = receiver
            var method: NativeMethod<ABIInitializerFixture?>? = try await ABIRuntime.shared.object(receiver!).method(
                selector: selector, as: (() -> ABIInitializerFixture?).self
            )
            receiver = nil
            #expect(original != nil)
            let result = try unsafe method!.unsafeInvoke()
            if selector == "initWithReplacement" {
                #expect(result != nil)
                #expect(result !== original)
            } else {
                #expect(result == nil)
            }
            #expect(original != nil)
            method = nil
            #expect(original == nil)
        }
    }

    @Test func characterBooleanClassAndSelector() async throws {
        let object = ABIRuntime.shared.object(ABIOwnershipFixture())
        let negate = try await object.method(
            selector: "negateCharacterBoolean:", as: ((Bool) -> Bool).self
        )
        #expect(try unsafe negate.unsafeInvoke(false))
        #expect(try unsafe !negate.unsafeInvoke(true))
        let cls = try await object.method(selector: "echoClass:", as: ((AnyClass) -> AnyClass).self)
        #expect(try unsafe cls.unsafeInvoke(NSString.self) === NSString.self)
        let sel = try await object.method(selector: "echoSelector:", as: ((Selector) -> Selector).self)
        let selector = NSSelectorFromString("answer")
        #expect(try unsafe sel.unsafeInvoke(selector) == selector)
    }

    @Test func forwardingUsesNormalDispatch() async throws {
        let method = try await ABIRuntime.shared.object(ABIForwardingFixture()).method(
            selector: "answer", as: (() -> Int).self
        )
        #expect(try unsafe method.unsafeInvoke() == 61)
    }

    @Test func runtimeMethodWithoutOffsets() async throws {
        let className = "ABIInvocationDynamic_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cls = try #require(objc_allocateClassPair(NSObject.self, className, 0))
        let implementation: @convention(block) (AnyObject) -> Int = { _ in 73 }
        let imp = imp_implementationWithBlock(implementation)
        #expect(class_addMethod(cls, NSSelectorFromString("dynamicAnswer"), imp, "q@:"))
        objc_registerClassPair(cls)
        // Registered classes and their implementations live for this test process.
        let receiver = try #require(class_createInstance(cls, 0))
        let answer = try await ABIRuntime.shared.object(receiver as AnyObject).method(
            selector: "dynamicAnswer", as: (() -> Int).self
        )
        #expect(try unsafe answer.unsafeInvoke() == 73)
    }
}
