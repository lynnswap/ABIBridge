import ABIBridge
import CoreGraphics
import Foundation
import ObjectiveC
import ObjectiveCFixtures
import Testing

private final class HookBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
}
private enum HookFailure: Error { case deliberate }
private final class HookCapture: @unchecked Sendable {
    let onDeinit: @Sendable () -> Void
    init(_ onDeinit: @escaping @Sendable () -> Void = {}) { self.onDeinit = onDeinit }
    deinit { onDeinit() }
}

@Suite(.serialized)
struct ObjectiveCMethodHookTests {
    let runtime = ABIRuntime()

    @Test func orderingMiddleRemovalAndStableEntry() throws {
        let trace = HookBox<[Int]>([])
        func install(_ number: Int, increment: Int32) throws -> NativeObjCMethodHook {
            try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
                as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in
                    trace.update { $0.append(number) }
                    let result = try call.proceed(a + increment, b)
                    trace.update { $0.append(-number) }
                    return result
                }
        }
        let first = try install(1, increment: 1)
        defer { first.invalidate() }
        let method = try #require(class_getInstanceMethod(ABIManagedHookFixture.self, NSSelectorFromString("add:to:")))
        let dispatcher = method_getImplementation(method)
        let middle = try install(2, increment: 2)
        let last = try install(3, increment: 3)
        defer { middle.invalidate(); last.invalidate() }
        #expect(ABIManagedHookFixture().add(10, to: 20) == 36)
        #expect(trace.read() == [3, 2, 1, -1, -2, -3])
        middle.invalidate()
        trace.update { $0 = [] }
        #expect(ABIManagedHookFixture().add(10, to: 20) == 34)
        #expect(trace.read() == [3, 1, -1, -3])
        first.invalidate(); last.invalidate(); last.invalidate()
        #expect(last.status == .invalidated)
        #expect(method_getImplementation(method) == dispatcher)
        #expect(ABIReplacementCallAdd(dispatcher, ABIManagedHookFixture(), 20, 22) == 42)
        let again = try install(4, increment: 4)
        defer { again.invalidate() }
        #expect(method_getImplementation(method) == dispatcher)
        #expect(ABIManagedHookFixture().add(10, to: 20) == 34)
    }

    @Test func ordinaryMethodsCanSkipOrRepeatContinuation() throws {
        let hook = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in
                if a == 0 { return 99 }
                return try call.proceed(a, b) + call.proceed(a, b)
            }
        defer { hook.invalidate() }
        let object = ABIManagedHookFixture()
        #expect(object.add(0, to: 2) == 99 && object.calls == 0)
        #expect(object.add(20, to: 1) == 42 && object.calls == 2)
    }

    @Test func inheritedPassThroughFollowsCurrentSuperclass() throws {
        let child = try unsafe runtime.hookMethod(on: ABIHookChild.self, selector: "value", as: (() -> Int).self,
            onFailure: { Issue.record($0) }) { call in try call.proceed() + 1 }
        defer { child.invalidate() }
        #expect(ABIHookChild().value() == 21)
        #expect(ABIHookParent().value() == 20 && ABIHookSibling().value() == 20)
        let parent = try unsafe runtime.hookMethod(on: ABIHookParent.self, selector: "value", as: (() -> Int).self,
            onFailure: { Issue.record($0) }) { call in try call.proceed() + 10 }
        defer { parent.invalidate() }
        #expect(ABIHookChild().value() == 31)
        child.invalidate()
        #expect(ABIHookChild().value() == 30)
        parent.invalidate()
        #expect(ABIHookChild().value() == 20)
        let classHook = try unsafe runtime.hookMethod(on: ABIHookChild.self, selector: "value", as: (() -> Int).self,
            classMethod: true, onFailure: { Issue.record($0) }) { call in
                #expect(try call.receiver === ABIHookChild.self)
                return try call.proceed() + 2
            }
        defer { classHook.invalidate() }
        #expect(ABIHookChild.value() == 42 && ABIHookParent.value() == 40)
    }

    @Test func accessorsAndNestedSelectorDispatch() throws {
        let setter = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "setNumber:",
            as: ((Int) -> Void).self, onFailure: { Issue.record($0) }) { call, value in try call.proceed(value + 1) }
        let getter = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "number",
            as: (() -> Int).self, onFailure: { Issue.record($0) }) { call in try call.proceed() * 2 }
        defer { setter.invalidate(); getter.invalidate() }
        let object = ABIManagedHookFixture()
        object.number = 20
        #expect(object.number == 42)
        let calls = HookBox(0)
        let recursive = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "sumThrough:",
            as: ((Int) -> Int).self, onFailure: { Issue.record($0) }) { call, value in
                calls.update { $0 += 1 }
                return try call.proceed(value)
            }
        defer { recursive.invalidate() }
        #expect(object.sumThrough(4) == 10 && calls.read() == 5)
    }

    @Test func weakIdentityScopeDoesNotRetainTheReceiver() throws {
        var object: ABIManagedHookFixture? = ABIManagedHookFixture()
        weak var observed = object
        let calls = HookBox(0)
        let originalClass = object_getClass(try #require(object))
        let hook = try unsafe runtime.object(try #require(object)).hookMethod(selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in
                calls.update { $0 += 1 }
                return try call.proceed(a, b) + 1
            }
        defer { hook.invalidate() }
        #expect(object?.add(20, to: 21) == 42)
        #expect(object_getClass(try #require(object)) === originalClass)
        #expect(ABIManagedHookFixture().add(20, to: 21) == 41 && calls.read() == 1)
        object = nil
        #expect(observed == nil)
        #expect(ABIManagedHookFixture().add(20, to: 21) == 41 && calls.read() == 1)
    }

    @Test func snapshotsSurviveInvalidationAndReleaseCapturesOutsideLocks() throws {
        let started = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let callbacks = HookBox(0)
        let deinitialized = HookBox(false)
        var capture: HookCapture? = HookCapture { deinitialized.update { $0 = true } }
        weak var observed = capture
        let inner = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { [capture] call, a, b in
                withExtendedLifetime(capture) { callbacks.update { $0 += 1 } }
                return try call.proceed(a, b) + 1
            }
        capture = nil
        let outer = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in
                started.signal(); resume.wait()
                return try call.proceed(a, b)
            }
        defer { inner.invalidate(); outer.invalidate() }
        finished.enter()
        let worker = Thread { defer { finished.leave() }; #expect(ABIManagedHookFixture().add(20, to: 21) == 42) }
        worker.qualityOfService = .userInitiated; worker.start()
        defer { resume.signal(); finished.wait() }
        started.wait()
        inner.invalidate(); outer.invalidate()
        #expect(observed != nil && !deinitialized.read())
        #expect(ABIManagedHookFixture().add(20, to: 21) == 41)
        resume.signal(); finished.wait()
        #expect(callbacks.read() == 1 && observed == nil && deinitialized.read())
    }

    @Test func invalidateAndRegisterFromInsideCallbacks() throws {
        let current = HookBox<NativeObjCMethodHook?>(nil)
        let added = HookBox<NativeObjCMethodHook?>(nil)
        let hook = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in
                current.read()?.invalidate()
                let next = try unsafe ABIRuntime.shared.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
                    as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) + 2 }
                added.update { $0 = next }
                return try call.proceed(a, b) + 1
            }
        current.update { $0 = hook }
        defer { hook.invalidate(); added.read()?.invalidate(); current.update { $0 = nil } }
        #expect(ABIManagedHookFixture().add(20, to: 21) == 42)
        #expect(ABIManagedHookFixture().add(20, to: 21) == 43)
    }

    @Test func externalReplacementKeepsSavedDispatcherAndIsNeverOverwritten() throws {
        let hook = try unsafe runtime.hookMethod(on: ABIHookExternalFixture.self, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) + 1 }
        let method = try #require(class_getInstanceMethod(ABIHookExternalFixture.self, NSSelectorFromString("add:to:")))
        let saved = method_getImplementation(method)
        let block: @convention(block) (ABIReplacementFixture, Int32, Int32) -> Int32 = { object, a, b in
            ABIReplacementCallAdd(saved, object, a, b) + 10
        }
        let external = imp_implementationWithBlock(block)
        method_setImplementation(method, external)
        defer { method_setImplementation(method, saved); imp_removeBlock(external); hook.invalidate() }
        #expect(hook.status == .displaced)
        #expect(ABIHookExternalFixture().add(20, to: 21) == 52)
        #expect(throws: NativeObjCMethodHookError.displaced) {
            try unsafe runtime.hookMethod(on: ABIHookExternalFixture.self, selector: "add:to:",
                as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) }
        }
        hook.invalidate()
        #expect(method_getImplementation(method) == external)
        #expect(ABIHookExternalFixture().add(20, to: 21) == 51)
        #expect(ABIReplacementCallAdd(saved, ABIHookExternalFixture(), 20, 22) == 42)
        method_setImplementation(method, ABIHookForwardingImplementation())
        #expect(throws: NativeObjCMethodHookError.displaced) {
            try unsafe runtime.hookMethod(on: ABIHookExternalFixture.self, selector: "add:to:",
                as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) }
        }
    }

    @Test func tokenDestructionAndReentrantCaptureDestruction() throws {
        let released = HookBox(false)
        var capture: HookCapture? = HookCapture {
            do {
                let hook = try unsafe ABIRuntime.shared.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
                    as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) }
                hook.invalidate()
                released.update { $0 = true }
            } catch { Issue.record(error) }
        }
        var token: NativeObjCMethodHook? = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { [capture] call, a, b in
                try withExtendedLifetime(capture) { try call.proceed(a, b) + 1 }
            }
        capture = nil
        #expect(token?.status == .active)
        token = nil
        #expect(released.read())
        #expect(ABIManagedHookFixture().add(20, to: 21) == 41)
    }

    @Test func errorsContinueTheSnapshotWithoutRepeatingNativeEffects() throws {
        for after in [false, true] {
            let errors = HookBox(0)
            let inner = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
                as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) + 1 }
            let outer = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
                as: ((Int32, Int32) -> Int32).self, onFailure: { _ in errors.update { $0 += 1 } }) { call, a, b in
                    if after { _ = try call.proceed(a + 1, b) }
                    throw HookFailure.deliberate
                }
            defer { inner.invalidate(); outer.invalidate() }
            let object = ABIManagedHookFixture()
            #expect(object.add(20, to: 21) == (after ? 43 : 42))
            #expect(object.calls == 1 && errors.read() == 1)
        }
    }

    @Test func concurrentCallsAndRegistrations() throws {
        let count = HookBox(0)
        let tokens = HookBox<[NativeObjCMethodHook]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let token = try unsafe ABIRuntime.shared.hookMethod(on: ABIManagedHookFixture.self, selector: "resize:",
                    as: ((CGSize) -> CGSize).self, onFailure: { Issue.record($0) }) { call, size in
                        count.update { $0 += 1 }
                        return try call.proceed(size)
                    }
                tokens.update { $0.append(token) }
            } catch { Issue.record(error) }
        }
        defer { for token in tokens.read() { token.invalidate() } }
        #expect(tokens.read().count == 8)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let size = CGSize(width: index, height: index)
            #expect(ABIManagedHookFixture().resize(size) == CGSize(width: index + 1, height: index + 2))
        }
        #expect(count.read() == 800)
    }

    @Test func concurrentFirstRegistrationsShareOneEntry() throws {
        for _ in 0..<16 {
            let name = "ABIConcurrentHook_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let type = try #require(objc_allocateClassPair(ABIManagedHookFixture.self, name, 0))
            objc_registerClassPair(type)
            // Published entries require their runtime class for process lifetime.
            let target = HookBox<AnyClass>(type)
            let tokens = HookBox<[NativeObjCMethodHook]>([])
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                do {
                    let token = try unsafe ABIRuntime.shared.hookMethod(on: target.read(), selector: "add:to:",
                        as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) + 1 }
                    tokens.update { $0.append(token) }
                } catch { Issue.record(error) }
            }
            defer { for token in tokens.read() { token.invalidate() } }
            #expect(tokens.read().count == 8)
            let fixture = try #require(type as? ABIManagedHookFixture.Type).init()
            #expect(fixture.add(20, to: 22) == 50)
            let method = try #require(class_getInstanceMethod(type, NSSelectorFromString("add:to:")))
            let implementation = method_getImplementation(method)
            for token in tokens.read() { token.invalidate() }
            #expect(fixture.add(20, to: 22) == 42)
            let again = try unsafe runtime.hookMethod(on: type, selector: "add:to:",
                as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) }
            again.invalidate()
            #expect(method_getImplementation(method) == implementation)
        }
    }

    @MainActor @Test func mainActorMethodAndWeakObjectRoute() throws {
        let object = ABIManagedHookFixture()
        let calls = HookBox(0), errors = HookBox(0)
        let hook = try unsafe runtime.object(object).hookMainActorMethod(selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, onFailure: { error in
                #expect(error as? NativeObjCMethodHookError == .wrongThread)
                errors.update { $0 += 1 }
            }) { call, a, b in MainActor.assertIsolated(); calls.update { $0 += 1 }; return try call.proceed(a, b) + 1 }
        defer { hook.invalidate() }
        #expect(object.add(20, to: 21) == 42)
        let classHook = try unsafe runtime.hookMainActorMethod(on: ABIManagedHookFixture.self, selector: "number",
            as: (() -> Int).self, onFailure: { _ in errors.update { $0 += 1 } }) { call in MainActor.assertIsolated(); return try call.proceed() + 1 }
        defer { classHook.invalidate() }
        let done = DispatchSemaphore(value: 0)
        let worker = Thread { defer { done.signal() }; #expect(ABIManagedHookFixture().number == 0) }
        worker.qualityOfService = .userInitiated; worker.start(); done.wait()
        #expect(calls.read() == 1 && errors.read() == 1)
    }

    @Test func retainedObjectResultsStayBalancedAcrossChains() throws {
        for (selector, options) in [("object", NativeMethodOptions()), ("copyObject", .init()),
                                    ("retainedObject", .init(returnsRetainedObject: true)),
                                    ("newBorrowedObject", .init(returnsRetainedObject: false))] {
            func install() throws -> NativeObjCMethodHook {
                try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: selector,
                    as: (() -> NSObject).self, options: options, onFailure: { Issue.record($0) }) { call in try call.proceed() }
            }
            let first = try install(), second = try install()
            defer { first.invalidate(); second.invalidate() }
            let object = ABIManagedHookFixture()
            weak var observed: NSObject?
            autoreleasepool {
                let value: NSObject
                switch selector {
                case "copyObject": value = object.copyObject()
                case "retainedObject": value = object.retainedObject()
                case "newBorrowedObject": value = object.newBorrowedObject()
                default: value = object.object()
                }
                observed = value
                #expect(object.liveResults == 1)
            }
            #expect(observed == nil && object.liveResults == 0)
        }
    }

    @Test func mixedArgumentsAndBlocksTraverseTheChain() throws {
        typealias Mixed = (Int8, UInt16, Float, Double, Int, UnsafeMutableRawPointer?, CGSize, CGRect, Bool, Int64, Float, Double) -> Double
        let selector = "mixed:b:c:d:e:f:g:h:i:j:k:l:"
        func install() throws -> NativeObjCMethodHook {
            try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: selector, as: Mixed.self,
                onFailure: { Issue.record($0) }) { call, a,b,c,d,e,f,g,h,i,j,k,l in try call.proceed(a,b,c,d,e,f,g,h,i,j,k,l) + 1 }
        }
        let first = try install(), second = try install()
        defer { first.invalidate(); second.invalidate() }
        let size = CGSize(width: 7, height: 8), rect = CGRect(x: 9, y: 10, width: 11, height: 12)
        let expected = ABIHookBenchmarkControl().mixed(1, b: 2, c: 3, d: 4, e: 5, f: nil, g: size, h: rect, i: true, j: 14, k: 15, l: 16)
        #expect(ABIManagedHookFixture().mixed(1, b: 2, c: 3, d: 4, e: 5, f: nil, g: size, h: rect, i: true, j: 14, k: 15, l: 16) == expected + 2)
        typealias Block = @convention(block) (Int32) -> Int32
        let blockHook = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "block",
            as: (() -> Block).self, onFailure: { Issue.record($0) }) { call in try call.proceed() }
        let argumentHook = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "apply:block:",
            as: ((Int32, Block?) -> Int32).self, onFailure: { Issue.record($0) }) { call, value, block in try call.proceed(value, block) }
        defer { blockHook.invalidate(); argumentHook.invalidate() }
        let object = ABIManagedHookFixture()
        #expect(object.apply(30, block: object.block()) == 40)
        #expect(object.storedBlock?(32) == 42)
    }

    @Test func managedEntryBenchmark() throws {
        let count = 10_000, object = ABIManagedHookFixture(), clock = ContinuousClock()
        func measure(_ name: String, _ body: () -> Void) {
            let start = clock.now
            autoreleasepool { for _ in 0..<count { body() } }
            print("Managed hook \(name), \(count) calls: \(start.duration(to: clock.now))")
        }
        // Prior tests may already have published inactive entries on this class.
        // A separate compiler-authored class remains a direct-call control.
        let direct = ABIHookBenchmarkControl()
        measure("scalar direct") { _ = direct.add(20, to: 22) }
        measure("CGSize direct") { _ = direct.resize(.zero) }
        measure("object direct") { _ = direct.object() }
        var tokens: [NativeObjCMethodHook] = []
        for level in 1...3 {
            tokens.append(try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
                as: ((Int32, Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a, b) })
            tokens.append(try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "resize:",
                as: ((CGSize) -> CGSize).self, onFailure: { Issue.record($0) }) { call, value in try call.proceed(value) })
            tokens.append(try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "object",
                as: (() -> NSObject).self, onFailure: { Issue.record($0) }) { call in try call.proceed() })
            measure("scalar \(level) hooks") { _ = object.add(20, to: 22) }
            measure("CGSize \(level) hooks") { _ = object.resize(.zero) }
            measure("object \(level) hooks") { _ = object.object() }
        }
        for token in tokens { token.invalidate() }
        measure("scalar inactive") { _ = object.add(20, to: 22) }
        measure("CGSize inactive") { _ = object.resize(.zero) }
        measure("object inactive") { _ = object.object() }
        #expect(object.liveResults == 0 && direct.liveResults == 0)
    }

    @Test func unsupportedContractsFailBeforeMutation() throws {
        let selector = NSSelectorFromString("add:to:")
        let method = try #require(class_getInstanceMethod(ABIManagedHookFixture.self, selector))
        let original = method_getImplementation(method)
        #expect(throws: (any Error).self) {
            try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "add:to:",
                as: ((String) -> Int).self, onFailure: { Issue.record($0) }) { _, _ in 0 }
        }
        #expect(method_getImplementation(method) == original)
        #expect(throws: NativeObjCMethodHookError.unsupportedMethod) {
            try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "init",
                as: (() -> AnyObject?).self, onFailure: { Issue.record($0) }) { call in try call.proceed() }
        }
        #expect(throws: NativeObjCMethodHookError.unsupportedMethod) {
            try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "dealloc",
                as: (() -> Void).self, onFailure: { Issue.record($0) }) { call in try call.proceed() }
        }
        let token = try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "object",
            as: (() -> NSObject).self, onFailure: { Issue.record($0) }) { call in try call.proceed() }
        defer { token.invalidate() }
        #expect(throws: NativeObjCMethodHookError.incompatibleContract) {
            try unsafe runtime.hookMethod(on: ABIManagedHookFixture.self, selector: "object",
                as: (() -> NSObject).self, options: .init(returnsRetainedObject: true),
                onFailure: { Issue.record($0) }) { call in try call.proceed() }
        }
    }
}
