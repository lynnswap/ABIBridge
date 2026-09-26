import ABIBridge
import Foundation
import ObjectiveC
import ObjectiveCFixtures
import Testing

private final class InitBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
}
private enum InitFailure: Error { case deliberate }
private final class InitCapture: @unchecked Sendable {}

@Suite(.serialized)
struct ObjectiveCInitializerHookTests {
    let runtime = ABIRuntime()
    let selector = "initWithMode:value:object:"
    typealias Signature = (Int, Int, NSObject?) -> ABIManagedInitializerFixture?

    @Test func sameNilAndReplacementResultsBalanceIncomingOwnership() throws {
        let observedValues = InitBox<[Int?]>([])
        let hook = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
            as: Signature.self, onFailure: { Issue.record($0) }, after: { result in
                observedValues.update { $0.append(result?.value) }
            })
        defer { hook.invalidate() }
        for mode in 0...2 {
            let start = ABIManagedInitializerFixture.initializations
            weak var observed: ABIManagedInitializerFixture?
            autoreleasepool {
                let object = ABIManagedInitializerFixture(mode: mode, value: 20, object: nil)
                observed = object
                #expect((object == nil) == (mode == 1))
                #expect(ABIManagedInitializerFixture.liveObjects == (mode == 1 ? 0 : 1))
                if mode == 2, let object { #expect(type(of: object) != ABIManagedInitializerFixture.self) }
            }
            #expect(observed == nil && ABIManagedInitializerFixture.liveObjects == 0)
            #expect(ABIManagedInitializerFixture.initializations - start == (mode == 2 ? 2 : 1))
        }
        #expect(observedValues.read() == [20, nil, 30, 30])
    }

    @Test func preparesReferenceArgumentsAndTransformsValueTuples() throws {
        let hook = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
            as: ((Int, Int, NSMutableDictionary?) -> ABIManagedInitializerFixture?).self,
            onFailure: { Issue.record($0) }, transformingArguments: { mode, value, object in
                (mode, value * 2, object)
            }, before: { _, _, object in object?["prepared"] = true }, after: { result in result?.value += 2 })
        defer { hook.invalidate() }
        autoreleasepool {
            let configuration = NSMutableDictionary()
            let object = ABIManagedInitializerFixture(mode: 0, value: 20, object: configuration)
            #expect(object?.value == 42)
            #expect(configuration["prepared"] as? Bool == true)
            #expect(object?.object as? NSMutableDictionary === configuration)
        }
        #expect(ABIManagedInitializerFixture.liveObjects == 0)
    }

    @Test func zeroAndSingleArgumentTransformationsCompileAndExecute() throws {
        let zeroCount = InitBox(0)
        let zero = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: "init",
            as: (() -> ABIManagedInitializerFixture).self, onFailure: { Issue.record($0) },
            transformingArguments: { () }, before: { zeroCount.update { $0 += 1 } }, after: { $0.value += 1 })
        let single = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: "initWithValue:",
            as: ((Int) -> ABIManagedInitializerFixture).self, onFailure: { Issue.record($0) },
            transformingArguments: { $0 * 2 }, after: { $0.value += 2 })
        defer { zero.invalidate(); single.invalidate() }
        autoreleasepool {
            #expect(ABIManagedInitializerFixture().value == 8)
            #expect(ABIManagedInitializerFixture(value: 20).value == 42)
        }
        #expect(zeroCount.read() == 1 && ABIManagedInitializerFixture.liveObjects == 0)
    }

    @MainActor @Test func observationPreservesOriginalBridgedArguments() throws {
        typealias Bridged = (Int, Int, String?) -> ABIManagedInitializerFixture?
        for mainActor in [false, true] {
            let hook: NativeObjCMethodHook
            if mainActor {
                hook = try unsafe runtime.hookMainActorInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
                    as: Bridged.self, onFailure: { Issue.record($0) }, before: { _, _, text in #expect(text == "original") })
            } else {
                hook = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
                    as: Bridged.self, onFailure: { Issue.record($0) }, before: { _, _, text in #expect(text == "original") })
            }
            defer { hook.invalidate() }
            autoreleasepool {
                let text = NSMutableString(string: "original")
                let result = ABIManagedInitializerFixture(mode: 0, value: 0, object: text)
                #expect(result?.containsIdenticalObject(text) == true)
            }
            #expect(ABIManagedInitializerFixture.liveObjects == 0)
        }
        let zero = try unsafe runtime.hookMainActorInitializer(on: ABIManagedInitializerFixture.self, selector: "init",
            as: (() -> ABIManagedInitializerFixture).self, onFailure: { Issue.record($0) })
        defer { zero.invalidate() }
        autoreleasepool { #expect(ABIManagedInitializerFixture().value == 7) }
    }

    @Test func observersWrapOneInitializationAndCanBeRemovedIndependently() throws {
        let trace = InitBox<[Int]>([])
        func install(_ number: Int) throws -> NativeObjCMethodHook {
            try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
                as: Signature.self, onFailure: { Issue.record($0) },
                before: { _, _, _ in trace.update { $0.append(number) } },
                after: { result in trace.update { $0.append(-number) }; result?.value += number })
        }
        let first = try install(1), middle = try install(2), outer = try install(3)
        defer { first.invalidate(); middle.invalidate(); outer.invalidate() }
        let start = ABIManagedInitializerFixture.initializations
        autoreleasepool { #expect(ABIManagedInitializerFixture(mode: 0, value: 36, object: nil)?.value == 42) }
        #expect(trace.read() == [3, 2, 1, -1, -2, -3])
        #expect(ABIManagedInitializerFixture.initializations - start == 1)
        middle.invalidate(); trace.update { $0 = [] }
        autoreleasepool { #expect(ABIManagedInitializerFixture(mode: 0, value: 38, object: nil)?.value == 42) }
        #expect(trace.read() == [3, 1, -1, -3])
        #expect(ABIManagedInitializerFixture.liveObjects == 0)
    }

    @Test func failuresBeforeAndAfterInitializationNeverReplayIt() throws {
        for stage in 0...2 {
            let errors = InitBox(0), afters = InitBox(0)
            let hook = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
                as: Signature.self, onFailure: { _ in errors.update { $0 += 1 } },
                transformingArguments: { mode, value, object in
                    if stage == 1 { throw InitFailure.deliberate }
                    return (mode, value + 2, object)
                }, before: { _, _, _ in if stage == 0 { throw InitFailure.deliberate } },
                after: { _ in afters.update { $0 += 1 }; throw InitFailure.deliberate })
            defer { hook.invalidate() }
            let start = ABIManagedInitializerFixture.initializations
            autoreleasepool { #expect(ABIManagedInitializerFixture(mode: 0, value: 40, object: nil)?.value == (stage == 2 ? 42 : 40)) }
            #expect(errors.read() == 1 && afters.read() == (stage == 2 ? 1 : 0))
            #expect(ABIManagedInitializerFixture.initializations - start == 1 && ABIManagedInitializerFixture.liveObjects == 0)
        }
    }

    @Test func conversionFailuresPreserveActualNativeArgumentsAndResult() throws {
        let errors = InitBox(0), afters = InitBox(0)
        let hook = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
            as: ((Int, Int, NSString?) -> NSString).self, onFailure: { _ in errors.update { $0 += 1 } },
            before: { _, _, _ in }, after: { _ in afters.update { $0 += 1 } })
        defer { hook.invalidate() }
        for object: NSObject? in [NSNumber(value: 2), nil] {
            let start = ABIManagedInitializerFixture.initializations
            autoreleasepool {
                let result = ABIManagedInitializerFixture(mode: 0, value: 42, object: object)
                #expect(result?.value == 42 && result?.object as? NSObject === object)
            }
            #expect(ABIManagedInitializerFixture.initializations - start == 1)
        }
        let start = ABIManagedInitializerFixture.initializations
        autoreleasepool { #expect(ABIManagedInitializerFixture(mode: 1, value: 42, object: nil) == nil) }
        #expect(errors.read() == 3 && afters.read() == 0)
        #expect(ABIManagedInitializerFixture.initializations - start == 1 && ABIManagedInitializerFixture.liveObjects == 0)
    }

    @Test func superclassDelegationAndInheritedPassThroughRemainDistinctEntries() throws {
        let trace = InitBox<[String]>([])
        let child = try unsafe runtime.hookInitializer(on: ABIManagedInitializerChild.self, selector: selector,
            as: Signature.self, onFailure: { Issue.record($0) }, before: { _, _, _ in trace.update { $0.append("child before") } },
            after: { _ in trace.update { $0.append("child after") } })
        let inherited = try unsafe runtime.hookInitializer(on: ABIManagedInitializerInherited.self, selector: selector,
            as: Signature.self, onFailure: { Issue.record($0) })
        inherited.invalidate()
        let parent = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
            as: Signature.self, onFailure: { Issue.record($0) }, before: { _, _, _ in trace.update { $0.append("parent before") } },
            after: { result in trace.update { $0.append("parent after") }; result?.value += 1 })
        defer { child.invalidate(); parent.invalidate() }
        let start = ABIManagedInitializerFixture.initializations
        autoreleasepool { #expect(ABIManagedInitializerChild(mode: 0, value: 41, object: nil)?.value == 42) }
        #expect(trace.read() == ["child before", "parent before", "parent after", "child after"])
        #expect(ABIManagedInitializerFixture.initializations - start == 1)
        autoreleasepool { #expect(ABIManagedInitializerInherited(mode: 0, value: 41, object: nil)?.value == 42) }
        #expect(ABIManagedInitializerFixture.liveObjects == 0)
    }

    @Test func invalidationKeepsTheCurrentInitializerSnapshotAndCaptures() throws {
        let started = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let finished = DispatchGroup(), observedAfter = InitBox(0)
        var capture: InitCapture? = InitCapture()
        weak var observed = capture
        let inner = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
            as: Signature.self, onFailure: { Issue.record($0) }, after: { [capture] result in
                withExtendedLifetime(capture) { observedAfter.update { $0 += 1 }; result?.value += 1 }
            })
        let outer = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
            as: Signature.self, onFailure: { Issue.record($0) }, before: { _, _, _ in started.signal(); resume.wait() })
        capture = nil
        defer { inner.invalidate(); outer.invalidate() }
        finished.enter()
        let worker = Thread {
            defer { finished.leave() }
            autoreleasepool { #expect(ABIManagedInitializerFixture(mode: 0, value: 41, object: nil)?.value == 42) }
        }
        worker.qualityOfService = .userInitiated; worker.start()
        defer { resume.signal(); finished.wait() }
        started.wait()
        inner.invalidate(); outer.invalidate()
        #expect(observed != nil)
        autoreleasepool { #expect(ABIManagedInitializerFixture(mode: 0, value: 41, object: nil)?.value == 41) }
        resume.signal(); finished.wait()
        #expect(observed == nil && observedAfter.read() == 1 && ABIManagedInitializerFixture.liveObjects == 0)
    }

    @MainActor @Test func mainActorInitializerAndBackgroundBypass() throws {
        let errors = InitBox(0), before = InitBox(0), after = InitBox(0)
        let hook = try unsafe runtime.hookMainActorInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
            as: Signature.self, onFailure: { error in
                #expect(error as? NativeObjCMethodHookError == .wrongThread); errors.update { $0 += 1 }
            }, transformingArguments: { mode, value, object in MainActor.assertIsolated(); return (mode, value + 1, object) },
            before: { _, _, _ in MainActor.assertIsolated(); before.update { $0 += 1 } },
            after: { _ in MainActor.assertIsolated(); after.update { $0 += 1 } })
        defer { hook.invalidate() }
        autoreleasepool { #expect(ABIManagedInitializerFixture(mode: 0, value: 41, object: nil)?.value == 42) }
        let done = DispatchSemaphore(value: 0)
        let worker = Thread { defer { done.signal() }; autoreleasepool { #expect(ABIManagedInitializerFixture(mode: 0, value: 41, object: nil)?.value == 41) } }
        worker.qualityOfService = .userInitiated; worker.start(); done.wait()
        #expect(errors.read() == 1 && before.read() == 1 && after.read() == 1)
        #expect(ABIManagedInitializerFixture.liveObjects == 0)
    }

    @Test func nonstandardInitializerOwnershipCannotMixWithOrdinaryHooks() throws {
        let options = NativeMethodOptions(returnsRetainedObject: true, consumesReceiver: true)
        let hook = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: "constructValue:",
            as: ((Int) -> ABIManagedInitializerFixture).self, options: options, onFailure: { Issue.record($0) },
            transformingArguments: { $0 + 1 })
        defer { hook.invalidate() }
        autoreleasepool { #expect(ABIManagedConstruct(41).value == 42) }
        #expect(throws: NativeObjCMethodHookError.incompatibleContract) {
            try unsafe runtime.hookMethod(on: ABIManagedInitializerFixture.self, selector: "constructValue:",
                as: ((Int) -> ABIManagedInitializerFixture).self, options: .init(returnsRetainedObject: true, consumesReceiver: false),
                onFailure: { Issue.record($0) }) { call, value in try call.proceed(value) }
        }
        #expect(ABIManagedInitializerFixture.liveObjects == 0)
    }

    @Test func postprocessingCanRetainOnlyTheInitializedResult() throws {
        let result = InitBox<ABIManagedInitializerFixture?>(nil)
        var hook: NativeObjCMethodHook? = try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
            as: Signature.self, onFailure: { Issue.record($0) }, after: { value in result.update { $0 = value } })
        weak var observed: ABIManagedInitializerFixture?
        autoreleasepool { let value = ABIManagedInitializerFixture(mode: 2, value: 32, object: nil); observed = value }
        #expect(observed?.value == 42 && ABIManagedInitializerFixture.liveObjects == 1)
        #expect(hook?.status == .active)
        hook = nil
        result.update { $0 = nil }
        #expect(observed == nil && ABIManagedInitializerFixture.liveObjects == 0)
    }

    @Test func invalidContractsDoNotReplaceMethods() throws {
        let method = try #require(class_getInstanceMethod(ABIManagedInitializerFixture.self, NSSelectorFromString(selector)))
        let original = method_getImplementation(method)
        for options in [NativeMethodOptions(returnsRetainedObject: false), .init(consumesReceiver: false)] {
            #expect(throws: NativeObjCMethodHookError.unsupportedMethod) {
                try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: selector,
                    as: Signature.self, options: options, onFailure: { Issue.record($0) })
            }
        }
        #expect(method_getImplementation(method) == original)
        #expect(throws: NativeObjCMethodHookError.unsupportedMethod) {
            try unsafe runtime.hookInitializer(on: ABIManagedInitializerFixture.self, selector: "value",
                as: (() -> Int).self, onFailure: { Issue.record($0) })
        }
    }
}
