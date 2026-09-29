import ABIBridge
import Foundation
import Testing

private final class SelectorReceiver: NSObject {
    @objc var numberValue: Int
    @objc init(value: Int) { self.numberValue = value; super.init() }
    @objc dynamic func increment(_ number: Int) -> Int { number + 1 }
    @objc class func classValue() -> Int { 42 }
}

@Suite(.serialized)
struct ObjectiveCSelectorTests {
    @MainActor @Test func lookupAcceptsCompilerCheckedSelectors() throws {
        let runtime = ABIRuntime()
        let append = try runtime.objcMethod(on: NSMutableString.self,
            selector: #selector(NSMutableString.append(_:)), as: ((String) -> Void).self)
        let text = NSMutableString(string: "a")
        try unsafe append.unsafeInvoke(on: text, "b")
        #expect(text as String == "ab")
        let receiver = SelectorReceiver(value: 7)
        let selector = #selector(SelectorReceiver.increment(_:))
        let bound = try runtime.object(receiver).method(selector: selector, as: ((Int) -> Int).self)
        let message = try runtime.objcMethod(on: SelectorReceiver.self, selector: selector, as: ((Int) -> Int).self)
        let captured = try runtime.objcImplementation(on: SelectorReceiver.self, selector: selector, as: ((Int) -> Int).self)
        #expect(try unsafe bound.unsafeInvoke(41) == 42)
        #expect(try unsafe message.unsafeInvoke(on: receiver, 41) == 42)
        #expect(try unsafe captured.unsafeInvoke(on: receiver, 41) == 42)
        let getter = try runtime.object(receiver).method(selector: #selector(getter: SelectorReceiver.numberValue), as: (() -> Int).self)
        #expect(try unsafe getter.unsafeInvoke() == 7)
        let classMethod = try runtime.objcMethod(on: SelectorReceiver.self,
            selector: #selector(SelectorReceiver.classValue), as: (() -> Int).self, classMethod: true)
        #expect(try unsafe classMethod.unsafeInvoke(on: SelectorReceiver.self as AnyObject) == 42)
    }

    @MainActor @Test(arguments: 0..<7)
    func selectorMethodHooksShareDispatch(_ path: Int) throws {
        let runtime = ABIRuntime()
        let receiver = SelectorReceiver(value: 0)
        let selector = #selector(SelectorReceiver.increment(_:))
        let body: @Sendable (NativeObjCMethodInvocation<Int, Int>, Int) throws -> Int = {
            try $0.proceed($1) + 10
        }
        let actorBody: @MainActor @Sendable (NativeObjCMethodInvocation<Int, Int>, Int) throws -> Int = {
            MainActor.preconditionIsolated()
            return try $0.proceed($1) + 10
        }
        let token: NativeObjCMethodHook
        switch path {
        case 0:
            token = try unsafe runtime.hookMethod(on: SelectorReceiver.self, selector: selector,
                as: ((Int) -> Int).self, onFailure: { Issue.record($0) }, body: body)
        case 1:
            token = try unsafe runtime.hookMainActorMethod(on: SelectorReceiver.self, selector: selector,
                as: ((Int) -> Int).self, onFailure: { Issue.record($0) }, body: actorBody)
        case 2:
            token = try unsafe runtime.object(receiver).hookMethod(selector: selector,
                as: ((Int) -> Int).self, onFailure: { Issue.record($0) }, body: body)
        case 3:
            token = try unsafe runtime.object(receiver).hookMainActorMethod(selector: selector,
                as: ((Int) -> Int).self, onFailure: { Issue.record($0) }, body: actorBody)
        default:
            let request: NativeObjCHookRequest
            if path == 4 {
                request = unsafe .method(on: SelectorReceiver.self, selector: selector,
                    as: ((Int) -> Int).self, onFailure: { Issue.record($0) }, body: body)
            } else if path == 5 {
                request = unsafe .mainActorMethod(on: SelectorReceiver.self, selector: selector,
                    as: ((Int) -> Int).self, onFailure: { Issue.record($0) }, body: actorBody)
            } else {
                request = unsafe .objectMethod(on: receiver, selector: selector,
                    as: ((Int) -> Int).self, onFailure: { Issue.record($0) }, body: body)
            }
            token = try #require(unsafe runtime.installHooks([request]).first)
        }
        defer { token.invalidate() }
        let message = try runtime.object(receiver).method(selector: selector, as: ((Int) -> Int).self)
        #expect(try unsafe message.unsafeInvoke(31) == 42)
    }

    @MainActor @Test(arguments: 0..<4)
    func selectorInitializerHooksKeepTheirContracts(_ path: Int) throws {
        let runtime = ABIRuntime()
        let selector = #selector(SelectorReceiver.init(value:))
        let token: NativeObjCMethodHook
        let after: @Sendable (SelectorReceiver) throws -> Void = { $0.numberValue += 10 }
        let actorAfter: @MainActor @Sendable (SelectorReceiver) throws -> Void = {
            MainActor.preconditionIsolated()
            $0.numberValue += 10
        }
        switch path {
        case 0:
            token = try unsafe runtime.hookInitializer(on: SelectorReceiver.self, selector: selector,
                as: ((Int) -> SelectorReceiver).self, onFailure: { Issue.record($0) }, after: after)
        case 1:
            token = try unsafe runtime.hookMainActorInitializer(on: SelectorReceiver.self, selector: selector,
                as: ((Int) -> SelectorReceiver).self, onFailure: { Issue.record($0) }, after: actorAfter)
        default:
            let request: NativeObjCHookRequest
            if path == 2 {
                request = unsafe .initializer(on: SelectorReceiver.self, selector: selector,
                    as: ((Int) -> SelectorReceiver).self, onFailure: { Issue.record($0) }, after: after)
            } else {
                request = unsafe .mainActorInitializer(on: SelectorReceiver.self, selector: selector,
                    as: ((Int) -> SelectorReceiver).self, onFailure: { Issue.record($0) }, after: actorAfter)
            }
            token = try #require(unsafe runtime.installHooks([request]).first)
        }
        defer { token.invalidate() }
        let allocate = try runtime.objcMethod(on: SelectorReceiver.self, selector: "alloc",
            as: (() -> SelectorReceiver).self, classMethod: true)
        let allocated = try unsafe allocate.unsafeInvoke(on: SelectorReceiver.self as AnyObject)
        let initialize = try runtime.object(allocated).method(selector: selector, as: ((Int) -> SelectorReceiver).self)
        let value = try unsafe initialize.unsafeInvoke(32)
        #expect(value.numberValue == 42)
    }
}
