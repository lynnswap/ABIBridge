import ABIBridge
import Foundation
import HookCoordinationFixtures
import ObjectiveC
import ObjectiveCFixtures
import Testing

private class CoordinatedFixture: NSObject {
    required override init() { super.init() }
    @objc dynamic func add(_ a: Int32, to b: Int32) -> Int32 { a + b }
    @objc dynamic func number() -> Int32 { 20 }
    @objc dynamic func object() -> NSObject { NSObject() }
    @objc dynamic class func answer() -> Int32 { 42 }
}
private class CoordinatedParent: NSObject { @objc dynamic func value() -> Int32 { 20 } }
private class CoordinatedChild: CoordinatedParent {}
private final class BatchBox<V>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: V
    init(_ value: V) { self.value = value }
    func read() -> V { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ body: (inout V) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
}
private final class BatchCapture: @unchecked Sendable {}

@Suite(.serialized)
struct CoordinatedObjectiveCHookTests {
    let runtime = ABIRuntime()
    private func adding(_ amount: Int32, on type: AnyClass = CoordinatedFixture.self) -> NativeObjCHookRequest {
        unsafe .method(on: type, selector: "add:to:", as: ((Int32, Int32) -> Int32).self,
            onFailure: { Issue.record($0) }) { call, a, b in try call.proceed(a,b) + amount }
    }

    @Test func preparationFailurePublishesNothing() throws {
        let method = try #require(class_getInstanceMethod(CoordinatedFixture.self, NSSelectorFromString("add:to:")))
        let original = method_getImplementation(method)
        let requests = [adding(1), unsafe NativeObjCHookRequest.method(on: CoordinatedFixture.self, selector: "number",
            as: ((Int32) -> Int32).self, onFailure: { Issue.record($0) }) { call, x in try call.proceed(x) }]
        do { _ = try unsafe runtime.installHooks(requests); Issue.record("Expected signature failure") }
        catch let error as NativeObjCHookInstallationError {
            #expect(error.failedIndex == 1 && error.phase == .preparation)
            #expect(error.invalidatedHooks.isEmpty)
            #expect(error.underlyingError is ABIResolutionError)
        }
        #expect(method_getImplementation(method) == original)
        #expect(CoordinatedFixture().add(20, to: 22) == 42)
        #expect(try unsafe runtime.installHooks([]).isEmpty)
    }

    @Test func overlappingRequestsKeepIndependentHandlesAndOrdering() throws {
        let first = try unsafe runtime.installHooks([adding(1), adding(2)])
        defer { first.forEach { $0.invalidate() } }
        let second = try unsafe runtime.installHooks([adding(3)])
        defer { second.forEach { $0.invalidate() } }
        #expect(CoordinatedFixture().add(20, to: 16) == 42)
        first.forEach { $0.invalidate() }
        #expect(CoordinatedFixture().add(20, to: 19) == 42)
        #expect(first.allSatisfy { $0.status == .invalidated } && second[0].status == .active)
        let method = try #require(class_getInstanceMethod(CoordinatedFixture.self, NSSelectorFromString("add:to:")))
        let saved = method_getImplementation(method)
        second.forEach { $0.invalidate() }
        for _ in 0..<4 {
            let hooks = try unsafe runtime.installHooks([adding(1)])
            #expect(method_getImplementation(method) == saved)
            hooks.forEach { $0.invalidate() }
        }
    }

    @Test func inheritedRequestsWorkInEitherOrder() throws {
        let parent = unsafe NativeObjCHookRequest.method(on: CoordinatedParent.self, selector: "value",
            as: (() -> Int32).self, onFailure: { Issue.record($0) }) { call in try call.proceed() + 10 }
        let child = unsafe NativeObjCHookRequest.method(on: CoordinatedChild.self, selector: "value",
            as: (() -> Int32).self, onFailure: { Issue.record($0) }) { call in try call.proceed() + 12 }
        for requests in [[parent,child],[child,parent]] {
            let hooks = try unsafe runtime.installHooks(requests)
            #expect(CoordinatedParent().value() == 30 && CoordinatedChild().value() == 42)
            hooks.forEach { $0.invalidate() }
            #expect(CoordinatedChild().value() == 20)
        }
    }

    @Test func ownershipMismatchWithinBatchFailsBeforePublication() throws {
        let method = try #require(class_getInstanceMethod(CoordinatedFixture.self, NSSelectorFromString("object")))
        let original = method_getImplementation(method)
        func request(_ retained: Bool) -> NativeObjCHookRequest {
            unsafe .method(on: CoordinatedFixture.self, selector: "object", as: (() -> NSObject).self,
                options: .init(returnsRetainedObject: retained), onFailure: { Issue.record($0) }) { call in try call.proceed() }
        }
        do { _ = try unsafe runtime.installHooks([request(false),request(true)]); Issue.record("Expected contract failure") }
        catch let error as NativeObjCHookInstallationError {
            #expect(error.failedIndex == 1 && error.phase == .preparation && error.invalidatedHooks.isEmpty)
            #expect(error.underlyingError as? NativeObjCMethodHookError == .incompatibleContract)
        }
        #expect(method_getImplementation(method) == original)
    }

    @Test func activationFailureInvalidatesOnlyItsOwnRegistration() throws {
        // A fresh subclass needs a new dispatcher, whose fallback-owner retain
        // runs an external writer after validation and before later activation.
        let name = "ABIBatch_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let type = try #require(objc_allocateClassPair(CoordinatedFixture.self, name, 0))
        objc_registerClassPair(type)
        let existing = try unsafe runtime.hookMethod(on: type, selector: "number", as: (() -> Int32).self,
            onFailure: { Issue.record($0) }) { call in try call.proceed() + 1 }
        defer { existing.invalidate() }
        let number = try #require(class_getInstanceMethod(type, NSSelectorFromString("number")))
        let original = method_getImplementation(number)
        let replacement: @convention(block) (AnyObject) -> Int32 = { _ in 99 }
        let external = imp_implementationWithBlock(replacement)
        defer { method_setImplementation(number, original); imp_removeBlock(external) }
        let owner = ABICoordinationOwner()
        let first = unsafe NativeObjCHookRequest.method(on: type, selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self, retaining: owner, onFailure: { Issue.record($0) }) { call,a,b in try call.proceed(a,b) + 1 }
        let second = unsafe NativeObjCHookRequest.method(on: type, selector: "number", as: (() -> Int32).self,
            onFailure: { Issue.record($0) }) { call in try call.proceed() + 2 }
        owner.onRetain = { method_setImplementation(number, external) }
        do { _ = try unsafe runtime.installHooks([first,second]); Issue.record("Expected activation displacement") }
        catch let error as NativeObjCHookInstallationError {
            #expect(error.failedIndex == 1 && error.phase == .activation)
            #expect(error.invalidatedHooks.count == 1 && error.invalidatedHooks[0].status == .invalidated)
            #expect(error.underlyingError as? NativeObjCMethodHookError == .displaced)
        }
        #expect(existing.status == .displaced && method_getImplementation(number) == external)
        method_setImplementation(number, original)
        #expect(existing.status == .active)
        let instance = try #require(type as? CoordinatedFixture.Type).init()
        #expect(instance.add(20, to: 22) == 42 && instance.number() == 21)
    }

    @Test func requestsAndInFlightSnapshotsHaveSeparateCaptureLifetimes() throws {
        var capture: BatchCapture? = BatchCapture()
        weak var observed = capture
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchGroup()
        var requests: [NativeObjCHookRequest] = [unsafe .method(on: CoordinatedFixture.self, selector: "add:to:",
            as: ((Int32,Int32) -> Int32).self, onFailure: { Issue.record($0) }) { [capture] call,a,b in
                entered.signal(); resume.wait()
                return try withExtendedLifetime(capture) { try call.proceed(a,b) + 1 }
            }]
        capture = nil
        var hooks = try unsafe runtime.installHooks(requests)
        requests.removeAll()
        done.enter()
        let worker = Thread { defer { done.leave() }; #expect(CoordinatedFixture().add(20,to:21) == 42) }
        worker.qualityOfService = .userInitiated; worker.start()
        defer { resume.signal(); done.wait() }
        entered.wait()
        hooks.forEach { $0.invalidate() }; hooks.removeAll()
        #expect(observed != nil)
        #expect(CoordinatedFixture().add(20,to:22) == 42)
        resume.signal(); done.wait()
        #expect(observed == nil)
    }

    @MainActor @Test func mainActorAndObjectRequestsKeepTheirScope() throws {
        let object = CoordinatedFixture()
        let hooks = try unsafe runtime.installHooks([
            unsafe .mainActorMethod(on: CoordinatedFixture.self, selector: "number", as: (() -> Int32).self,
                onFailure: { Issue.record($0) }) { call in MainActor.assertIsolated(); return try call.proceed() + 1 },
            unsafe .objectMethod(on: object, selector: "add:to:", as: ((Int32,Int32) -> Int32).self,
                onFailure: { Issue.record($0) }) { call,a,b in try call.proceed(a,b) + 1 },
            unsafe .method(on: CoordinatedFixture.self, selector: "answer", as: (() -> Int32).self, classMethod: true,
                onFailure: { Issue.record($0) }) { call in try call.proceed() + 1 }
        ])
        defer { hooks.forEach { $0.invalidate() } }
        #expect(object.number() == 21 && object.add(20,to:21) == 42)
        #expect(CoordinatedFixture().add(20,to:21) == 41 && CoordinatedFixture.answer() == 43)
    }

    @MainActor @Test func mixedOrdinaryAndMainActorInitializerRequests() throws {
        let first = unsafe NativeObjCHookRequest.initializer(on: ABIBatchInitializerFixture.self,
            selector: "initWithBatchValue:", as: ((Int) -> ABIBatchInitializerFixture).self,
            onFailure: { Issue.record($0) }, transformingArguments: { $0 + 1 })
        let second = unsafe NativeObjCHookRequest.mainActorInitializer(on: ABIBatchInitializerFixture.self,
            selector: "initWithBatchValue:", as: ((Int) -> ABIBatchInitializerFixture).self,
            onFailure: { Issue.record($0) }, after: { value in MainActor.assertIsolated(); value.value += 1 })
        let hooks = try unsafe runtime.installHooks([first,second])
        defer { hooks.forEach { $0.invalidate() } }
        #expect(ABIBatchInitializerFixture(batchValue: 40).value == 42)
        hooks[0].invalidate()
        #expect(ABIBatchInitializerFixture(batchValue: 41).value == 42)
    }

    @Test func releasedArrayRemovesRegistrationAndCaptures() throws {
        var capture: BatchCapture? = BatchCapture()
        weak var observed = capture
        var hooks: [NativeObjCMethodHook]? = try unsafe runtime.installHooks([
            unsafe .method(on: CoordinatedFixture.self, selector: "number", as: (() -> Int32).self,
                onFailure: { Issue.record($0) }) { [capture] call in try withExtendedLifetime(capture) { try call.proceed() + 1 } }
        ])
        capture = nil
        #expect(hooks?.count == 1 && observed != nil)
        hooks = nil
        #expect(observed == nil && CoordinatedFixture().number() == 20)
    }
}
