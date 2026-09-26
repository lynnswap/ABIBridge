import ABIBridge
import Foundation
import CoreGraphics
import ObjectiveC
import ObjectiveCFixtures
import Testing

private final class ReplacementBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}
private enum ReplacementFailure: Error { case deliberate }
private final class ReplacementCapture: @unchecked Sendable {}
private final class ReplacementCodeOwner {
    let implementation: IMP
    init() {
        let body: @convention(block) (AnyObject, Int32, Int32) -> Int32 = { _, a, b in a + b + 100 }
        implementation = imp_implementationWithBlock(body)
    }
    deinit { imp_removeBlock(implementation) }
}
private final class RequiredReplacementObject: NSObject {}

// Only this isolated fixture class is modified, and each test restores the
// method. Registration, inherited dispatch, and chains belong to issue #111.
private func withReplacement<Result, each Argument, Output>(
    _ entry: ObjCReplacement<Result, repeat each Argument>,
    on type: AnyClass = ABIReplacementFixture.self, selector: String,
    classMethod: Bool = false, body: () throws -> Output
) throws -> Output {
    let target = classMethod ? try #require(object_getClass(type)) : type
    let selector = NSSelectorFromString(selector)
    let method = try #require(class_getInstanceMethod(target, selector))
    let previous = method_getImplementation(method)
    class_replaceMethod(target, selector, entry.publishImplementation(), method_getTypeEncoding(method))
    defer {
        class_replaceMethod(target, selector, previous, method_getTypeEncoding(method))
        entry.invalidate()
    }
    return try body()
}

@Suite(.serialized)
struct ObjectiveCReplacementTests {
    @Test func scalarReceiverAndModifiedArguments() throws {
        let errors = ReplacementBox<[String]>([])
        let entry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { error in errors.update { $0.append(String(describing: error)) } }) { call, a, b in
            #expect(try call.receiver is ABIReplacementFixture)
            return try call.proceed(a + 1, b) * 2
        }
        try withReplacement(entry, selector: "add:to:") {
            let receiver = ABIReplacementFixture()
            #expect(receiver.add(20, to: 21) == 84)
            #expect(receiver.calls == 1)
        }
        #expect(errors.read().isEmpty)
    }

    @Test func narrowAndStructureResults() throws {
        let narrow = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "negate:",
            as: ((Int8) -> Int8).self, onFailure: { Issue.record($0) }) { call, value in try call.proceed(value) }
        try withReplacement(narrow, selector: "negate:") {
            #expect(ABIReplacementFixture().negate(100) == -100)
            #expect(ABIReplacementFixture().negate(-100) == 100)
        }
        let size = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "resize:",
            as: ((CGSize) -> CGSize).self, onFailure: { Issue.record($0) }) { call, value in try call.proceed(value) }
        try withReplacement(size, selector: "resize:") {
            #expect(ABIReplacementFixture().resize(CGSize(width: 3, height: 5)) == CGSize(width: 4, height: 7))
        }
        let rect = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "translate:",
            as: ((CGRect) -> CGRect).self, onFailure: { Issue.record($0) }) { call, value in try call.proceed(value) }
        try withReplacement(rect, selector: "translate:") {
            #expect(ABIReplacementFixture().translate(CGRect(x: 1, y: 2, width: 3, height: 4)) == CGRect(x: 4, y: 7, width: 3, height: 4))
        }
    }

    @Test func twelveMixedArgumentsUseCompilerABI() throws {
        let fixture = ABIReplacementFixture()
        func oracle() -> Double {
            fixture.mixed(-2, b: 4, c: 1.5, d: 2.5, e: 9, f: UnsafeMutableRawPointer(bitPattern: 16),
                          g: CGSize(width: 5, height: 7), h: CGRect(x: 1, y: 2, width: 3, height: 4),
                          i: true, j: 12, k: 13.5, l: 14.5)
        }
        let expected = oracle()
        let selector = "mixed:b:c:d:e:f:g:h:i:j:k:l:"
        let entry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: selector,
            as: ((Int8, UInt16, Float, Double, Int, UnsafeMutableRawPointer?, CGSize, CGRect, Bool, Int64, Float, Double) -> Double).self,
            onFailure: { Issue.record($0) }) { call, a, b, c, d, e, f, g, h, i, j, k, l in
                try call.proceed(a, b, c, d, e, f, g, h, i, j, k, l) + 1
            }
        try withReplacement(entry, selector: selector) { #expect(oracle() == expected + 1) }
    }

    @Test func nullableObjectsVoidAndClassValues() throws {
        let echo = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "echo:",
            as: ((NSObject?) -> NSObject?).self, onFailure: { Issue.record($0) }) { call, value in try call.proceed(value) }
        try withReplacement(echo, selector: "echo:") {
            let receiver = ABIReplacementFixture()
            let object = NSObject()
            #expect(receiver.echo(object) as AnyObject === object)
            #expect(receiver.echo(nil) == nil)
        }
        let accept = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "accept:",
            as: ((AnyObject?) -> Void).self, onFailure: { Issue.record($0) }) { call, value in try call.proceed(value) }
        try withReplacement(accept, selector: "accept:") {
            let receiver = ABIReplacementFixture()
            receiver.accept(nil)
            #expect(receiver.calls == 1)
        }
        let cls = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "echoClass:",
            as: ((AnyClass) -> AnyClass).self, onFailure: { Issue.record($0) }) { call, value in try call.proceed(value) }
        try withReplacement(cls, selector: "echoClass:") {
            #expect(ABIReplacementFixture().echo(NSString.self) === NSString.self)
        }
        let classEntry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "answer",
            as: (() -> Int32).self, classMethod: true, onFailure: { Issue.record($0) }) { call in try call.proceed() + 1 }
        try withReplacement(classEntry, selector: "answer", classMethod: true) { #expect(ABIReplacementFixture.answer() == 43) }
    }

    @Test func resultOwnershipMatchesCompilerFamilies() throws {
        let fixture = ABIReplacementFixture()
        for (selector, retained) in [("object", nil), ("copyObject", nil), ("retainedObject", true), ("newBorrowedObject", false)] as [(String, Bool?)] {
            let entry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: selector,
                as: (() -> NSObject).self, options: .init(returnsRetainedObject: retained),
                onFailure: { Issue.record($0) }) { call in try call.proceed() }
            try withReplacement(entry, selector: selector) {
                weak var observed: NSObject?
                autoreleasepool {
                    let value: NSObject
                    switch selector {
                    case "copyObject": value = fixture.copyObject()
                    case "retainedObject": value = fixture.retainedObject()
                    case "newBorrowedObject": value = fixture.newBorrowedObject()
                    default: value = fixture.object()
                    }
                    observed = value
                    #expect(fixture.liveResults == 1)
                }
                #expect(observed == nil && fixture.liveResults == 0)
            }
        }
    }

    @Test func blockArgumentsEscapeAndResultsPreserveOwnership() throws {
        typealias Block = @convention(block) (Int32) -> Int32
        let entry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "apply:block:",
            as: ((Int32, Block?) -> Int32).self, onFailure: { Issue.record($0) }) { call, value, block in try call.proceed(value, block) }
        let receiver = ABIReplacementFixture()
        try withReplacement(entry, selector: "apply:block:") {
            var capture: ReplacementCapture? = ReplacementCapture()
            weak var observed = capture
            autoreleasepool {
                let block: Block = { [capture] value in withExtendedLifetime(capture) { value + 2 } }
                #expect(receiver.apply(40, block: block) == 42)
            }
            capture = nil
            #expect(observed != nil)
            #expect(receiver.storedBlock?(5) == 7)
            receiver.storedBlock = nil
            #expect(observed == nil)
            #expect(receiver.apply(0, block: nil) == -1)
        }
        for (selector, retained) in [("block", false), ("retainedBlock", true)] {
            let result = try ObjCReplacement(on: ABIReplacementFixture.self, selector: selector,
                as: (() -> Block).self, options: .init(returnsRetainedObject: retained),
                onFailure: { Issue.record($0) }) { call in try call.proceed() }
            try withReplacement(result, selector: selector) {
                let block = retained ? receiver.retainedBlock() : receiver.block()
                #expect(block(2) == (retained ? 22 : 12))
            }
        }
    }

    @Test func callbackFailuresDoNotReplayNativeSideEffects() throws {
        for after in [false, true] {
            let errors = ReplacementBox(0)
            let entry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "add:to:",
                as: ((Int32, Int32) -> Int32).self, onFailure: { _ in errors.update { $0 += 1 } }) { call, a, b in
                if after { _ = try call.proceed(a, b) }
                throw ReplacementFailure.deliberate
            }
            try withReplacement(entry, selector: "add:to:") {
                let receiver = ABIReplacementFixture()
                #expect(receiver.add(20, to: 22) == 42)
                #expect(receiver.calls == 1)
            }
            #expect(errors.read() == 1)
        }
    }

    @Test func failedInputAndOutputConversionsPreserveNativeValues() throws {
        let errors = ReplacementBox(0)
        let input = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "echo:",
            as: ((RequiredReplacementObject?) -> AnyObject?).self, onFailure: { _ in errors.update { $0 += 1 } }) { call, value in
                try call.proceed(value)
            }
        try withReplacement(input, selector: "echo:") {
            let receiver = ABIReplacementFixture()
            let number = NSNumber(value: 42)
            #expect(receiver.echo(number) as? NSNumber == number)
            #expect(receiver.calls == 1)
        }
        let output = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "object",
            as: (() -> String).self, onFailure: { _ in errors.update { $0 += 1 } }) { call in try call.proceed() }
        try withReplacement(output, selector: "object") {
            let receiver = ABIReplacementFixture()
            autoreleasepool { #expect(receiver.object().isKind(of: NSObject.self)) }
            #expect(receiver.liveResults == 0)
        }
        #expect(errors.read() == 2)
    }

    @Test func savedInvocationExpiresAndPublishedIMPOutlivesItsOwner() throws {
        let saved = ReplacementBox<NativeObjCMethodInvocation<Int32, Int32, Int32>?>(nil)
        var capture: ReplacementCapture? = ReplacementCapture()
        weak var observed = capture
        var entry: ObjCReplacement<Int32, Int32, Int32>? = try ObjCReplacement(on: ABIReplacementFixture.self,
            selector: "add:to:", as: ((Int32, Int32) -> Int32).self,
            onFailure: { Issue.record($0) }) { [capture] call, a, b in
                saved.update { $0 = call }
                return try withExtendedLifetime(capture) { try call.proceed(a, b) + 1 }
            }
        capture = nil
        let imp = try #require(entry).publishImplementation()
        let receiver = ABIReplacementFixture()
        #expect(ABIReplacementCallAdd(imp, receiver, 20, 21) == 42)
        let expired = try #require(saved.read())
        #expect(throws: NativeObjCMethodHookError.expiredInvocation) { try expired.proceed(1, 2) }
        entry = nil
        #expect(observed == nil)
        #expect(ABIReplacementCallAdd(imp, receiver, 20, 22) == 42)
    }

    @Test func unpublishedEntriesReleaseCaptures() throws {
        var capture: ReplacementCapture? = ReplacementCapture()
        weak var observed = capture
        var entry: ObjCReplacement<Int32, Int32, Int32>? = try ObjCReplacement(on: ABIReplacementFixture.self,
            selector: "add:to:", as: ((Int32, Int32) -> Int32).self,
            onFailure: { Issue.record($0) }) { [capture] call, a, b in
                try withExtendedLifetime(capture) { try call.proceed(a, b) }
            }
        capture = nil
        #expect(entry != nil && observed != nil)
        entry = nil
        #expect(observed == nil)
    }

    @Test func generatedFallbackCodeHasAnIndependentOwner() throws {
        var owner: ReplacementCodeOwner? = ReplacementCodeOwner()
        weak var observed = owner
        let selector = NSSelectorFromString("add:to:")
        let method = try #require(class_getInstanceMethod(ABIReplacementFixture.self, selector))
        let previous = method_setImplementation(method, try #require(owner).implementation)
        defer { method_setImplementation(method, previous) }
        var entry: ObjCReplacement<Int32, Int32, Int32>? = try ObjCReplacement(on: ABIReplacementFixture.self,
            selector: "add:to:", as: ((Int32, Int32) -> Int32).self, retaining: owner,
            onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) + 1 }
        let cached = try #require(entry).publishImplementation()
        method_setImplementation(method, previous)
        owner = nil
        #expect(ABIReplacementCallAdd(cached, ABIReplacementFixture(), 20, 21) == 142)
        entry = nil
        #expect(observed != nil)
        #expect(ABIReplacementCallAdd(cached, ABIReplacementFixture(), 20, 22) == 142)
    }

    @Test func inFlightCallbacksKeepCapturesAndRejectCrossThreadContinuation() throws {
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let saved = ReplacementBox<NativeObjCMethodInvocation<Int32, Int32, Int32>?>(nil)
        let result = ReplacementBox<Int32>(0)
        var capture: ReplacementCapture? = ReplacementCapture()
        weak var observed = capture
        let entry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { [capture] call, a, b in
                saved.update { $0 = call }
                started.signal()
                resume.wait()
                return try withExtendedLifetime(capture) { try call.proceed(a, b) + 1 }
            }
        capture = nil
        try withReplacement(entry, selector: "add:to:") {
            // This callback deliberately blocks. Give it a dedicated thread
            // so unrelated tests cannot exhaust the pool it needs to enter.
            finished.enter()
            let worker = Thread {
                defer { finished.leave() }
                result.update { $0 = ABIReplacementFixture().add(20, to: 21) }
            }
            worker.qualityOfService = .userInitiated
            worker.start()
            // Join before restoring the method even if a requirement throws;
            // a late call must never enter another test's replacement.
            defer { resume.signal(); finished.wait() }
            started.wait()
            let invocation = try #require(saved.read())
            #expect(throws: NativeObjCMethodHookError.wrongThread) { try invocation.proceed(1, 2) }
            entry.invalidate()
            #expect(observed != nil)
            resume.signal()
            finished.wait()
            #expect(result.read() == 42)
            #expect(observed == nil)
            #expect(ABIReplacementFixture().add(20, to: 22) == 42)
        }
    }

    @Test func concurrentCallsHaveIndependentFramesAndCanInvalidateInsideCallback() throws {
        let invocations = ReplacementBox(0)
        let invalidator = ReplacementBox<(() -> Void)?>(nil)
        let entry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "resize:",
            as: ((CGSize) -> CGSize).self, onFailure: { Issue.record($0) }) { call, value in
                invocations.update { $0 += 1 }
                if value.width == -1 { invalidator.read()?() }
                return try call.proceed(value)
            }
        invalidator.update { $0 = { entry.invalidate() } }
        defer { invalidator.update { $0 = nil } }
        try withReplacement(entry, selector: "resize:") {
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                let value = CGFloat(index)
                #expect(ABIReplacementFixture().resize(CGSize(width: value, height: value * 2)) == CGSize(width: value + 1, height: value * 2 + 2))
            }
            #expect(invocations.read() == 100)
            #expect(ABIReplacementFixture().resize(CGSize(width: -1, height: 0)) == CGSize(width: 0, height: 2))
            #expect(ABIReplacementFixture().resize(.zero) == CGSize(width: 1, height: 2))
            #expect(invocations.read() == 101)
        }
    }

    @Test func initializersBalanceSameNilAndReplacementResults() throws {
        let before = ReplacementBox(0)
        let after = ReplacementBox(0)
        let entry = try ObjCReplacement(initializerOn: ABIReplacementInitializer.self, selector: "initWithMode:",
            as: ((Int) -> ABIReplacementInitializer?).self, onFailure: { Issue.record($0) },
            before: { _ in before.update { $0 += 1 } }, after: { _ in after.update { $0 += 1 } })
        try withReplacement(entry, on: ABIReplacementInitializer.self, selector: "initWithMode:") {
            for mode in 0...2 {
                let start = ABIReplacementInitializer.initializations
                weak var observed: ABIReplacementInitializer?
                autoreleasepool {
                    let value = ABIReplacementInitializer(mode: mode)
                    observed = value
                    #expect((value == nil) == (mode == 1))
                    #expect(ABIReplacementInitializer.liveObjects == (mode == 1 ? 0 : 1))
                    if mode == 2, let value { #expect(type(of: value) != ABIReplacementInitializer.self) }
                }
                #expect(observed == nil && ABIReplacementInitializer.liveObjects == 0)
                #expect(ABIReplacementInitializer.initializations - start == (mode == 2 ? 2 : 1))
            }
        }
        #expect(before.read() == 4 && after.read() == 4)
    }

    @Test func initializerFailuresAndSuperDelegationDoNotRepeatInitialization() throws {
        for failsAfter in [false, true] {
            let errors = ReplacementBox(0)
            let entry = try ObjCReplacement(initializerOn: ABIReplacementInitializer.self, selector: "initWithMode:",
                as: ((Int) -> ABIReplacementInitializer?).self, onFailure: { _ in errors.update { $0 += 1 } },
                before: { _ in if !failsAfter { throw ReplacementFailure.deliberate } },
                after: { _ in if failsAfter { throw ReplacementFailure.deliberate } })
            try withReplacement(entry, on: ABIReplacementInitializer.self, selector: "initWithMode:") {
                let start = ABIReplacementInitializer.initializations
                autoreleasepool { #expect(ABIReplacementInitializerChild(mode: 0) != nil) }
                #expect(ABIReplacementInitializer.initializations - start == 1)
                #expect(ABIReplacementInitializer.liveObjects == 0)
            }
            #expect(errors.read() == 1)
        }
    }

    @MainActor @Test func mainActorCallbackAndOffThreadBypass() throws {
        let calls = ReplacementBox(0)
        let errors = ReplacementBox(0)
        let entry = try ObjCReplacement(mainActorOn: ABIReplacementFixture.self, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { _ in errors.update { $0 += 1 } }) { call, a, b in
                MainActor.assertIsolated()
                calls.update { $0 += 1 }
                return try call.proceed(a, b) + 1
            }
        try withReplacement(entry, selector: "add:to:") {
            #expect(ABIReplacementFixture().add(20, to: 21) == 42)
            let result = ReplacementBox<Int32>(0)
            let done = DispatchSemaphore(value: 0)
            let worker = Thread {
                defer { done.signal() }
                result.update { $0 = ABIReplacementFixture().add(20, to: 22) }
            }
            worker.qualityOfService = .userInitiated
            worker.start()
            done.wait()
            #expect(result.read() == 42)
        }
        #expect(calls.read() == 1 && errors.read() == 1)
    }

    @Test func invalidSignaturesAndInitializerModeFailBeforePublication() throws {
        #expect(throws: (any Error).self) {
            _ = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "resize:", as: ((Int32) -> Int32).self,
                onFailure: { _ in }) { call, value in try call.proceed(value) }
        }
        #expect(throws: ObjCReplacementError.initializerRequiresDedicatedCallback) {
            _ = try ObjCReplacement(on: ABIReplacementInitializer.self, selector: "initWithMode:",
                as: ((Int) -> ABIReplacementInitializer?).self, onFailure: { _ in }) { call, mode in try call.proceed(mode) }
        }
    }

    @Test func replacementEntryBenchmark() throws {
        let count = 10_000
        let receiver = ABIReplacementFixture()
        let clock = ContinuousClock()
        let start = clock.now
        for index in 0..<count { _ = receiver.add(Int32(index), to: 1) }
        let direct = start.duration(to: clock.now)
        let entry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) }
        try withReplacement(entry, selector: "add:to:") {
            let start = clock.now
            for index in 0..<count { _ = receiver.add(Int32(index), to: 1) }
            let callback = start.duration(to: clock.now)
            entry.invalidate()
            let bypassStart = clock.now
            for index in 0..<count { _ = receiver.add(Int32(index), to: 1) }
            print("ObjC replacement \(count) calls: direct=\(direct), callback=\(callback), inactive=\(bypassStart.duration(to: clock.now))")
        }
        let size = CGSize(width: 3, height: 5)
        let sizeStart = clock.now
        for _ in 0..<count { _ = receiver.resize(size) }
        let sizeDirect = sizeStart.duration(to: clock.now)
        let sizeEntry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "resize:",
            as: ((CGSize) -> CGSize).self, onFailure: { Issue.record($0) }) { call, value in try call.proceed(value) }
        try withReplacement(sizeEntry, selector: "resize:") {
            let start = clock.now
            for _ in 0..<count { _ = receiver.resize(size) }
            print("ObjC replacement CGSize \(count) calls: direct=\(sizeDirect), callback=\(start.duration(to: clock.now))")
        }
        let objectStart = clock.now
        autoreleasepool { for _ in 0..<count { _ = receiver.object() } }
        let objectDirect = objectStart.duration(to: clock.now)
        let objectEntry = try ObjCReplacement(on: ABIReplacementFixture.self, selector: "object",
            as: (() -> NSObject).self, onFailure: { Issue.record($0) }) { call in try call.proceed() }
        try withReplacement(objectEntry, selector: "object") {
            let start = clock.now
            autoreleasepool { for _ in 0..<count { _ = receiver.object() } }
            print("ObjC replacement object \(count) calls: direct=\(objectDirect), callback=\(start.duration(to: clock.now))")
        }
        #expect(receiver.liveResults == 0)
    }
}
