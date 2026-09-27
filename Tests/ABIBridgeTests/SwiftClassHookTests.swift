#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct SwiftClassHookTests {
    @Test func inheritedAndOverriddenMetadataKeepIndependentReceiverScopes() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false); defer { fixture.cleanup() }
        let baseName = fixture.module + ".ReplacementRenderer"
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classScalar(\(baseName), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        var objects: [AnyObject] = []
        for factory in ["makeRenderer", "makeInheritedRenderer", "makeOverridingRenderer"] {
            let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".\(factory)() -> " + baseName,
                as: (() -> AnyObject).self, in: fixture.providerScope)
            objects.append(try unsafe make.unsafeInvoke())
        }
        for (index, name) in ["ReplacementRenderer", "InheritedRenderer", "OverridingRenderer"].enumerated() {
            let type = try await fixture.runtime.swiftType(named: fixture.module + "." + name, in: fixture.providerScope)
            let method = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
            let identity = ObjectIdentifier(objects[index])
            let hook = try await unsafe method.hookVirtualCalls(onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
                #expect(ObjectIdentifier(try call.receiver(as: AnyObject.self)) == identity)
                return try call.proceed(value) + 100
            }
            for (other, object) in objects.enumerated() {
                #expect(try unsafe oracle.unsafeInvoke(object, 40) == (other == 2 ? 44 : 42) + (index == other ? 100 : 0))
            }
            hook.invalidate()
            #expect(try unsafe oracle.unsafeInvoke(objects[index], 40) == (index == 2 ? 44 : 42))
        }
    }

    @Test func virtualChainsPreserveTheSelectedClassAndReceiverIdentity() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false); defer { fixture.cleanup() }
        let name = fixture.module + ".ReplacementRenderer"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.providerScope)
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeRenderer() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let makeChild = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeInheritedRenderer() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let object = try unsafe make.unsafeInvoke(), child = try unsafe makeChild.unsafeInvoke()
        let identity = ObjectIdentifier(object)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classScalar(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let method = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
        let first = try await unsafe method.hookVirtualCalls(onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            let receiver = try call.receiver(as: AnyObject.self)
            #expect(ObjectIdentifier(receiver) == identity)
            return try call.proceed(value + 1) + 10
        }
        defer { first.invalidate() }
        #expect(first.status == .active)
        #expect(try unsafe oracle.unsafeInvoke(object, 40) == 53)
        #expect(try unsafe oracle.unsafeInvoke(child, 40) == 42)
        #expect(try unsafe method.unsafeInvoke(on: object, 40) == 42)
        let second = try await unsafe method.hookVirtualCalls(onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            try call.proceed(value * 2) + 100
        }
        defer { second.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(object, 40) == 193)
        first.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(object, 40) == 182)
        second.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(object, 40) == 42)
    }

    @Test func receiverAccessCanEditObjectPropertiesAroundImportedCalls() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        import Foundation
        public class Editable: NSObject {
            @objc public var count: Int64 = 0
            @inline(never) public final func adding(_ value: Int64) -> Int64 { count + value }
        }
        @inline(never) public func makeEditable() -> Editable { Editable() }
        """, callerExtra: """
        @inline(never) public func callEditable(_ object: Editable, _ value: Int64) -> Int64 { object.adding(value) }
        """); defer { fixture.cleanup() }
        let name = fixture.module + ".Editable"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.providerScope)
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeEditable() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let object = try #require(try unsafe make.unsafeInvoke() as? NSObject)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".callEditable(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let method = try await type.method(named: "adding(_:)", as: ((Int64) -> Int64).self)
        let hook = try await unsafe method.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
                let receiver = try call.receiver(as: NSObject.self)
                receiver.setValue(Int64(10), forKey: "count")
                let result = try call.proceed(value + 1)
                receiver.setValue(Int64(100), forKey: "count")
                return result + 1000
            }
        defer { hook.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(object, 2) == 1013)
        #expect(object.value(forKey: "count") as? Int64 == 100)
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(object, 2) == 102)
    }

    @Test func getterAndSetterHooksPreserveOwnedStringArgumentsAndResults() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        public class TextReceiver {
            public var text: String = "initial"
            public init() {}
        }
        @inline(never) public func makeTextReceiver() -> TextReceiver { TextReceiver() }
        """, callerExtra: """
        @inline(never) public func setAndRead(_ object: TextReceiver, _ value: String) -> String { object.text = value; return object.text }
        """); defer { fixture.cleanup() }
        let name = fixture.module + ".TextReceiver"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.providerScope)
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeTextReceiver() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let object = try unsafe make.unsafeInvoke()
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".setAndRead(\(name), Swift.String) -> Swift.String",
            as: ((AnyObject, String) -> String).self, in: fixture.callerScope)
        let getter = try await type.getter(named: "text", as: String.self)
        let setter = try await type.setter(named: "text", as: String.self)
        let setterHook = try await unsafe setter.hookVirtualCalls(onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            try call.proceed(value + " set")
            let receiver = try call.receiver(as: AnyObject.self)
            #expect(try unsafe getter.unsafeInvoke(on: receiver) == value + " set")
        }
        defer { setterHook.invalidate() }
        let getterHook = try await unsafe getter.hookVirtualCalls(onFailure: { Issue.record("Unexpected: \($0)") }) { call in
            try call.proceed() + " get"
        }
        defer { getterHook.invalidate() }
        let input = String(repeating: "heap-backed property", count: 100)
        for _ in 0..<20 { #expect(try unsafe oracle.unsafeInvoke(object, input) == input + " set get") }
        setterHook.invalidate(); getterHook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(object, input) == input)
    }

    @Test func consumingSelfSurvivesRepeatedProceedAndSkippingTheOriginal() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false); defer { fixture.cleanup() }
        let name = fixture.module + ".CallbackRenderer"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.providerScope)
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeCallbackRenderer(Swift.Int64) -> " + name,
            as: ((Int64) -> AnyObject).self, in: fixture.providerScope)
        var object: AnyObject? = try unsafe make.unsafeInvoke(10)
        weak var weakObject = object
        let identity = ObjectIdentifier(object!)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".callbackConsumeSelf(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let method = try await type.method(named: "consumeSelf(_:)", as: ((Int64) -> Int64).self, consuming: true)
        let hook = try await unsafe method.hookVirtualCalls(onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            #expect(ObjectIdentifier(try call.receiver(as: AnyObject.self)) == identity)
            if value == 0 { return 1000 }
            _ = try call.proceed(value + 1)
            let result = try call.proceed(value + 2)
            #expect(ObjectIdentifier(try call.receiver(as: AnyObject.self)) == identity)
            return result
        }
        defer { hook.invalidate() }
        for _ in 0..<20 {
            #expect(try unsafe oracle.unsafeInvoke(object!, 40) == 52)
            #expect(try unsafe oracle.unsafeInvoke(object!, 0) == 1000)
        }
        hook.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(object!, 40) == 50)
        object = nil
        #expect(weakObject == nil)
    }

    @Test @MainActor func mainActorMethodHooksBypassBackgroundEntry() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false); defer { fixture.cleanup() }
        let name = fixture.module + ".ReplacementRenderer"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.providerScope)
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeRenderer() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let object = SwiftClassObject(try unsafe make.unsafeInvoke())
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classScalar(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let method = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
        let failures = Mutex<[String]>([])
        let state = SwiftClassActorState()
        let hook = try await unsafe method.hookMainActorVirtualCalls(onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
            state.calls += 1
            #expect(ObjectIdentifier(try call.receiver(as: AnyObject.self)) == ObjectIdentifier(object.value))
            return try call.proceed(value + 1)
        }
        defer { hook.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(object.value, 40) == 43)
        #expect(try await Task.detached { try unsafe oracle.unsafeInvoke(object.value, 40) }.value == 42)
        #expect(state.calls == 1)
        #expect(failures.withLock { $0 } == ["wrongThread"])
    }

    @Test func escapedMethodNamesRemainDistinctFromLifecycleEntries() async throws {
        let fixture = try CompiledSwiftReplacementFixture(providerExtra: """
        public class Escaped {
            public init() {}
            @inline(never) public func `init`(_ value: Int64) -> Int64 { value + 1 }
            @inline(never) public final func `deinit`(_ value: Int64) -> Int64 { value + 2 }
        }
        @inline(never) public func makeEscaped() -> Escaped { Escaped() }
        """, callerExtra: """
        @inline(never) public func escapedInit(_ object: Escaped, _ value: Int64) -> Int64 { object.`init`(value) }
        @inline(never) public func escapedDeinit(_ object: Escaped, _ value: Int64) -> Int64 { object.`deinit`(value) }
        """); defer { fixture.cleanup() }
        let name = fixture.module + ".Escaped"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.providerScope)
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeEscaped() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let object = try unsafe make.unsafeInvoke()
        let first = try await type.method(named: "init(_:)", as: ((Int64) -> Int64).self)
        let second = try await type.method(named: "deinit(_:)", as: ((Int64) -> Int64).self)
        let firstCall = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".escapedInit(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let secondCall = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".escapedDeinit(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let virtual = try await unsafe first.hookVirtualCalls(onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in try call.proceed(value) + 10 }
        defer { virtual.invalidate() }
        let imported = try await unsafe second.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in try call.proceed(value) + 20 }
        defer { imported.invalidate() }
        #expect(try unsafe firstCall.unsafeInvoke(object, 40) == 51)
        #expect(try unsafe secondCall.unsafeInvoke(object, 40) == 62)
    }

    @Test func importedAndVirtualSelectionsShareTheSameInheritedEntry() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let name = fixture.callerModule + ".CallerOverridingRenderer"
        let baseName = fixture.module + ".ReplacementRenderer"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.callerScope)
        let make = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".makeCallerRenderer() -> " + name,
            as: (() -> AnyObject).self, in: fixture.callerScope)
        let object = try unsafe make.unsafeInvoke()
        let method = try await type.method(named: "text(_:)", as: ((String) -> String).self)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classText(\(baseName), Swift.String) -> Swift.String",
            as: ((AnyObject, String) -> String).self, in: fixture.callerScope)
        let virtual = try await unsafe method.hookVirtualCalls(onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in
            try call.proceed(value + "V") + "v"
        }
        defer { virtual.invalidate() }
        let imported = try await unsafe method.hookImportedCalls(in: fixture.callerScope, using: fixture.runtime,
            onFailure: { Issue.record("Unexpected: \($0)") }) { call, value in try call.proceed(value + "I") + "i" }
        defer { imported.invalidate() }
        let shared = try #require(imported.slots.first(where: { $0.address == virtual.address }))
        #expect(shared.mutation == nil)
        #expect(try unsafe oracle.unsafeInvoke(object, "x") == "method:xIVvi")
        virtual.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(object, "x") == "method:xIi")
        imported.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(object, "x") == "method:x")

        let base = try await fixture.runtime.swiftType(named: baseName, in: fixture.providerScope)
        let destroy = try await base.method(named: "deinit", as: (() -> UnsafeRawPointer?).self)
        do {
            _ = try await unsafe destroy.hookImportedCalls(in: fixture.callerScope, onFailure: { Issue.record("Unexpected: \($0)") }) { _ in nil }
            Issue.record("An initializing/deinitializing receiver cannot use an ordinary method hook")
        } catch ABIResolutionError.unsupportedDeclaration { }
    }

    @Test func failurePreservesTheCompletedResultAndExpiredReceiverViewsReleaseObjects() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false); defer { fixture.cleanup() }
        let name = fixture.module + ".ReplacementRenderer"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.providerScope)
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeRenderer() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        var object: AnyObject? = try unsafe make.unsafeInvoke()
        weak var observed = object
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classScalar(\(name), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        let method = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
        let saved = SavedSwiftClassInvocation(), failures = Mutex<[String]>([]), proceeded = Mutex(0)
        let first = try await unsafe method.hookVirtualCalls(onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
            proceeded.withLock { $0 += 1 }
            return try call.proceed(value)
        }
        defer { first.invalidate() }
        let second = try await unsafe method.hookVirtualCalls(onFailure: { error in failures.withLock { $0.append(String(describing: error)) } }) { call, value in
            saved.value = call
            _ = try call.receiver(as: AnyObject.self)
            _ = try call.proceed(value + 1)
            throw SwiftClassHookFailure.afterProceed
        }
        defer { second.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(object!, 40) == 43)
        #expect(proceeded.withLock { $0 } == 1 && failures.withLock { $0 } == ["afterProceed"])
        let escaped = try #require(saved.value)
        #expect(throws: NativeSwiftHookInvocationError.expiredInvocation) { try escaped.receiver(as: AnyObject.self) }
        #expect(throws: NativeSwiftHookInvocationError.expiredInvocation) { try escaped.proceed(1) }
        object = nil
        #expect(observed == nil)
        #expect(escaped.description.contains("scalar"))
    }
}

// This fixture contains no mutable fields and is used sequentially across the
// two execution contexts to verify the incoming-thread policy.
private final class SwiftClassObject: @unchecked Sendable {
    let value: AnyObject
    init(_ value: AnyObject) { self.value = value }
}
@MainActor private final class SwiftClassActorState { var calls = 0 }
private enum SwiftClassHookFailure: Error { case afterProceed }
private final class SavedSwiftClassInvocation: @unchecked Sendable {
    var value: NativeSwiftMethodInvocation<Int64, Int64>?
}
#endif
