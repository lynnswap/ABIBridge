import ABIBridge
import Foundation
import Testing

@objc(ABIDiagnosticRequest)
private final class DiagnosticRequest: NSObject {
    @objc dynamic var value: Int32 = 2
    var observed: Int32 = 0
    var descriptionReads = 0
    override var description: String { descriptionReads += 1; return "request" }
}
@objc(ABIDiagnosticRenderer)
private final class DiagnosticRenderer: NSObject {
    var lastRequest: DiagnosticRequest?
    var descriptionReads = 0
    override var description: String { descriptionReads += 1; return "renderer" }
    @objc dynamic func edit(_ request: DiagnosticRequest) -> Int32 {
        lastRequest = request
        request.observed = request.value + 40
        return request.observed
    }
    @objc dynamic func edit(_ request: DiagnosticRequest, offset: Int32, other: DiagnosticRequest?) -> Int32 {
        lastRequest = request
        request.observed = request.value + offset + (other?.value ?? 0)
        return request.observed
    }
}
private final class DiagnosticBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite(.serialized)
struct HookInvocationDiagnosticsTests {
    @Test func editsActualObjectsAndKeepsDiagnosticsAfterExpiry() throws {
        let saved = DiagnosticBox<NativeObjCMethodInvocation<Int32, DiagnosticRequest>?>(nil)
        let description = DiagnosticBox("")
        let runtime = ABIRuntime()
        let hook = try unsafe runtime.hookMethod(on: DiagnosticRenderer.self, selector: "edit:",
            as: ((DiagnosticRequest) -> Int32).self, onFailure: { Issue.record($0) }) { call, request in
                saved.set(call)
                #expect(call.declaration.name == "-[ABIDiagnosticRenderer edit:]")
                #expect(call.declaration.language == .objectiveC)
                #expect(ObjectIdentifier(call.signature) == ObjectIdentifier(((DiagnosticRequest) -> Int32).self))
                description.set(String(describing: call))
                #expect(try call.receiver is DiagnosticRenderer)
                request.value = 7
                let result = try call.proceed(request)
                request.observed += 1
                return result
            }
        let renderer = DiagnosticRenderer(), request = DiagnosticRequest()
        #expect(renderer.edit(request) == 47)
        #expect(renderer.lastRequest === request && request.value == 7 && request.observed == 48)
        #expect(request.descriptionReads == 0 && renderer.descriptionReads == 0)
        hook.invalidate()
        let call = try #require(saved.get())
        #expect(String(describing: call) == description.get())
        #expect(call.description.contains("DiagnosticRequest") && call.description.contains("Swift.Int32"))
        #expect(throws: NativeObjCMethodHookError.expiredInvocation) { try call.proceed(request) }
        let copied = DispatchQueue.global().sync { saved.get()?.description }
        #expect(copied == description.get())
    }

    @Test func replacesOnlyDownstreamReferenceAndUsesDynamicSetter() throws {
        let runtime = ABIRuntime()
        let renderer = DiagnosticRenderer(), request = DiagnosticRequest()
        let redirect = try unsafe runtime.hookMethod(on: DiagnosticRenderer.self, selector: "edit:",
            as: ((DiagnosticRequest) -> Int32).self, onFailure: { Issue.record($0) }) { call, _ in
                let replacement = DiagnosticRequest()
                replacement.value = 11
                return try call.proceed(replacement)
            }
        #expect(renderer.edit(request) == 51)
        #expect(renderer.lastRequest !== request && request.value == 2 && request.observed == 0)
        redirect.invalidate()
        // The callback deliberately does not require the concrete argument type.
        let dynamic = try unsafe runtime.hookMethod(on: DiagnosticRenderer.self, selector: "edit:",
            as: ((AnyObject) -> Int32).self, onFailure: { Issue.record($0) }) { call, object in
                let setter = try runtime.object(object).method(selector: "setValue:", as: ((Int32) -> Void).self)
                try unsafe setter.unsafeInvoke(9)
                return try call.proceed(object)
            }
        defer { dynamic.invalidate() }
        #expect(renderer.edit(request) == 49)
        #expect(renderer.lastRequest === request && request.value == 9 && request.observed == 49)
    }

    @Test func objectChangesRemainAfterFailureBeforeAndAfterProceed() throws {
        enum Expected: Error { case failed }
        let failures = DiagnosticBox(0)
        for after in [false, true] {
            let hook = try unsafe ABIRuntime.shared.hookMethod(on: DiagnosticRenderer.self, selector: "edit:",
                as: ((DiagnosticRequest) -> Int32).self, onFailure: { _ in failures.set(failures.get() + 1) }) { call, request in
                    request.value = 8
                    if after { _ = try call.proceed(request); request.value = 10 }
                    throw Expected.failed
                }
            let renderer = DiagnosticRenderer(), request = DiagnosticRequest()
            #expect(renderer.edit(request) == 48)
            #expect(request.value == (after ? 10 : 8) && request.observed == 48)
            hook.invalidate()
        }
        #expect(failures.get() == 2)
    }

    @Test @MainActor func coordinatedMainActorHooksCarryTheirDeclaration() throws {
        let request = unsafe NativeObjCHookRequest.mainActorMethod(on: DiagnosticRenderer.self, selector: "edit:",
            as: ((DiagnosticRequest) -> Int32).self, onFailure: { Issue.record($0) }) { call, argument in
                #expect(call.declaration.name == "-[ABIDiagnosticRenderer edit:]")
                argument.value = 12
                return try call.proceed(argument)
            }
        let hooks = try unsafe ABIRuntime.shared.installHooks([request])
        defer { hooks.forEach { $0.invalidate() } }
        #expect(DiagnosticRenderer().edit(DiagnosticRequest()) == 52)
    }

    @Test(arguments: [0, 1, 2]) @MainActor func mainActorRoutesEditMixedArguments(route: Int) throws {
        let runtime = ABIRuntime(), renderer = DiagnosticRenderer()
        let body: @MainActor @Sendable (NativeObjCMethodInvocation<Int32, DiagnosticRequest, Int32, DiagnosticRequest?>,
            DiagnosticRequest, Int32, DiagnosticRequest?) throws -> Int32 = { call, request, offset, other in
                #expect(call.declaration.name == "-[ABIDiagnosticRenderer edit:offset:other:]")
                request.value = 10
                other?.value = 20
                let result = try call.proceed(request, offset + 1, other)
                request.observed += 1
                return result
            }
        let signature = ((DiagnosticRequest, Int32, DiagnosticRequest?) -> Int32).self
        let hooks: [NativeObjCMethodHook]
        switch route {
        case 0:
            hooks = [try unsafe runtime.hookMainActorMethod(on: DiagnosticRenderer.self, selector: "edit:offset:other:",
                as: signature, onFailure: { Issue.record($0) }, body: body)]
        case 1:
            hooks = [try unsafe runtime.object(renderer).hookMainActorMethod(selector: "edit:offset:other:",
                as: signature, onFailure: { Issue.record($0) }, body: body)]
        default:
            hooks = try unsafe runtime.installHooks([.mainActorMethod(on: DiagnosticRenderer.self, selector: "edit:offset:other:",
                as: signature, onFailure: { Issue.record($0) }, body: body)])
        }
        defer { hooks.forEach { $0.invalidate() } }
        let request = DiagnosticRequest(), other = DiagnosticRequest()
        #expect(renderer.edit(request, offset: 2, other: other) == 33)
        #expect(request.value == 10 && request.observed == 34 && other.value == 20)
        #expect(renderer.edit(request, offset: 4, other: nil) == 15)
        #expect(request.observed == 16 && renderer.lastRequest === request)
    }
}
