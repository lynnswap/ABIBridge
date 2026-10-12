import ABIBridge
import CoreGraphics
import Foundation
import ObjectiveC
import ObjectiveCFixtures
import Testing

private class Renderer: NSObject {
    var recorded: (NSObject?, Bool)?
    @objc func answer() -> Int { 42 }
    @objc func increment(_ value: Int64) -> Int64 { value + 1 }
    @objc func refreshAnimated(_ animated: Bool) -> Bool { !animated }
    @objc func setImage(_ image: NSObject?, animated: Bool) { recorded = (image, animated) }
    @objc func echo(_ object: NSObject?) -> NSObject? { object }
    @objc func range(_ range: NSRange) -> NSRange { range }
    @objc func rectangle(_ rect: CGRect) -> CGRect { rect }
    @objc func point(_ point: CGPoint) -> CGPoint { point }
    @objc func size(_ size: CGSize) -> CGSize { size }
    @objc func pointer(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? { pointer }
    @objc func mixed(
        _ a: Int8,
        _ b: UInt16,
        _ c: Int32,
        _ d: UInt64,
        _ e: Float,
        _ f: Double,
        _ g: Bool,
        _ h: NSObject?,
        _ i: Int,
        _ j: Double
    ) -> Double {
        Double(a) + Double(b) + Double(c) + Double(d) + Double(e) + f
            + (g ? 1 : 0) + (h == nil ? 0 : 1) + Double(i) + j
    }
}

struct ObjectiveCInvocationTests {
    @MainActor @Test func asynchronousClassResolutionRunsAwayFromMainActor() async throws {
        let method = try await ABIRuntime().resolveObjCImplementation(
            on: ABIWorkerLookupFixture.self,
            selector: "workerIncrement:",
            as: ((Int) -> Int).self
        )
        #expect(!ABIWorkerLookupFixture.resolutionRequestedOnMainThread)
        #expect(try unsafe method.unsafeInvoke(on: ABIWorkerLookupFixture(), 41) == 42)
    }

    @MainActor @Test func asynchronousLookupKeepsBoundReceiversAndOwnersOnCaller() async throws {
        let runtime = ABIRuntime()
        let receiver = Renderer()
        let owner = NSObject()
        let selector = #selector(Renderer.increment(_:))
        let bound = try await runtime.object(receiver).resolveMethod(
            selector: selector,
            as: ((Int64) -> Int64).self
        )
        let message = try await runtime.resolveObjCMethod(
            on: Renderer.self,
            selector: selector,
            as: ((Int64) -> Int64).self,
            retaining: owner
        )
        let captured = try await runtime.resolveObjCImplementation(
            on: Renderer.self,
            selector: selector,
            as: ((Int64) -> Int64).self,
            retaining: owner
        )
        #expect(try unsafe bound.unsafeInvoke(41) == 42)
        #expect(try unsafe message.unsafeInvoke(on: receiver, 41) == 42)
        #expect(try unsafe captured.unsafeInvoke(on: receiver, 41) == 42)
    }

    @MainActor @Test func asynchronousForwardingLookupPreservesReceiverIsolation() async throws {
        let receiver = ABIForwardingFixture()
        let method = try await ABIRuntime().object(receiver).resolveMethod(
            selector: "answer",
            as: (() -> Int).self
        )
        #expect(receiver.signatureRequestedOnMainThread)
        #expect(receiver.forwardedCalls == 0)
        #expect(try unsafe method.unsafeInvoke() == 61)
        #expect(receiver.forwardedCalls == 1)
    }

    @MainActor
    @Test(
        arguments: ["bound", "captured"],
        ["missing", "argument", "result", "count"]
    )
    func lookupFailuresShareCategoriesAndContext(_ path: String, _ failure: String) throws {
        let runtime = ABIRuntime.shared
        let object = runtime.object(Renderer())
        let selector = failure == "missing" ? "missing" : "increment:"
        let declaration = NativeDeclaration(
            name: "-[\(NSStringFromClass(Renderer.self)) \(selector)]",
            language: .objectiveC
        )
        func prepare<Result, each Argument>(
            _ signature: ((repeat each Argument) -> Result).Type
        ) throws {
            if path == "bound" {
                _ = try object.resolveMethodAndWait(selector: selector, as: signature)
            } else {
                _ = try runtime.resolveObjCImplementationAndWait(
                    on: Renderer.self,
                    selector: selector,
                    as: signature
                )
            }
        }
        do {
            switch failure {
            case "missing": try prepare((() -> Void).self)
            case "argument": try prepare(((Double) -> Int64).self)
            case "result": try prepare(((Int64) -> Double).self)
            default: try prepare((() -> Int64).self)
            }
            Issue.record("Invalid lookup unexpectedly succeeded")
        } catch let ABIResolutionError.declarationNotFound(request) {
            #expect(failure == "missing")
            #expect(request == declaration)
        } catch let ABIResolutionError.signatureMismatch(details) {
            #expect(details.declaration == declaration)
            if failure == "count" {
                #expect(details.position == .argumentCount)
                #expect(details.expected == "0 arguments")
                #expect(details.found == ["1 arguments"])
            } else {
                #expect(details.position == (failure == "argument" ? .argument(0) : .result))
                #expect(details.expected == "Swift.Double")
                #expect(details.found == ["q"])
            }
        }
    }

    @MainActor @Test(arguments: [false, true], [false, true])
    func hookPreparationPreservesLookupCause(_ coordinated: Bool, _ missing: Bool) throws {
        let runtime = ABIRuntime.shared
        let selector = missing ? "missing" : "increment:"
        func prepare() throws {
            if coordinated {
                let request = unsafe NativeObjCHookRequest.method(
                    on: Renderer.self,
                    selector: selector,
                    as: ((Double) -> Int64).self,
                    onFailure: { Issue.record($0) },
                    body: { call, value in try call.proceed(value) }
                )
                do {
                    let tokens = try unsafe runtime.installHooks([request])
                    tokens.forEach { $0.invalidate() }
                } catch let error as NativeObjCHookInstallationError {
                    #expect(error.phase == .preparation)
                    #expect(error.failedIndex == 0 && error.invalidatedHooks.isEmpty)
                    throw error.underlyingError
                }
            } else {
                let token = try unsafe runtime.hookMethod(
                    on: Renderer.self,
                    selector: selector,
                    as: ((Double) -> Int64).self,
                    onFailure: { Issue.record($0) },
                    body: { call, value in try call.proceed(value) }
                )
                token.invalidate()
            }
        }
        let declaration = NativeDeclaration(
            name: "-[\(NSStringFromClass(Renderer.self)) \(selector)]",
            language: .objectiveC
        )
        do {
            try prepare()
            Issue.record("Invalid hook preparation unexpectedly succeeded")
        } catch let ABIResolutionError.declarationNotFound(request) {
            #expect(missing && request == declaration)
        } catch let ABIResolutionError.signatureMismatch(details) {
            #expect(!missing)
            #expect(details.declaration == declaration && details.position == .argument(0))
            #expect(details.expected == "Swift.Double" && details.found == ["q"])
        }
    }

    @Test func missingClassMethodKeepsClassRequest() throws {
        do {
            _ = try ABIRuntime.shared.object(Renderer.self).resolveMethodAndWait(
                selector: "missingClassMethod",
                as: (() -> Void).self
            )
            Issue.record("An absent class method unexpectedly resolved")
        } catch let ABIResolutionError.declarationNotFound(request) {
            #expect(request.name == "+[\(NSStringFromClass(Renderer.self)) missingClassMethod]")
        }
    }

    @MainActor @Test func callerIsolationAndOptionalArguments() throws {
        let renderer = Renderer()
        let object = ABIRuntime.shared.object(renderer)
        let setImage = try object.resolveMethodAndWait(
            selector: "setImage:animated:",
            as: ((NSObject?, Bool) -> Void).self
        )
        let image = NSObject()
        try unsafe setImage.unsafeInvoke(image, true)
        #expect(renderer.recorded?.0 === image)
        #expect(renderer.recorded?.1 == true)
        try unsafe setImage.unsafeInvoke(nil, false)
        #expect(renderer.recorded?.0 == nil)
        #expect(renderer.recorded?.1 == false)
        let refresh = try object.resolveMethodAndWait(
            selector: "refreshAnimated:",
            as: ((Bool) -> Bool).self
        )
        #expect(try unsafe refresh.unsafeInvoke(false))
    }

    @Test func zeroAndManyArguments() throws {
        let object = ABIRuntime.shared.object(Renderer())
        let answer = try object.resolveMethodAndWait(selector: "answer", as: (() -> Int).self)
        #expect(try unsafe answer.unsafeInvoke() == 42)
        let mixed = try object.resolveMethodAndWait(
            selector: "mixed::::::::::",
            as: ((Int8, UInt16, Int32, UInt64, Float, Double, Bool, NSObject?, Int, Double)
                -> Double).self
        )
        #expect(
            try unsafe mixed.unsafeInvoke(-1, 2, 3, 4, 5.5, 6.25, true, NSObject(), 8, 9.75) == 39.5
        )
    }

    @Test func geometryAndRangeValues() throws {
        let object = ABIRuntime.shared.object(Renderer())
        let rect = try object.resolveMethodAndWait(
            selector: "rectangle:",
            as: ((CGRect) -> CGRect).self
        )
        let value = CGRect(x: 1, y: 2, width: 3, height: 4)
        #expect(try unsafe rect.unsafeInvoke(value) == value)
        let point = try object.resolveMethodAndWait(
            selector: "point:",
            as: ((CGPoint) -> CGPoint).self
        )
        #expect(try unsafe point.unsafeInvoke(value.origin) == value.origin)
        let size = try object.resolveMethodAndWait(selector: "size:", as: ((CGSize) -> CGSize).self)
        #expect(try unsafe size.unsafeInvoke(value.size) == value.size)
        let range = try object.resolveMethodAndWait(
            selector: "range:",
            as: ((NSRange) -> NSRange).self
        )
        #expect(
            try unsafe range.unsafeInvoke(NSRange(location: 2, length: 7))
                == NSRange(location: 2, length: 7)
        )
    }

    @Test func objectResultsAndConversions() throws {
        let object = ABIRuntime.shared.object(Renderer())
        let echo = try object.resolveMethodAndWait(
            selector: "echo:",
            as: ((NSObject?) -> NSObject?).self
        )
        let value = NSObject()
        #expect(try unsafe echo.unsafeInvoke(value) === value)
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)
        let bridge = try object.resolveMethodAndWait(
            selector: "echo:",
            as: ((String?) -> String?).self
        )
        #expect(try unsafe bridge.unsafeInvoke("value") == "value")
        #expect(try unsafe bridge.unsafeInvoke(nil) == nil)
        let nonoptional = try object.resolveMethodAndWait(
            selector: "echo:",
            as: ((NSObject?) -> NSObject).self
        )
        #expect(throws: ABIInvocationError.self) { try unsafe nonoptional.unsafeInvoke(nil) }
        let mismatch = try object.resolveMethodAndWait(
            selector: "echo:",
            as: ((NSObject) -> NSString).self
        )
        #expect(throws: ABIInvocationError.self) { try unsafe mismatch.unsafeInvoke(value) }
    }

    @Test func pointersAndNil() throws {
        let object = ABIRuntime.shared.object(Renderer())
        let echo = try object.resolveMethodAndWait(
            selector: "pointer:",
            as: ((UnsafeMutablePointer<Int>?) -> UnsafeMutablePointer<Int>?).self
        )
        let memory = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { memory.deallocate() }
        #expect(try unsafe echo.unsafeInvoke(memory) == memory)
        #expect(try unsafe echo.unsafeInvoke(nil) == nil)
    }

    @Test func boundMethodRetainsReceiver() throws {
        var receiver: Renderer? = Renderer()
        weak var weakReceiver = receiver
        var method: NativeBoundObjCMethod<Int>? = try ABIRuntime.shared.object(receiver!)
            .resolveMethodAndWait(
                selector: "answer",
                as: (() -> Int).self
            )
        receiver = nil
        #expect(weakReceiver != nil)
        #expect(try unsafe method?.unsafeInvoke() == 42)
        method = nil
        #expect(weakReceiver == nil)
    }

    @Test func invalidSignaturesThrowBeforeInvocation() throws {
        let object = ABIRuntime.shared.object(Renderer())
        #expect(throws: (any Error).self) {
            _ = try object.resolveMethodAndWait(selector: "absent", as: (() -> Void).self)
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try object.resolveMethodAndWait(selector: "answer", as: ((Int) -> Int).self)
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try object.resolveMethodAndWait(selector: "answer", as: (() -> Double).self)
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try object.resolveMethodAndWait(selector: "answer", as: (() -> UInt).self)
        }
    }

    @Test func objectOwnershipConventionsAndOverrides() throws {
        let fixture = ABIOwnershipFixture()
        let object = ABIRuntime.shared.object(fixture)
        for (selector, override) in [
            ("object", nil), ("copyObject", nil),
            ("retainedObject", true), ("newBorrowedObject", false),
        ] as [(String, Bool?)] {
            let method = try object.resolveMethodAndWait(
                selector: selector,
                as: (() -> NSObject).self,
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

    @Test func initializersKeepOriginalReceiverAlive() throws {
        for selector in ["initWithReplacement", "initReturningNil"] {
            var receiver: ABIInitializerFixture? = ABIInitializerFixture()
            weak var original = receiver
            var method: NativeBoundObjCMethod<ABIInitializerFixture?>? = try ABIRuntime.shared
                .object(receiver!).resolveMethodAndWait(
                    selector: selector,
                    as: (() -> ABIInitializerFixture?).self
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

    @Test(arguments: ["bound", "message", "captured"])
    func consumedObjectArgumentsKeepCallerOwnership(_ path: String) throws {
        let fixture = ABIOwnershipFixture()
        let options = NativeMethodOptions(consumedArguments: [0])
        let signature = ((NSObject?) -> Int).self
        let bound = try ABIRuntime.shared.object(fixture).resolveMethodAndWait(
            selector: "consume:",
            as: signature,
            options: options
        )
        let message = try ABIRuntime.shared.resolveObjCMethodAndWait(
            on: ABIOwnershipFixture.self,
            selector: "consume:",
            as: signature,
            options: options
        )
        let captured = try ABIRuntime.shared.resolveObjCImplementationAndWait(
            on: ABIOwnershipFixture.self,
            selector: "consume:",
            as: signature,
            options: options
        )
        func invoke(_ value: NSObject?) throws -> Int {
            switch path {
            case "bound": return try unsafe bound.unsafeInvoke(value)
            case "message": return try unsafe message.unsafeInvoke(on: fixture, value)
            default: return try unsafe captured.unsafeInvoke(on: fixture, value)
            }
        }
        weak var observed: NSObject?
        try autoreleasepool {
            let value = fixture.copyObject()
            observed = value
            #expect(fixture.consume(value) == 1)
            for _ in 0..<4 {
                let result = try invoke(value)
                #expect(result == 1)
            }
            #expect(observed === value && fixture.liveResults == 1)
            let nilResult = try invoke(nil)
            #expect(nilResult == 0)
        }
        #expect(fixture.consumedCalls == 6)
        #expect(observed == nil && fixture.liveResults == 0)
    }

    @Test func consumedArgumentsAreNotTransferredBeforeConversionSucceeds() throws {
        let fixture = ABIOwnershipFixture()
        let method = try ABIRuntime.shared.object(fixture).resolveMethodAndWait(
            selector: "consume:withClass:",
            as: ((NSObject, NSObject) -> Int).self,
            options: .init(consumedArguments: [0])
        )
        weak var observed: NSObject?
        autoreleasepool {
            let value = fixture.copyObject()
            observed = value
            #expect(throws: ABIInvocationError.self) {
                try unsafe method.unsafeInvoke(value, NSObject())
            }
            #expect(observed === value && fixture.liveResults == 1)
        }
        #expect(fixture.consumedCalls == 0)
        #expect(observed == nil && fixture.liveResults == 0)
    }

    @Test func consumedArgumentValidationUsesNativeReferenceKinds() throws {
        let object = ABIRuntime.shared.object(ABIOwnershipFixture())
        for index in [-1, 1] {
            #expect(throws: ABIResolutionError.self) {
                _ = try object.resolveMethodAndWait(
                    selector: "consume:",
                    as: ((NSObject?) -> Int).self,
                    options: .init(consumedArguments: [index])
                )
            }
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try object.resolveMethodAndWait(
                selector: "negateCharacterBoolean:",
                as: ((Bool) -> Bool).self,
                options: .init(consumedArguments: [0])
            )
        }
    }

    @Test(arguments: ["bound", "captured"])
    func consumedBlocksAndInitializerInputsStayAlive(_ path: String) throws {
        typealias Block = @convention(block) (Int32) -> Int32
        let fixture = ABIOwnershipFixture()
        let blocks = ABIBlockFixture()
        let options = NativeMethodOptions(consumedArguments: [0])
        let bound = try ABIRuntime.shared.object(blocks).resolveMethodAndWait(
            selector: "consumeBlock:value:",
            as: ((Block?, Int32) -> Int32).self,
            options: options
        )
        let captured = try ABIRuntime.shared.resolveObjCImplementationAndWait(
            on: ABIBlockFixture.self,
            selector: "consumeBlock:value:",
            as: ((Block?, Int32) -> Int32).self,
            options: options
        )
        weak var observed: NSObject?
        try autoreleasepool {
            let value = fixture.copyObject()
            observed = value
            let block: Block = { [value] number in withExtendedLifetime(value) { number + 1 } }
            for _ in 0..<4 {
                let result =
                    path == "bound"
                    ? try unsafe bound.unsafeInvoke(block, 41)
                    : try unsafe captured.unsafeInvoke(on: blocks, block, 41)
                #expect(result == blocks.consumeBlock(block, value: 41))
            }
            let receiver = ABIInitializerFixture()
            let initialize = try ABIRuntime.shared.object(receiver).resolveMethodAndWait(
                selector: "initConsuming:",
                as: ((NSObject?) -> ABIInitializerFixture?).self,
                options: options
            )
            #expect(try unsafe initialize.unsafeInvoke(value) === receiver)
            #expect(observed === value && fixture.liveResults == 1)
        }
        #expect(observed == nil && fixture.liveResults == 0)
    }

    @Test func unmanagedCoreFoundationReferencesUsePointerEncoding() throws {
        let fixture = ABIOwnershipFixture()
        let echo = try ABIRuntime.shared.object(fixture).resolveMethodAndWait(
            selector: "echoCFValue:",
            as: ((Unmanaged<NSObject>?) -> Unmanaged<NSObject>?).self
        )
        weak var observed: NSObject?
        try autoreleasepool {
            let value = fixture.copyObject()
            observed = value
            let result = try unsafe echo.unsafeInvoke(.passUnretained(value))
            #expect(result?.takeUnretainedValue() === value)
            #expect(try unsafe echo.unsafeInvoke(nil) == nil)
        }
        #expect(observed == nil && fixture.liveResults == 0)
    }

    @Test func characterBooleanClassAndSelector() throws {
        let object = ABIRuntime.shared.object(ABIOwnershipFixture())
        let negate = try object.resolveMethodAndWait(
            selector: "negateCharacterBoolean:",
            as: ((Bool) -> Bool).self
        )
        #expect(try unsafe negate.unsafeInvoke(false))
        #expect(try unsafe !negate.unsafeInvoke(true))
        let cls = try object.resolveMethodAndWait(
            selector: "echoClass:",
            as: ((AnyClass) -> AnyClass).self
        )
        #expect(try unsafe cls.unsafeInvoke(NSString.self) === NSString.self)
        let sel = try object.resolveMethodAndWait(
            selector: "echoSelector:",
            as: ((Selector) -> Selector).self
        )
        let selector = NSSelectorFromString("answer")
        #expect(try unsafe sel.unsafeInvoke(selector) == selector)
    }

    @Test func unsupportedFoundationEncodingsThrowDuringLookup() throws {
        let object = ABIRuntime.shared.object(ABIOwnershipFixture())
        #expect(throws: ABIResolutionError.self) {
            _ = try object.resolveMethodAndWait(
                selector: "unionValue",
                as: (() -> ABIUnionFixture).self
            )
        }
        #expect(throws: ABIResolutionError.self) {
            _ = try object.resolveMethodAndWait(
                selector: "unionPointer:",
                as: ((UnsafeMutablePointer<ABIUnionFixture>) -> UnsafeMutablePointer<
                    ABIUnionFixture
                >).self
            )
        }
    }

    @Test func classValuesRemainDistinctFromInstances() throws {
        let fixture = ABIOwnershipFixture()
        let object = ABIRuntime.shared.object(fixture)
        let typed = try object.resolveMethodAndWait(
            selector: "echoClass:",
            as: ((NSString.Type?) -> NSString.Type?).self
        )
        #expect(try unsafe typed.unsafeInvoke(NSString.self) === NSString.self)
        #expect(try unsafe typed.unsafeInvoke(nil) == nil)
        let invalidArgument = try object.resolveMethodAndWait(
            selector: "echoClass:",
            as: ((NSObject) -> AnyClass).self
        )
        let calls = fixture.classCalls
        #expect(throws: ABIInvocationError.self) {
            try unsafe invalidArgument.unsafeInvoke(NSObject())
        }
        #expect(fixture.classCalls == calls)
        let invalidScalar = try object.resolveMethodAndWait(
            selector: "echoClass:",
            as: ((Int) -> AnyClass).self
        )
        #expect(throws: ABIInvocationError.self) { try unsafe invalidScalar.unsafeInvoke(42) }
        #expect(fixture.classCalls == calls)
        let invalidResult = try object.resolveMethodAndWait(
            selector: "echoClass:",
            as: ((AnyClass) -> NSObject).self
        )
        #expect(throws: ABIInvocationError.self) {
            try unsafe invalidResult.unsafeInvoke(NSString.self)
        }
    }

    @Test func forwardingUsesNormalDispatch() throws {
        let method = try ABIRuntime.shared.object(ABIForwardingFixture()).resolveMethodAndWait(
            selector: "answer",
            as: (() -> Int).self
        )
        #expect(try unsafe method.unsafeInvoke() == 61)
    }

    @Test func forwardedInvocationsRemainIndependentAfterLaterCalls() throws {
        let fixture = ABIEscapingForwardingFixture()
        let method = try ABIRuntime.shared.object(fixture).resolveMethodAndWait(
            selector: "remember:",
            as: ((Int) -> Int).self
        )
        #expect(try unsafe method.unsafeInvoke(10) == 11)
        #expect(try unsafe method.unsafeInvoke(20) == 21)
        #expect(fixture.savedArguments.map(\.intValue) == [10, 20])
    }

    @Test func runtimeMethodWithoutOffsets() throws {
        let className =
            "ABIInvocationDynamic_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cls = try #require(objc_allocateClassPair(NSObject.self, className, 0))
        let implementation: @convention(block) (AnyObject) -> Int = { _ in 73 }
        let imp = imp_implementationWithBlock(implementation)
        #expect(class_addMethod(cls, NSSelectorFromString("dynamicAnswer"), imp, "q@:"))
        objc_registerClassPair(cls)
        // Registered classes and their implementations live for this test process.
        let receiver = try #require(class_createInstance(cls, 0))
        let answer = try ABIRuntime.shared.object(receiver as AnyObject).resolveMethodAndWait(
            selector: "dynamicAnswer",
            as: (() -> Int).self
        )
        #expect(try unsafe answer.unsafeInvoke() == 73)
    }
}
