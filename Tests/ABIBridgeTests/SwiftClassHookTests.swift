#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct SwiftClassHookTests {
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
}
#endif
